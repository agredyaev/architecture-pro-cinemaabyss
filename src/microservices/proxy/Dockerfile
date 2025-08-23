# syntax=docker/dockerfile:1.7

FROM golang:1.24-alpine AS builder

WORKDIR /src

RUN apk add --no-cache ca-certificates tzdata

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOMODCACHE=/go/pkg/mod

COPY go.mod ./
COPY go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

COPY . .

ARG VERSION=dev
ARG COMMIT=unknown

RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags="-s -w -X 'main.version=${VERSION}' -X 'main.commit=${COMMIT}'" \
    -o /out/proxy-service .

FROM gcr.io/distroless/static:nonroot

WORKDIR /app

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

COPY --from=builder /out/proxy-service ./proxy-service

EXPOSE 8000

USER nonroot:nonroot

ENTRYPOINT ["/app/proxy-service"]
