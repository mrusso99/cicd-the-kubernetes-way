# Multi-stage build: the final image is distroless, so the Trivy gate has a
# deterministic (and clean) target to scan.
#
# The builder tag is part of the gate: an old toolchain bakes its own CVEs into
# the binary, and the scan is right to fail the run.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./main.go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
