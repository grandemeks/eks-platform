package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics follows the RED method: Rate, Errors, Duration. Those three are what
// an availability and latency SLO is computed from, so they are the metrics
// that actually drive alerting rather than just filling a dashboard.
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
	// A custom registry rather than the global default: the app controls
	// exactly what is exposed, and tests do not leak metrics into each other.
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
			// eventually take Prometheus down — the classic cardinality
			// explosion.
			[]string{"method", "route", "status"},
		),

		requestDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Name: "http_request_duration_seconds",
				Help: "HTTP request latency in seconds.",
				// Buckets straddle the latency objective (250ms) so the SLO
				// can be computed exactly at a bucket boundary. Default
				// buckets would force interpolation across a boundary and give
				// a number that is close but not defensible.
				Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
			},
			[]string{"method", "route"},
		),

		inFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Requests currently being served.",
		}),

		// Saturation and dependency health. Alerting on this directly is
		// usually wrong — a brief blip is not user-visible — but it is the
		// first panel you open when the error rate climbs.
		dbUp: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "app_database_up",
			Help: "1 if the last database health check succeeded, 0 otherwise.",
		}),

		dbQueryDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "app_database_query_duration_seconds",
			Help:    "Time spent in database queries.",
			Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1},
		}),

		// The value is always 1; the information lives in the labels. This is
		// the standard pattern for exposing build metadata, and it lets a
		// dashboard annotate a latency change with the deploy that caused it.
		buildInfo: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "app_build_info",
				Help: "Build metadata. Always 1; the labels carry the information.",
			},
			[]string{"version"},
		),
	}

	reg.MustRegister(
		m.requestsTotal,
		m.requestDuration,
		m.inFlight,
		m.dbUp,
		m.dbQueryDuration,
		m.buildInfo,
	)

	// Go runtime and process metrics: goroutines, heap, GC pauses, file
	// descriptors, CPU. Free to collect and the first thing worth checking
	// when a pod is restarting for no obvious reason.
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

func (m *Metrics) ObserveDBQuery(d time.Duration) {
	m.dbQueryDuration.Observe(d.Seconds())
}

// statusRecorder captures the status code, which the standard
// http.ResponseWriter does not expose after the fact.
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
		m.requestDuration.WithLabelValues(r.Method, route).Observe(elapsed)
		m.requestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
	})
}