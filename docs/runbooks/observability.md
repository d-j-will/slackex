# Observability Stack Runbook

## Architecture

```
App (Elixir) ──OTLP──▶ OTEL Collector ──▶ Tempo (traces)
     │                       │
     │ /metrics              ▼
     ▼                  Prometheus (OTEL metrics)
Prometheus (scrape) ◀────────┘
     │
     ▼
  Grafana (dashboards)
```

**Two data paths:**
1. **Traces:** App pushes spans via OTLP HTTP to Collector → Collector forwards to Tempo
2. **Metrics:** Prometheus scrapes `/metrics` from app nodes every 15s. Collector also exports OTEL metrics to Prometheus.

## Known Gotchas

### TelemetryMetricsPrometheus.Core metric naming

`TelemetryMetricsPrometheus.Core` does **NOT** append unit suffixes to metric names.

| You might expect | Actual name |
|------------------|-------------|
| `vm_memory_total_bytes` | `vm_memory_total` |
| `phoenix_endpoint_stop_duration_milliseconds_bucket` | `phoenix_endpoint_stop_duration_bucket` |
| `slackex_repo_query_total_time_milliseconds_sum` | `slackex_repo_query_total_time_sum` |

**Always verify metric names against `curl localhost:4000/metrics` before writing PromQL queries.**

### TelemetryMetricsPrometheus.Core metric types

- `summary` type is **NOT supported** — use `distribution` (becomes Prometheus histogram) or `last_value` (becomes gauge)
- `distribution` requires explicit `reporter_options: [buckets: [...]]` or the GenServer crashes on startup

### Grafana datasource provisioning

- Always set explicit `uid` fields in datasource YAML from the start
- Changing UIDs after first boot requires deleting the Grafana volume: `docker volume rm <project>_grafana_data`
- Dashboard JSON must reference datasources by `{"type": "prometheus", "uid": "prometheus"}` matching the provisioned UID

### /metrics endpoint security

- In production, `/metrics` is restricted to private network IPs (10.x, 172.16-31.x, 192.168.x, 127.x)
- Docker internal networks use 172.x ranges — Prometheus can reach it
- External access via Caddy does not reach `/metrics` (returns 403)

## Local Development

```bash
# Start observability stack (from project root or worktree)
docker compose -f docker-compose.observability.yml up -d

# Start app with OTEL export
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 mix phx.server

# Verify
curl localhost:4000/metrics          # Raw Prometheus metrics
open http://localhost:9090            # Prometheus UI
open http://localhost:3001            # Grafana (admin/admin)
```

**Dev Prometheus** uses `host.docker.internal:4000` to scrape the locally-running app.

## Production Deployment

The observability services are defined in `docker-compose.prod.yml`:

```bash
# First deploy — pull images
docker compose -f docker-compose.prod.yml pull otel-collector prometheus tempo grafana

# Start (alongside existing app services)
docker compose -f docker-compose.prod.yml up -d
```

**Environment variables** (set in `.env` or docker-compose):
- `GRAFANA_ADMIN_PASSWORD` — defaults to "admin" if not set
- `OTEL_EXPORTER_OTLP_ENDPOINT` — pre-configured to `http://otel-collector:4318` in compose

**Memory budget** (on 20GB LXC host with 2x 2GB app containers):
- OTEL Collector: 256MB
- Prometheus: 256MB (14-day retention, 2GB storage cap)
- Tempo: 256MB (7-day trace retention)
- Grafana: 128MB
- **Total: 896MB additional**

### Post-deploy verification

1. Check all targets are up: `curl prometheus:9090/api/v1/targets`
2. Query `up` in Prometheus — all jobs should show `1`
3. Open Grafana → Dashboards → Slackex → Overview — all panels should render
4. Grafana → Explore → Tempo — search for traces, verify waterfall view works

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No metrics in Prometheus | App `/metrics` unreachable | Check `docker network inspect` — app and prometheus on same network |
| No traces in Tempo | OTLP endpoint misconfigured | Check `OTEL_EXPORTER_OTLP_ENDPOINT` env var, check collector logs |
| Grafana "datasource not found" | UID mismatch | Delete grafana volume, restart |
| `summary unsupported` warnings | Wrong metric type in telemetry.ex | Use `distribution` with buckets or `last_value` |
| Collector OOM | Trace volume too high | Increase `memory_limiter` in collector config or add sampling |

## Config Files

| File | Purpose |
|------|---------|
| `infra/otel-collector-config.yaml` | Collector pipelines (OTLP → Tempo/Prometheus) |
| `infra/prometheus.yml` | Prod scrape targets (app1, app2, collector) |
| `infra/prometheus.dev.yml` | Dev scrape target (host.docker.internal) |
| `infra/tempo.yaml` | Trace storage config (local, 7-day retention) |
| `infra/grafana/provisioning/datasources/` | Auto-provisioned Prometheus + Tempo |
| `infra/grafana/provisioning/dashboards/` | Dashboard provisioning config |
| `infra/grafana/dashboards/` | Dashboard JSON files |
| `lib/slackex_web/telemetry.ex` | Metric definitions + periodic measurements |
| `lib/slackex_web/plugs/metrics_exporter.ex` | `/metrics` endpoint plug |
