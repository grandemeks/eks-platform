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

	// Flipped to false when SIGTERM arrives, so readiness starts failing
	// before the server stops accepting connections. See main.go.
	ready atomic.Bool
}

func NewServer(cfg Config, store *Store, metrics *Metrics, log *slog.Logger) *Server {
	s := &Server{cfg: cfg, store: store, metrics: metrics, log: log}
	s.ready.Store(true)
	return s
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	// otelhttp creates the server span and, crucially, reads any inbound
	// traceparent header so this service's spans attach to a trace that
	// started upstream rather than beginning a new one. The route pattern is
	// passed explicitly as the span name; letting it default to the raw path
	// produces one span name per URL, which is the same cardinality problem as
	// unbounded metric labels.
	mux.Handle("GET /", otelhttp.NewHandler(
		s.metrics.Instrument("/", http.HandlerFunc(s.handleRoot)),
		"GET /",
	))

	// Probes are neither traced nor instrumented. The kubelet probes every few
	// seconds; counting that as traffic would drown the real request rate and
	// fill Tempo with spans nobody will ever read.
	mux.Handle("GET /healthz", http.HandlerFunc(s.handleHealthz))
	mux.Handle("GET /readyz", http.HandlerFunc(s.handleReadyz))

	mux.Handle("GET /metrics", promhttp.HandlerFor(
		s.metrics.Registry(),
		promhttp.HandlerOpts{
			Registry: s.metrics.Registry(),
			// Without this the endpoint serves the classic Prometheus text
			// format, which has no syntax for exemplars — they are computed,
			// stored in the histogram, and then silently dropped on the way
			// out. This single line is the difference between exemplars
			// working and appearing not to exist.
			EnableOpenMetrics: true,
		},
	))

	return mux
}

// handleRoot is the actual workload: it writes a row and reads back the
// running total, which proves end to end that the pod can reach RDS.
func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	// Bounded so a slow database produces a fast 503 rather than a request
	// that hangs until the client gives up.
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

	// Attributes on the span the HTTP instrumentation created. A trace that
	// only shows timings answers "how long"; attributes are what let it answer
	// "on what".
	spanAttr(ctx, attribute.Int64("app.total_visits", result.Total))

	writeJSON(w, http.StatusOK, map[string]any{
		"message":      "eks-platform demo application",
		"version":      s.cfg.Version,
		"hostname":     hostname(),
		"total_visits": result.Total,
		"first_visit":  result.First.UTC().Format(time.RFC3339),
		// Returned so a caller can look up their own request in Tempo. Small
		// touch, and the fastest way to demonstrate the trace pipeline works.
		"trace_id": traceIDFrom(ctx),
	})
}

// handleHealthz answers liveness: is this process itself broken beyond
// recovery? It deliberately does not touch the database. If it did, a database
// outage would restart every pod in the deployment, turning a recoverable
// dependency failure into a self-inflicted outage.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz answers readiness: should this pod receive traffic right now?
// Here the database check belongs, because a pod that cannot reach the
// database should leave the load balancer without being killed.
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

// logCtx returns a logger that stamps every line with the current trace ID.
//
// This is the third side of the correlation triangle. The Grafana Loki
// datasource is configured with a derived field on trace_id, so a log line
// carrying this field renders as a link straight into the trace. Without it,
// correlating a log with a trace means comparing timestamps by eye.
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

func hostname() string {
	// In Kubernetes this is the pod name, which makes it obvious from a
	// response which replica served the request.
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}
