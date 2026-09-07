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

	// The SDK reports asynchronous failures — a rejected export, a dropped
	// batch — through the global error handler, and the default one writes to
	// the standard log package. slog.SetDefault redirects that to the JSON
	// handler at INFO, so an export failing on every batch appears as an
	// unlabelled info line indistinguishable from ordinary application output.
	// That is how a completely dead trace pipeline reads as healthy. Route it
	// through slog at ERROR with a stable message instead, so it is greppable
	// in Loki and can be alerted on.
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		slog.Error("otel sdk error", slog.Any("error", err))
	}))

	// Attributes written as literal keys rather than through semconv helpers.
	//
	// resource.Default() carries the schema URL of the SDK version, and the
	// semconv package carries its own. resource.Merge refuses to combine two
	// resources with different schema URLs, so importing a semconv package
	// that does not exactly match the SDK produces a merge error at startup —
	// which is how this first surfaced, as tracing silently disabled with the
	// application otherwise healthy.
	//
	// Passing an empty schema URL sidesteps the version coupling entirely. The
	// attribute keys below are the ones Tempo groups by and the ones the
	// Grafana datasource configuration matches on; those names are stable
	// across convention versions even when the generated helpers are renamed.
	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes("",
			attribute.String("service.name", cfg.ServiceName),
			attribute.String("service.version", cfg.Version),
			attribute.String("deployment.environment", cfg.Environment),
			// The pod name. When a trace shows one slow replica out of two,
			// this is the attribute that says which one.
			attribute.String("k8s.pod.name", hostname()),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("build resource: %w", err)
	}

	// OTEL_EXPORTER_OTLP_ENDPOINT is a base URL by specification: the exporter
	// is expected to append the per-signal path, so http://host:4318 means
	// http://host:4318/v1/traces. WithEndpointURL does not do that — it takes
	// the URL as the complete traces endpoint and, given no path, sets it to
	// "/" explicitly so the default signal path is not filled in later. The
	// collector serves only /v1/traces, /v1/metrics and /v1/logs, so every
	// export was answered with a 404 and no span ever reached Tempo. Nothing
	// failed loudly: the application stayed healthy, trace IDs were generated
	// and returned to callers, and exemplars carried IDs that resolved to
	// nothing.
	//
	// So parse the base URL and append the signal path here.
	base, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse OTLP endpoint %q: %w", endpoint, err)
	}
	if base.Host == "" {
		return nil, fmt.Errorf("OTLP endpoint %q has no host", endpoint)
	}

	// HTTP rather than gRPC. Both are supported by the collector; HTTP keeps
	// the dependency tree considerably smaller, and at this volume the
	// difference in efficiency is not measurable.
	exporterOpts := []otlptracehttp.Option{
		otlptracehttp.WithEndpoint(base.Host),
		otlptracehttp.WithURLPath(path.Join(base.Path, "/v1/traces")),
		otlptracehttp.WithTimeout(10 * time.Second),
	}
	if base.Scheme != "https" {
		// Plaintext. The collector runs on the same node, reached over the pod
		// network, and never leaves the VPC. TLS here would mean managing a
		// certificate for a hop that does not cross a trust boundary.
		exporterOpts = append(exporterOpts, otlptracehttp.WithInsecure())
	}

	exporter, err := otlptracehttp.New(ctx, exporterOpts...)
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
