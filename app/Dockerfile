# syntax=docker/dockerfile:1

# --- build stage --------------------------------------------------------------
FROM golang:1.25-alpine AS build

WORKDIR /src

# Dependencies are copied and downloaded before the source. Docker caches this
# layer on the checksum of these two files, so editing application code does
# not re-download the module graph on every build.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev

# CGO_ENABLED=0 produces a statically linked binary with no libc dependency,
# which is what allows the final image to be a distroless static base.
# -trimpath strips local filesystem paths from the binary, so the image does
# not leak the directory layout of the machine that built it.
# -s -w drop the symbol table and DWARF debug info, cutting binary size by
# roughly a third.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.Version=${VERSION}" \
    -o /out/app .

# --- runtime stage ------------------------------------------------------------
# Distroless static: no shell, no package manager, no busybox. An attacker who
# achieves code execution inside this container has no tooling to work with.
# It also means the image has essentially no CVE surface of its own, so a Trivy
# scan reports only what our own dependencies bring.
FROM gcr.io/distroless/static-debian12:nonroot

# The nonroot tag runs as UID 65532. Declared explicitly here as well so the
# constraint is visible without inspecting the base image, and so it matches
# the securityContext in the Kubernetes manifest.
USER 65532:65532

COPY --from=build /out/app /app

EXPOSE 8080

# Exec form, so the binary is PID 1 and receives SIGTERM directly. With the
# shell form the signal would go to /bin/sh, which distroless does not have,
# and graceful shutdown would never run.
ENTRYPOINT ["/app"]