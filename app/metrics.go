package main

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics follows the RED method: Rate, Errors, Duration. Those three are what
// an availability and latency SLO is computed from, so they are the metrics
// that drive alerting rather than just filling a dashboard.
//
// Deliberately still the Prometheus client rather than the OpenTelemetry
// metrics SDK, even though this service now emits OTel traces. OTel's HTTP
// semantic conventions name the histogram http.server.request.duration, which
// a Prometheus exporter renders as http_server_request_duration_seconds_bucket
// — every recording rule, every burn-rate alert and every dashboard panel is
// written against the names below. Switching instrumentation libraries would
// rewrite the SLO definition as a side effect of a plumbing change.
//
// Traces go through OTel because Prometheus does not do traces. Exemplars link
// the two.
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
	// A custom registry rather than the global default: the application
	// controls exactly what is exposed, and tests do not leak metrics into
	// each other.
	reg := prometheus.NewRegistry()

	m := &Metrics{
		registry: reg,

		requestsTotal: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "http_requests_total",
				Help: "Total HTTP requests by method, route and status code.",
			},
			// Labelled by route pattern, never by raw URL path. Using the raw
			// path would give every unique URL its own time series and
			// eventually take Prometheus down.
			[]string{"method", "route", "status"},
		),

		requestDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Name: "http_request_duration_seconds",
				Help: "HTTP request latency in seconds.",
				// Buckets straddle the latency objective (250ms) so the SLO is
				// counted at a bucket boundary rather than interpolated across
				// one.
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

		// Always 1; the information is in the labels. Standard pattern for
		// build metadata, and it lets a dashboard annotate a latency change
		// with the deploy that caused it.
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

	// Go runtime and process metrics: goroutines, heap, GC pauses, file
	// descriptors, CPU. Free to collect and the first thing worth checking
	// when a pod restarts for no obvious reason.
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

// ObserveDBQuery records query latency, attaching the current trace as an
// exemplar when one exists.
func (m *Metrics) ObserveDBQuery(ctx context.Context, d time.Duration) {
	observeWithTrace(ctx, m.dbQueryDuration, d.Seconds())
}

// observeWithTrace attaches the current trace ID to a histogram observation as
// an exemplar.
//
// This is the link that makes the whole observability stack one thing rather
// than three. A histogram tells you the p99 rose; it cannot tell you which
// request was slow. An exemplar carries the trace ID of one specific
// observation in the bucket, so clicking the spike in Grafana opens the trace
// of a request that actually caused it — not a representative one, that one.
//
// Two conditions have to hold for this to be visible, and both are easy to
// miss because neither produces an error:
//   - the /metrics handler must serve OpenMetrics, since the classic Prometheus
//     text format has no way to express an exemplar
//   - Prometheus must run with the exemplar-storage feature enabled, or it
//     parses them off the wire and discards them
func observeWithTrace(ctx context.Context, obs prometheus.Observer, value float64) {
	traceID := traceIDFrom(ctx)
	if traceID == "" {
		obs.Observe(value)
		return
	}

	// Not every Observer supports exemplars; the type assertion is the
	// documented way to find out rather than a defensive habit.
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

// Instrument wraps a handler with the RED metrics. The route argument is the
// pattern, supplied by the caller rather than read from the request, which is
// what keeps label cardinality bounded.
func (m *Metrics) Instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		m.inFlight.Inc()
		defer m.inFlight.Dec()

		// Default to 200: a handler that writes a body without calling
		// WriteHeader implicitly sends 200.
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(rec, r)

		elapsed := time.Since(start).Seconds()

		// The context is read after the handler has run, so it carries the
		// span the HTTP instrumentation created for this request.
		observeWithTrace(r.Context(),
			m.requestDuration.WithLabelValues(r.Method, route), elapsed)

		m.requestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
	})
}
