# ── Frontend build ──
FROM node:24-bookworm-slim AS web-builder
WORKDIR /app/web
RUN npm install -g pnpm@11.5.0
COPY web/pnpm-lock.yaml web/package.json ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm run build

# ── Backend build ──
FROM golang:1.25-bookworm AS go-builder
WORKDIR /app/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app/ledger-web ./cmd/ledger-web
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app/ledger-indexer ./cmd/ledger-indexer

# ── Runtime ──
FROM debian:bookworm-slim
WORKDIR /app
ENV GIN_MODE=release
ENV SERVE_STATIC=true
ENV STATIC_DIR=/app/web-dist

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    python3 \
    python3-pip \
    git \
    poppler-utils \
  && rm -rf /var/lib/apt/lists/* \
  && pip3 install --break-system-packages beancount==3.2.3

COPY --from=go-builder /app/ledger-web /app/ledger-web
COPY --from=go-builder /app/ledger-indexer /app/ledger-indexer
COPY --from=web-builder /app/web/dist /app/web-dist
COPY examples /app/examples

EXPOSE 3000
CMD ["/app/ledger-web"]
