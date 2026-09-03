package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config is populated entirely from the environment. Nothing about where this
// runs is compiled into the binary, so the same image is promoted unchanged
// from a laptop to the cluster — the twelve-factor rule that makes an image
// reproducible.
type Config struct {
	Port            string
	ShutdownTimeout time.Duration

	DBHost     string
	DBPort     string
	DBName     string
	DBUser     string
	DBPassword string
	DBSSLMode  string

	// Version is stamped in at build time via -ldflags and exported as a
	// metric label, so a dashboard can show which build served a request.
	Version string
}

func LoadConfig() (Config, error) {
	c := Config{
		Port:            env("PORT", "8080"),
		ShutdownTimeout: time.Duration(envInt("SHUTDOWN_TIMEOUT_SECONDS", 15)) * time.Second,

		DBHost: os.Getenv("DB_HOST"),
		DBPort: env("DB_PORT", "5432"),
		DBName: env("DB_NAME", "demo"),
		DBUser: os.Getenv("DB_USER"),

		// Read from the environment, which Kubernetes populates from a Secret
		// that External Secrets syncs out of AWS Secrets Manager. The password
		// never exists in this repository, in the image, or in Terraform state.
		DBPassword: os.Getenv("DB_PASSWORD"),

		// require rather than verify-full: RDS presents a certificate signed by
		// the Amazon RDS CA, and verifying it would mean shipping that bundle
		// into the image. Traffic is encrypted either way; this trades
		// certificate pinning for a simpler image, and the connection never
		// leaves the VPC.
		DBSSLMode: env("DB_SSLMODE", "require"),

		Version: env("APP_VERSION", "dev"),
	}

	// Fail fast and loudly. A pod that starts without a database configured
	// would pass its liveness probe and quietly serve errors, which is worse
	// than a CrashLoopBackOff that is visible in one kubectl command.
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

// DSN never appears in a log line: the password would travel with it.
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