package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
)

type Server struct {
	cfg     Config
	store   *Store
	metrics *Metrics
	log     *slog.Logger

	// Cleared on SIGTERM so readiness fails before the drain begins. See main.go.
	ready atomic.Bool
}

func NewServer(cfg Config, store *Store, metrics *Metrics, log *slog.Logger) *Server {
	s := &Server{cfg: cfg, store: store, metrics: metrics, log: log}
	s.ready.Store(true)
	return s
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	// otelhttp must stay the outer wrapper: it creates the server span from any
	// inbound traceparent, and Instrument reads that span for exemplars.
	// Span name is the route pattern, not the raw path: raw paths are unbounded
	// cardinality.
	mux.Handle("GET /", otelhttp.NewHandler(
		s.metrics.Instrument("/", http.HandlerFunc(s.handleRoot)),
		"GET /",
	))

	// Probes stay uninstrumented: kubelet polls every few seconds and would
	// swamp the real request rate.
	mux.Handle("GET /healthz", http.HandlerFunc(s.handleHealthz))
	mux.Handle("GET /readyz", http.HandlerFunc(s.handleReadyz))

	mux.Handle("GET /metrics", promhttp.HandlerFor(
		s.metrics.Registry(),
		promhttp.HandlerOpts{
			Registry: s.metrics.Registry(),
			// Required for exemplars: the classic text format cannot express
			// them, so they are dropped on the way out with no error.
			EnableOpenMetrics: true,
		},
	))

	return mux
}

// handleRoot writes a visit row and returns the running total, exercising the
// path to RDS.
func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	// Shorter than the server WriteTimeout, so a slow DB gives a 503 rather
	// than a hung request.
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	start := time.Now()
	result, err := s.store.RecordVisit(ctx, r.Header.Get("User-Agent"))
	s.metrics.ObserveDBQuery(ctx, time.Since(start))

	if err != nil {
		s.metrics.SetDBUp(false)
		s.logCtx(ctx).Error("failed to record visit", slog.Any("error", err))
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"error": "database unavailable",
		})
		return
	}

	s.metrics.SetDBUp(true)

	spanAttr(ctx, attribute.Int64("app.total_visits", result.Total))

	writeJSON(w, http.StatusOK, map[string]any{
		"message":      "eks-platform demo application",
		"version":      s.cfg.Version,
		"hostname":     hostname(),
		"total_visits": result.Total,
		"first_visit":  result.First.UTC().Format(time.RFC3339),
		// Lets a caller look up their own request in Tempo.
		"trace_id": traceIDFrom(ctx),
	})
}

// handleHealthz answers liveness. It must not touch the database: a DB outage
// would then restart every replica.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz answers readiness. The DB check belongs here: a pod that cannot
// reach the database should leave the load balancer, not be killed.
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting down"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := s.store.Ping(ctx); err != nil {
		s.metrics.SetDBUp(false)
		s.log.Warn("readiness check failed", slog.Any("error", err))
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "database unreachable",
		})
		return
	}

	s.metrics.SetDBUp(true)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// logCtx returns a logger that stamps each line with the current trace ID.
//
// The field name must stay trace_id: the Loki datasource has a derived field on
// it that renders the log-to-trace link.
func (s *Server) logCtx(ctx context.Context) *slog.Logger {
	if id := traceIDFrom(ctx); id != "" {
		return s.log.With(slog.String("trace_id", id))
	}
	return s.log
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// hostname returns the pod name under Kubernetes, which identifies the replica
// that served a request.
func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}
