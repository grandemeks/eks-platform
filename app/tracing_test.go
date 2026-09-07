package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestInitTracingExportsToSignalPath pins the export URL: a base endpoint has
// to become <base>/v1/traces. Getting it wrong shows up nowhere but the
// collector's 404s.
func TestInitTracingExportsToSignalPath(t *testing.T) {
	paths := make(chan string, 1)

	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case paths <- r.URL.Path:
		default:
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer collector.Close()

	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", collector.URL)

	ctx := context.Background()
	shutdown, err := initTracing(ctx, Config{
		ServiceName: "demo-app",
		Version:     "test",
		Environment: "test",
	})
	if err != nil {
		t.Fatalf("initTracing: %v", err)
	}

	_, span := tracer.Start(ctx, "test")
	span.End()

	// Shutdown flushes the batcher, so the export lands before this returns.
	flushCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := shutdown(flushCtx); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	select {
	case got := <-paths:
		if got != "/v1/traces" {
			t.Errorf("exporter posted to %q, want %q", got, "/v1/traces")
		}
	default:
		t.Fatal("collector received no export")
	}
}

// TestInitTracingDisabledWithoutEndpoint covers local development: no endpoint
// means a no-op shutdown and no error.
func TestInitTracingDisabledWithoutEndpoint(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")

	shutdown, err := initTracing(context.Background(), Config{ServiceName: "demo-app"})
	if err != nil {
		t.Fatalf("initTracing: %v", err)
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
}
