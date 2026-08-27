# Defaults keep direct legacy Docker builds usable; BuildKit overrides these
# automatic platform arguments for multi-architecture CI builds.
ARG BUILDPLATFORM=linux/amd64
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VCS_REF=local

# ── Bub Agent runtime ──
FROM python:3.12-slim-bookworm AS agent-builder
WORKDIR /app/agent
RUN apt-get update \
  && apt-get install -y --no-install-recommends git \
  && rm -rf /var/lib/apt/lists/* \
  && pip install --no-cache-dir uv==0.8.14
COPY agent/pyproject.toml agent/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY agent/src ./src
RUN uv sync --frozen --no-dev

FROM python:3.12-slim-bookworm AS agent
ARG VCS_REF
LABEL org.opencontainers.image.revision=$VCS_REF
WORKDIR /app/agent
ENV PATH=/app/agent/.venv/bin:$PATH
ENV PYTHONUNBUFFERED=1
RUN groupadd --system ledger \
  && useradd --system --gid ledger --home-dir /app/agent ledger \
  && mkdir -p /app/agent/.bub \
  && chown ledger:ledger /app/agent/.bub
COPY --from=agent-builder --chown=ledger:ledger /app/agent/.venv /app/agent/.venv
COPY --from=agent-builder --chown=ledger:ledger /app/agent/src /app/agent/src
COPY --chown=ledger:ledger .agents/skills /app/agent/.agents/skills
USER ledger
EXPOSE 8080
CMD ["ledger-agent"]

# ── Backend build ──
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm AS go-builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /app/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /app/ledger-web ./cmd/ledger-web
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /app/ledger-selfhost ./cmd/ledger-selfhost
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /app/ledger-indexer ./cmd/ledger-indexer
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /app/ledger-indexer-daemon ./cmd/ledger-indexer-daemon
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /app/zip-worker ./cmd/zip-worker

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

# ── Private ZIP password worker ──
FROM alpine:3.22 AS zip-worker
ARG VCS_REF
LABEL org.opencontainers.image.revision=$VCS_REF
WORKDIR /app

RUN apk add --no-cache ca-certificates \
  && addgroup -S ledger \
  && adduser -S -G ledger ledger

COPY --from=go-builder /app/zip-worker /app/zip-worker
USER ledger

EXPOSE 8080
CMD ["/app/zip-worker"]

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

# ── Complete self-hosted runtime base ──
FROM indexer AS selfhost-base
ARG LEDGER_UID=1000
ARG LEDGER_GID=1000
RUN groupadd --gid "$LEDGER_GID" ledger \
  && useradd --uid "$LEDGER_UID" --gid ledger --create-home --shell /usr/sbin/nologin ledger
COPY --from=go-builder /app/ledger-indexer-daemon /app/ledger-indexer-daemon
USER ledger

# ── Recurring self-hosted indexer ──
FROM selfhost-base AS selfhost-indexer
ARG VCS_REF
LABEL org.opencontainers.image.revision=$VCS_REF
CMD ["/app/ledger-indexer-daemon"]

# ── Complete self-hosted API ──
# This image includes bean-check because local ledger writes validate and roll
# back within the user's own mounted ledger directory.
FROM selfhost-base AS selfhost-server
ARG VCS_REF
LABEL org.opencontainers.image.revision=$VCS_REF
COPY --from=go-builder /app/ledger-selfhost /app/ledger-selfhost
EXPOSE 3000
CMD ["/app/ledger-selfhost"]

# ── Frontend build ──
FROM --platform=$BUILDPLATFORM node:24-bookworm-slim AS web-builder
ARG VITE_ENABLE_SPEED_INSIGHTS=true
ENV VITE_ENABLE_SPEED_INSIGHTS=$VITE_ENABLE_SPEED_INSIGHTS
WORKDIR /app/web
RUN npm install -g pnpm@11.5.0
COPY web/pnpm-lock.yaml web/package.json ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm run build

# ── Static SPA ──
FROM nginx:1.27-alpine AS frontend
ARG VCS_REF
LABEL org.opencontainers.image.revision=$VCS_REF
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
