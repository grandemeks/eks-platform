package main

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics holds the RED series the SLO recording rules and burn-rate alerts are
// computed from.
//
// Still the Prometheus client, not the OTel metrics SDK: OTel exports these as
// http_server_request_duration_seconds_*, renaming the series every SLO rule
// and dashboard below is written against.
type Metrics struct {
	registry *prometheus.Registry

	requestsTotal   *prometheus.CounterVec
	requestDuration *prometheus.HistogramVec
	inFlight        prometheus.Gauge
	dbUp            prometheus.Gauge
	dbQueryDuration prometheus.Histogram
	buildInfo       *prometheus.GaugeVec
}

func NewMetrics(version string) *Metrics {
	// Custom registry, not the global default, so tests do not leak metrics
	// into each other.
	reg := prometheus.NewRegistry()

	m := &Metrics{
		registry: reg,

		requestsTotal: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "http_requests_total",
				Help: "Total HTTP requests by method, route and status code.",
			},
			// route is the pattern, never the raw path: raw paths give every
			// URL its own series.
			[]string{"method", "route", "status"},
		),

		requestDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Name: "http_request_duration_seconds",
				Help: "HTTP request latency in seconds.",
				// 0.25 must stay a bucket edge: the latency SLO is 250ms, and
				// otherwise it is interpolated across a bucket.
				Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
			},
			[]string{"method", "route"},
		),

		inFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Requests currently being served.",
		}),

		dbUp: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "app_database_up",
			Help: "1 if the last database health check succeeded, 0 otherwise.",
		}),

		dbQueryDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "app_database_query_duration_seconds",
			Help:    "Time spent in database queries.",
			Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1},
		}),

		// Lets a dashboard annotate a latency change with the deploy behind it.
		buildInfo: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "app_build_info",
				Help: "Build metadata. Always 1; the labels carry the information.",
			},
			[]string{"version"},
		),
	}

	reg.MustRegister(
		m.requestsTotal, m.requestDuration, m.inFlight,
		m.dbUp, m.dbQueryDuration, m.buildInfo,
	)

	// Runtime and process metrics: the first place to look when a pod restarts
	// for no obvious reason.
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	m.buildInfo.WithLabelValues(version).Set(1)
	return m
}

func (m *Metrics) Registry() *prometheus.Registry { return m.registry }

func (m *Metrics) SetDBUp(up bool) {
	if up {
		m.dbUp.Set(1)
		return
	}
	m.dbUp.Set(0)
}

// ObserveDBQuery records query latency with a trace exemplar when ctx has a span.
func (m *Metrics) ObserveDBQuery(ctx context.Context, d time.Duration) {
	observeWithTrace(ctx, m.dbQueryDuration, d.Seconds())
}

// observeWithTrace attaches the current trace ID to a histogram observation, so
// a latency spike links to the request that caused it.
//
// Both preconditions fail silently: /metrics must serve OpenMetrics, and
// Prometheus must run with exemplar storage enabled.
func observeWithTrace(ctx context.Context, obs prometheus.Observer, value float64) {
	traceID := traceIDFrom(ctx)
	if traceID == "" {
		obs.Observe(value)
		return
	}

	// Not every Observer implementation supports exemplars.
	if eo, ok := obs.(prometheus.ExemplarObserver); ok {
		eo.ObserveWithExemplar(value, prometheus.Labels{"trace_id": traceID})
		return
	}
	obs.Observe(value)
}

// statusRecorder captures the status code, which http.ResponseWriter does not
// expose after the fact.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Instrument wraps a handler with the RED metrics. route must be the mux
// pattern, not a path from the request, to keep label cardinality bounded.
func (m *Metrics) Instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		m.inFlight.Inc()
		defer m.inFlight.Dec()

		// A handler that writes a body without WriteHeader implicitly sends 200.
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(rec, r)

		elapsed := time.Since(start).Seconds()

		// otelhttp must wrap this handler, or r.Context() has no span here and
		// every exemplar is dropped.
		observeWithTrace(r.Context(),
			m.requestDuration.WithLabelValues(r.Method, route), elapsed)

		m.requestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
	})
}
