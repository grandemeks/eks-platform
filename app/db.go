package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel/attribute"
)

type Store struct {
	pool *pgxpool.Pool
}

// NewStore opens a connection pool without verifying the database is reachable,
// so a DB outage at startup makes the pod unready rather than crash-looping.
func NewStore(ctx context.Context, dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}

	// db.t4g.micro allows ~80 connections; two replicas at 10 leaves room for
	// migrations and psql.
	cfg.MaxConns = 10
	cfg.MinConns = 2

	// Recycle, so a failover does not leave the pool holding sockets to an
	// instance that is gone.
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create connection pool: %w", err)
	}

	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

// Ping backs the readiness probe. ctx must carry a deadline, or a hung database
// gives a probe that never returns instead of one that fails.
func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

// Migrate creates the schema if it is absent.
//
// Idempotent DDL, so a fresh database needs no manual step. Real schema
// evolution needs a migration tool run from a Job, so that replicas starting
// together do not race.
func (s *Store) Migrate(ctx context.Context) error {
	const schema = `
		CREATE TABLE IF NOT EXISTS visits (
			id         BIGSERIAL PRIMARY KEY,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
			source     TEXT        NOT NULL
		);
		CREATE INDEX IF NOT EXISTS visits_created_at_idx ON visits (created_at DESC);
	`

	if _, err := s.pool.Exec(ctx, schema); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	return nil
}

type VisitResult struct {
	Total int64     `json:"total_visits"`
	First time.Time `json:"first_visit"`
}

// RecordVisit writes a row and returns the running totals in one round trip.
//
// The +1 is required: sibling CTEs share one snapshot, so totals cannot see the
// row inserted alongside it and the count is one behind without it. coalesce
// covers the first visit, where min(created_at) over an empty table is NULL.
func (s *Store) RecordVisit(ctx context.Context, source string) (VisitResult, error) {
	// Child span, or the request's DB time is hidden inside the server span.
	// Instrumenting the driver would cover every query; overkill for one.
	ctx, span := tracer.Start(ctx, "db.record_visit")
	defer span.End()

	const query = `
		WITH inserted AS (
			INSERT INTO visits (source) VALUES ($1) RETURNING created_at
		),
		totals AS (
			SELECT count(*) AS c, min(created_at) AS m FROM visits
		)
		SELECT totals.c + 1, coalesce(totals.m, inserted.created_at)
		FROM totals, inserted;
	`

	span.SetAttributes(
		attribute.String("db.system", "postgresql"),
		attribute.String("db.operation", "INSERT"),
		attribute.String("db.sql.table", "visits"),
	)

	var r VisitResult
	if err := s.pool.QueryRow(ctx, query, source).Scan(&r.Total, &r.First); err != nil {
		// An unrecorded error leaves the span looking successful in Tempo and in
		// the metrics generator's RED metrics.
		span.RecordError(err)
		return VisitResult{}, fmt.Errorf("record visit: %w", err)
	}

	span.SetAttributes(attribute.Int64("db.rows_total", r.Total))
	return r, nil
}
