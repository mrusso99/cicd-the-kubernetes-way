# Example 1b — an application that must fail the Trivy gate.
#
# The same program as the golden path, built on a base image frozen in 2021. It
# carries CRITICAL and HIGH vulnerabilities that already have fixes, which is
# exactly what
#
#   trivy image --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed
#
# refuses. buildkit still builds and pushes the image (it did its job); what
# stops is everything after the gate, including the declaration to Tekton Chains.
FROM golang:1.16-alpine

WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./main.go

EXPOSE 8080
ENTRYPOINT ["/out/app"]
