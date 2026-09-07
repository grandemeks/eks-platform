package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config is populated entirely from the environment, so one image is promoted
// unchanged from a laptop to the cluster.
type Config struct {
	Port            string
	ShutdownTimeout time.Duration

	DBHost     string
	DBPort     string
	DBName     string
	DBUser     string
	DBPassword string
	DBSSLMode  string

	// Version becomes an app_build_info label, so a dashboard can tie a latency
	// change to the build that caused it.
	Version string

	// Identifies this service in Tempo and on the service graph.
	ServiceName string

	// Span resource attribute; separates dev from prod in a shared backend.
	Environment string
}

func LoadConfig() (Config, error) {
	c := Config{
		Port:            env("PORT", "8080"),
		ShutdownTimeout: time.Duration(envInt("SHUTDOWN_TIMEOUT_SECONDS", 15)) * time.Second,

		DBHost: os.Getenv("DB_HOST"),
		DBPort: env("DB_PORT", "5432"),
		DBName: env("DB_NAME", "demo"),
		DBUser: os.Getenv("DB_USER"),

		// Injected from a Secret that External Secrets syncs from AWS Secrets
		// Manager; never in this repo, the image, or Terraform state.
		DBPassword: os.Getenv("DB_PASSWORD"),

		// require, not verify-full: verifying would mean shipping the RDS CA
		// bundle in the image. Still encrypted, and the hop stays in the VPC.
		DBSSLMode: env("DB_SSLMODE", "require"),

		Version:     env("APP_VERSION", "dev"),
		ServiceName: env("OTEL_SERVICE_NAME", "demo-app"),
		Environment: env("OTEL_DEPLOYMENT_ENVIRONMENT", "dev"),
	}

	// Fail fast: a pod without DB config passes liveness and serves errors
	// quietly, which is harder to spot than a CrashLoopBackOff.
	for name, value := range map[string]string{
		"DB_HOST":     c.DBHost,
		"DB_USER":     c.DBUser,
		"DB_PASSWORD": c.DBPassword,
	} {
		if value == "" {
			return Config{}, fmt.Errorf("required environment variable %s is not set", name)
		}
	}

	return c, nil
}

// DSN returns the pgx connection string. Never log it: it carries the password.
func (c Config) DSN() string {
	return fmt.Sprintf(
		"host=%s port=%s dbname=%s user=%s password=%s sslmode=%s",
		c.DBHost, c.DBPort, c.DBName, c.DBUser, c.DBPassword, c.DBSSLMode,
	)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}
