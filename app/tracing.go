package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// initTracing configures the global tracer provider and returns its shutdown.
// Without OTEL_EXPORTER_OTLP_ENDPOINT it returns a no-op, so the same binary
// runs locally with no collector.
func initTracing(ctx context.Context, cfg Config) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	// Async export failures go to the global handler, whose default writes to
	// the log package and lands at INFO under slog.SetDefault. A dead trace
	// pipeline then reads as ordinary output; at ERROR it is alertable.
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		slog.Error("otel sdk error", slog.Any("error", err))
	}))

	// Literal keys and an empty schema URL, not semconv: Merge fails when the
	// two resources carry different schema URLs, which disables tracing at
	// startup whenever the semconv version drifts from the SDK's.
	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes("",
			attribute.String("service.name", cfg.ServiceName),
			attribute.String("service.version", cfg.Version),
			attribute.String("deployment.environment", cfg.Environment),
			// Pod name: says which replica when one of two is slow.
			attribute.String("k8s.pod.name", hostname()),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("build resource: %w", err)
	}

	// OTEL_EXPORTER_OTLP_ENDPOINT is a base URL per spec, so append the signal
	// path. WithEndpointURL would set the path to "/" and every export 404s,
	// silently: the app stays healthy and trace IDs resolve to nothing.
	base, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse OTLP endpoint %q: %w", endpoint, err)
	}
	if base.Host == "" {
		return nil, fmt.Errorf("OTLP endpoint %q has no host", endpoint)
	}

	// HTTP, not gRPC: the collector accepts both, and HTTP pulls in far less.
	exporterOpts := []otlptracehttp.Option{
		otlptracehttp.WithEndpoint(base.Host),
		otlptracehttp.WithURLPath(path.Join(base.Path, "/v1/traces")),
		otlptracehttp.WithTimeout(10 * time.Second),
	}
	if base.Scheme != "https" {
		// Plaintext: the collector is a node-local hop over the pod network,
		// so TLS would mean a certificate for no trust boundary.
		exporterOpts = append(exporterOpts, otlptracehttp.WithInsecure())
	}

	exporter, err := otlptracehttp.New(ctx, exporterOpts...)
	if err != nil {
		return nil, fmt.Errorf("create OTLP exporter: %w", err)
	}

	provider := sdktrace.NewTracerProvider(
		// Batched, not synchronous: a syncer puts the collector call on the
		// request path, so a slow collector becomes slow requests.
		sdktrace.WithBatcher(exporter,
			sdktrace.WithMaxQueueSize(2048),
			sdktrace.WithBatchTimeout(5*time.Second),
		),
		sdktrace.WithResource(res),

		// ParentBased honours the upstream decision; deciding independently
		// yields traces whose spans are missing their parents. Higher traffic
		// wants a ratio here plus tail sampling in a gateway collector.
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)

	otel.SetTracerProvider(provider)

	// W3C traceparent and baggage, or a trace restarts at every service hop.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return provider.Shutdown, nil
}

// tracer is the instrumentation scope for spans this application creates, as
// opposed to those from the HTTP instrumentation.
var tracer = otel.Tracer("github.com/grandemeks/eks-platform/app")

// traceIDFrom returns the current trace ID, or "" when tracing is disabled or
// ctx carries no span.
func traceIDFrom(ctx context.Context) string {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return ""
	}
	return sc.TraceID().String()
}

// spanAttr sets attributes on the span in ctx, and is a no-op when there is none.
func spanAttr(ctx context.Context, kv ...attribute.KeyValue) {
	trace.SpanFromContext(ctx).SetAttributes(kv...)
}
