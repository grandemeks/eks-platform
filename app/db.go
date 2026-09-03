package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Store struct {
	pool *pgxpool.Pool
}

// NewStore opens a connection pool. It does not verify the database is
// reachable — that is deliberate. A pod whose database is briefly unavailable
// at startup should come up and report itself unready, not crash. Readiness is
// what keeps it out of the load balancer until the dependency recovers.
func NewStore(ctx context.Context, dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}

	// Sized for a db.t4g.micro, which allows roughly 80 connections in total.
	// Two replicas at 10 each leaves ample room for migrations and psql.
	cfg.MaxConns = 10
	cfg.MinConns = 2

	// Recycle connections so a failed-over database does not leave the pool
	// holding sockets to an instance that no longer exists.
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create connection pool: %w", err)
	}

	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

// Ping is what the readiness probe calls. The caller supplies a timeout so a
// hung database produces a failed probe rather than a probe that never returns.
func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

// Migrate creates the schema if it is not already there.
//
// Running migrations from the application at startup is the right size for
// this service: one table, idempotent, and it means a fresh database works
// with no manual step, which is what makes `terraform destroy` followed by
// `terraform apply` reproduce a working system. A service with real schema
// evolution would use a dedicated tool and a Kubernetes Job or init container,
// so that N replicas starting at once do not race each other.
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

// RecordVisit writes a row and returns the running totals in a single round
// trip.
//
// The +1 is not a fudge. Every sub-statement of a WITH clause runs against the
// same snapshot, so the totals CTE cannot see the row that the inserted CTE is
// writing alongside it — a data-modifying CTE and its siblings do not observe
// each other's effects. The count therefore reflects the state before this
// visit, and the row just written is added explicitly. Without it the counter
// reports one visit behind forever, which is exactly what local testing showed.
//
// coalesce covers the first-ever visit, when the totals CTE finds no rows and
// min(created_at) is NULL.
func (s *Store) RecordVisit(ctx context.Context, source string) (VisitResult, error) {
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

	var r VisitResult
	err := s.pool.QueryRow(ctx, query, source).Scan(&r.Total, &r.First)
	if err != nil {
		return VisitResult{}, fmt.Errorf("record visit: %w", err)
	}
	return r, nil
}