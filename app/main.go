package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// Version is overridden at build time with:
//
//	-ldflags "-X main.Version=$(git rev-parse --short HEAD)"
//
// so a running pod can be traced back to an exact commit.
var Version = "dev"

func main() {
	// JSON to stdout, which is the only thing a container should do with logs.
	// The OTel collector reads them off the node with its filelog receiver and
	// forwards them to Loki; structured fields survive that trip as queryable
	// attributes rather than as text to match against.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(log)

	if err := run(log); err != nil {
		log.Error("fatal", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	if cfg.Version == "dev" && Version != "dev" {
		cfg.Version = Version
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// Returns a no-op shutdown when no OTLP endpoint is configured, so the
	// same binary runs locally without a collector.
	shutdownTracing, err := initTracing(ctx, cfg)
	tracingEnabled := err == nil && os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != ""
	if err != nil {
		// Not fatal. Losing traces is a degraded state; refusing to start
		// because the telemetry pipeline is unavailable would make the
		// observability stack a hard dependency of the thing it observes.
		log.Warn("tracing disabled", slog.Any("error", err))
		shutdownTracing = func(context.Context) error { return nil }
	}

	store, err := NewStore(ctx, cfg.DSN())
	if err != nil {
		return err
	}
	defer store.Close()

	// Migration is allowed to fail without taking the process down: the pod
	// comes up, reports unready, and recovers on its own once the database is
	// reachable. Exiting here would produce CrashLoopBackOff with exponential
	// backoff, turning a thirty-second database blip into minutes of downtime.
	migrateCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	if err := store.Migrate(migrateCtx); err != nil {
		log.Warn("schema migration failed, continuing in unready state", slog.Any("error", err))
	} else {
		log.Info("schema ready")
	}
	cancel()

	metrics := NewMetrics(cfg.Version)
	srv := NewServer(cfg, store, metrics, log)

	httpServer := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: srv.Routes(),

		// Without these a slow or malicious client can hold a connection open
		// indefinitely and exhaust the server's file descriptors.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("server listening",
			slog.String("addr", httpServer.Addr),
			slog.String("version", cfg.Version),
			slog.String("service", cfg.ServiceName),
			slog.Bool("tracing", tracingEnabled),
		)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	// --- Graceful shutdown -------------------------------------------------
	//
	// The ordering here is what makes a rollout drop zero requests.
	//
	// When a pod is deleted, two things happen at the same time and racing:
	// the kubelet sends SIGTERM, and the endpoints controller starts removing
	// the pod from Service endpoints. That removal has to propagate to
	// kube-proxy on every node and to the load balancer's target group, which
	// takes seconds. A server that exits the instant it sees SIGTERM is still
	// receiving traffic when it closes the socket, and those requests become
	// connection-refused errors on the client side.
	//
	// So: fail readiness first, wait long enough for the removal to propagate,
	// and only then drain in-flight requests.
	log.Info("shutdown signal received, failing readiness")
	srv.ready.Store(false)

	time.Sleep(5 * time.Second)

	log.Info("draining in-flight requests")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return err
	}

	// Flushed after the server has drained, so spans from the last requests
	// are exported rather than discarded with the batch queue. A process that
	// exits without this loses whatever the batcher had not yet sent — which
	// is precisely the spans from a shutdown, the ones worth having.
	log.Info("flushing traces")
	flushCtx, flushCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer flushCancel()
	if err := shutdownTracing(flushCtx); err != nil {
		log.Warn("trace flush failed", slog.Any("error", err))
	}

	log.Info("shutdown complete")
	return nil
}
