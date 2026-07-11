# ── Backend build ──
FROM golang:1.25-bookworm AS go-builder
WORKDIR /app/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app/ledger-web ./cmd/ledger-web
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app/ledger-indexer ./cmd/ledger-indexer

# ── API runtime ──
FROM alpine:3.22 AS server
WORKDIR /app
ENV GIN_MODE=release
ENV SERVE_STATIC=false

RUN apk add --no-cache ca-certificates \
  && addgroup -S ledger \
  && adduser -S -G ledger ledger

COPY --from=go-builder /app/ledger-web /app/ledger-web
COPY examples /app/examples
USER ledger

EXPOSE 3000
CMD ["/app/ledger-web"]

# ── One-shot ledger indexer ──
FROM debian:bookworm-slim AS indexer
WORKDIR /app
ENV GIN_MODE=release

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    python3 \
    python3-pip \
    git \
    poppler-utils \
  && rm -rf /var/lib/apt/lists/* \
  && pip3 install --break-system-packages beancount==3.2.3

COPY --from=go-builder /app/ledger-indexer /app/ledger-indexer
CMD ["/app/ledger-indexer"]

# ── Frontend build ──
FROM node:24-bookworm-slim AS web-builder
WORKDIR /app/web
RUN npm install -g pnpm@11.5.0
COPY web/pnpm-lock.yaml web/package.json ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm run build

# ── Static SPA ──
FROM nginx:1.27-alpine AS frontend
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web-builder /app/web/dist /srv

# ── HTTPS edge proxy ──
FROM caddy:2-alpine AS caddy
COPY docker/Caddyfile /etc/caddy/Caddyfile

# Preserve the original single-container image for direct Docker builds.
FROM server AS standalone
ENV SERVE_STATIC=true
ENV STATIC_DIR=/app/web-dist
COPY --from=web-builder /app/web/dist /app/web-dist
