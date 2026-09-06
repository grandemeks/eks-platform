package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

// Tracing is initialised only when an OTLP endpoint is configured. With the
// variable unset the application runs with a no-op tracer: spans are created
// and immediately discarded, at effectively no cost. That is what lets the
// same binary run locally against a Postgres container with no collector in
// sight, and in the cluster with one — a build-time switch would mean two
// binaries and only one of them tested.
func initTracing(ctx context.Context, cfg Config) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	// Resource attributes describe the producer of every span, and are set
	// once rather than repeated per span. service.name is what Tempo groups by
	// and what the service graph nodes are named after; getting it wrong makes
	// the traces arrive but unattributable.
	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(cfg.ServiceName),
			semconv.ServiceVersion(cfg.Version),
			// Written as a raw attribute rather than through a semconv helper.
			// The convention renamed this key from deployment.environment to
			// deployment.environment.name, so the generated helper exists
			// under one name in older packages and another in newer ones.
			// Spelling it out means the code does not break on a semconv bump,
			// and the key stays the one Grafana's datasource configuration and
			// the Tempo service graph are already matching on.
			attribute.String("deployment.environment", cfg.Environment),
			// The pod name. When a trace shows one slow replica out of two,
			// this is the attribute that says which one.
			semconv.K8SPodName(hostname()),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("build resource: %w", err)
	}

	// HTTP rather than gRPC. Both are supported by the collector; HTTP keeps
	// the dependency tree considerably smaller, and at this volume the
	// difference in efficiency is not measurable.
	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpointURL(endpoint),
		// Plaintext. The collector runs on the same node, reached over the
		// pod network, and never leaves the VPC. TLS here would mean managing
		// a certificate for a hop that does not cross a trust boundary.
		otlptracehttp.WithInsecure(),
		otlptracehttp.WithTimeout(10*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("create OTLP exporter: %w", err)
	}

	provider := sdktrace.NewTracerProvider(
		// Batched, not synchronous. A synchronous exporter puts an HTTP call
		// to the collector on the request path, so a slow collector becomes
		// slow requests — telemetry causing the outage it is meant to explain.
		sdktrace.WithBatcher(exporter,
			sdktrace.WithMaxQueueSize(2048),
			sdktrace.WithBatchTimeout(5*time.Second),
		),
		sdktrace.WithResource(res),

		// ParentBased(AlwaysSample): sample everything this service starts,
		// but honour the decision of an upstream caller when there is one.
		// Without ParentBased, a service that samples independently produces
		// broken traces — some spans present, their parents missing.
		//
		// AlwaysSample is right at this volume. Production would use
		// TraceIDRatioBased here and tail sampling in a gateway collector, so
		// that errors and slow requests are kept at 100% while routine traffic
		// is sampled down.
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)

	otel.SetTracerProvider(provider)

	// W3C trace context plus baggage. This is what makes a trace continue
	// across a service boundary instead of starting again: the caller writes
	// traceparent, the callee reads it and attaches its spans to the same
	// trace.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return provider.Shutdown, nil
}

// tracer is the instrumentation scope. Named after the module so spans this
// application creates are distinguishable from spans the HTTP instrumentation
// creates.
var tracer = otel.Tracer("github.com/grandemeks/eks-platform/app")

// traceIDFrom returns the current trace ID, or an empty string when tracing is
// disabled or the context carries no span. Used to attach the trace ID to log
// lines and to metric exemplars — the two links that turn three separate
// systems into one investigation.
func traceIDFrom(ctx context.Context) string {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return ""
	}
	return sc.TraceID().String()
}

// spanAttr is a small convenience so handlers can annotate the current span
// without importing the attribute package everywhere.
func spanAttr(ctx context.Context, kv ...attribute.KeyValue) {
	trace.SpanFromContext(ctx).SetAttributes(kv...)
}
