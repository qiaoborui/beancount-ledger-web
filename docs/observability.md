# Observability

Beancount Ledger Web can expose low-overhead Prometheus metrics on a dedicated
HTTP listener. The listener is disabled by default and is not registered on the
public application router, so enabling metrics does not bypass or modify the
application's existing authentication.

## Start locally

Enable the listener when starting either `ledger-web` or `ledger-selfhost`:

```bash
METRICS_ADDR=127.0.0.1:9091 <your normal server command>
```

That loopback example assumes the Go process runs on the host. For the
self-hosted Compose server, bind `:9091` inside the container, set
`METRICS_ALLOW_NON_LOOPBACK=true`, and either attach a collector to its private
Compose network or publish only `127.0.0.1:9091:9091` through a local override.
Do not publish the port on all host interfaces.

For a host managed by `beancount-ledger-deploy-run`, install the opt-in files
once so later immutable-image deployments preserve the listener and loopback
port mapping:

```bash
sudo install -m 644 -o root -g root \
  docker/docker-compose.selfhost-observability.yml \
  /etc/beancount-ledger-selfhost/compose.observability.yml
sudo install -m 600 -o root -g root \
  docker/selfhost-observability.env \
  /etc/beancount-ledger-selfhost/observability.env
sudo install -m 755 -o root -g root \
  scripts/selfhost/beancount-ledger-deploy-run \
  /usr/local/sbin/beancount-ledger-deploy-run
sudo docker compose \
  -p beancount-ledger-selfhost \
  --env-file /etc/beancount-ledger-selfhost/runtime.env \
  --env-file /var/lib/beancount-ledger-deploy/releases/current.env \
  --env-file /etc/beancount-ledger-selfhost/observability.env \
  -f /etc/beancount-ledger-selfhost/compose.yml \
  -f /etc/beancount-ledger-selfhost/compose.observability.yml \
  up -d --no-deps --no-build server
```

The deployer treats these files as an all-or-nothing pair, validates their root
ownership and modes, and includes them during normal deployment, recovery, and
rollback. Removing both files and redeploying returns the server to disabled
metrics.

On Linux, start the local Prometheus and Grafana stack from the repository root:

```bash
docker compose -f docker/docker-compose.observability.yml up -d
```

The Compose stack uses host networking so Prometheus can scrape the loopback-only
application listener without making it reachable from the LAN. It binds both UIs
to loopback as well:

- Prometheus: <http://127.0.0.1:9090>
- Grafana: <http://127.0.0.1:3001> (anonymous local Viewer access)

If either UI port is already occupied, override it without editing tracked
configuration:

```bash
PROMETHEUS_PORT=19090 GRAFANA_PORT=13001 \
  docker compose -f docker/docker-compose.observability.yml up -d
```

Grafana can be exposed to one trusted LAN interface without exposing Prometheus
or the application metrics listener. Set the host's exact LAN address rather
than `0.0.0.0`:

```bash
GRAFANA_BIND_ADDRESS=192.168.31.47 GRAFANA_PORT=13001 \
  docker compose -f docker/docker-compose.observability.yml up -d grafana
```

Grafana uses anonymous Viewer access in this local stack. Only use this setting
on a trusted LAN, keep the host firewall restricted, and return to the default
loopback binding when LAN access is no longer needed.

Grafana automatically provisions the Prometheus datasource and the
`Ledger Web / Beancount Ledger Web · Overview` dashboard. The dashboard covers
throughput, 4xx/5xx rate, p50/p95/p99 request latency, in-flight requests, p95 by
route, cache hit ratios, and key ledger read/parse operation latency.

## Configuration and endpoint

`METRICS_ADDR` accepts an explicit `host:port` listen address. An empty value
disables collection and the metrics listener. Loopback addresses such as
`127.0.0.1:9091`, `[::1]:9091`, and `localhost:9091` are accepted directly.

Non-loopback and wildcard addresses are rejected unless the operator also sets:

```bash
METRICS_ALLOW_NON_LOOPBACK=true
```

That opt-in exists for container sidecars or private monitoring networks; it is
not an authentication mechanism. The dedicated listener serves only
`GET /metrics`. It has short HTTP timeouts, a small header limit, and limits
concurrent scrapes.

The application exports:

- `beancount_ledger_web_http_requests_total{method,route,status}`
- `beancount_ledger_web_http_request_duration_seconds{method,route}`
- `beancount_ledger_web_http_requests_in_flight{method,route}`
- `beancount_ledger_web_ledger_cache_requests_total{cache,result}`
- `beancount_ledger_web_ledger_operations_total{operation,result}`
- `beancount_ledger_web_ledger_operation_duration_seconds{operation,result}`
- standard Go runtime and process collectors

HTTP `route` is always Gin's registered route template (for example,
`/api/ledger/imports/pending/:id`). Unmatched requests use `unmatched`, and
unknown methods use `OTHER`. Internal labels come from fixed code constants.
Metrics never contain ledger roots or filenames, account names, transaction or
query text, URL query values, user identifiers, cookies, credentials, or tokens.
Ledger entity counts are intentionally not exported.

## Verify

With the application running and metrics enabled:

```bash
curl -fsS http://127.0.0.1:9091/metrics | grep '^beancount_ledger_web_'
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS 'http://127.0.0.1:9090/api/v1/targets?state=active'
```

The collector and cache tests use `examples/minimal-ledger`, so validation does
not require private financial data:

```bash
cd server
go test ./internal/app -run 'Test(Metrics|LedgerMetrics)'
```

## Stop locally

Stop the monitoring containers while preserving their local time-series data:

```bash
docker compose -f docker/docker-compose.observability.yml down
```

Add `-v` only when you also want to delete the local Prometheus and Grafana
volumes.

## Production boundary

Keep metrics disabled unless a collector needs them. Prefer a loopback listener
scraped by a sidecar. If Prometheus must connect over a container or cluster
network, set `METRICS_ALLOW_NON_LOOPBACK=true` deliberately and restrict the
listener with firewall rules, a private network, or Kubernetes NetworkPolicy.
Do not route it through Caddy, a public load balancer, or Cloud Run ingress, and
do not publish the metrics port from Docker by default. Prometheus metrics have
no application-level authentication; network isolation is the security boundary.
