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

// Version is set at build time via -ldflags "-X main.Version=<sha>".
var Version = "dev"

func main() {
	// JSON to stdout: the collector's filelog receiver forwards these to Loki,
	// where structured fields stay queryable instead of needing a regex.
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

	// No-op shutdown when no OTLP endpoint is set, so the same binary runs
	// locally without a collector.
	shutdownTracing, err := initTracing(ctx, cfg)
	tracingEnabled := err == nil && os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != ""
	if err != nil {
		// Not fatal: the telemetry pipeline must not be a hard startup dependency.
		log.Warn("tracing disabled", slog.Any("error", err))
		shutdownTracing = func(context.Context) error { return nil }
	}

	store, err := NewStore(ctx, cfg.DSN())
	if err != nil {
		return err
	}
	defer store.Close()

	// Warn, don't exit: exiting here turns a brief DB blip into CrashLoopBackOff
	// with exponential backoff. Readiness keeps the pod out of the LB meanwhile.
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

		// Without these a slow client can hold connections open until the
		// process runs out of file descriptors.
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

	// Fail readiness before draining: SIGTERM races endpoint removal, and that
	// removal takes seconds to reach kube-proxy on every node and the ALB target
	// group. Closing the socket first turns in-flight traffic into
	// connection-refused. The sleep below covers that propagation window.
	log.Info("shutdown signal received, failing readiness")
	srv.ready.Store(false)

	time.Sleep(5 * time.Second)

	log.Info("draining in-flight requests")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return err
	}

	// Flush after the drain, or the batcher's unsent spans from the final
	// requests are lost with the queue.
	log.Info("flushing traces")
	flushCtx, flushCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer flushCancel()
	if err := shutdownTracing(flushCtx); err != nil {
		log.Warn("trace flush failed", slog.Any("error", err))
	}

	log.Info("shutdown complete")
	return nil
}
