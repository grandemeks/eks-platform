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

	mux.Handle("GET /", s.metrics.Instrument("/", http.HandlerFunc(s.handleRoot)))
	mux.Handle("GET /healthz", http.HandlerFunc(s.handleHealthz))
	mux.Handle("GET /readyz", http.HandlerFunc(s.handleReadyz))

	// Probes and the metrics endpoint are deliberately not instrumented.
	// Kubelet probes every few seconds and Prometheus scrapes every fifteen;
	// counting those as traffic would drown the real request rate and make any
	// availability SLO meaningless.
	mux.Handle("GET /metrics", promhttp.HandlerFor(
		s.metrics.Registry(),
		promhttp.HandlerOpts{Registry: s.metrics.Registry()},
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
	s.metrics.ObserveDBQuery(time.Since(start))

	if err != nil {
		s.metrics.SetDBUp(false)
		s.log.ErrorContext(ctx, "failed to record visit", slog.Any("error", err))
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"error": "database unavailable",
		})
		return
	}

	s.metrics.SetDBUp(true)

	writeJSON(w, http.StatusOK, map[string]any{
		"message":      "eks-platform demo application",
		"version":      s.cfg.Version,
		"hostname":     hostname(),
		"total_visits": result.Total,
		"first_visit":  result.First.UTC().Format(time.RFC3339),
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
// database should be removed from the load balancer without being killed.
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting down"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := s.store.Ping(ctx); err != nil {
		s.metrics.SetDBUp(false)
		s.log.WarnContext(ctx, "readiness check failed", slog.Any("error", err))
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "database unreachable",
		})
		return
	}

	s.metrics.SetDBUp(true)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
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