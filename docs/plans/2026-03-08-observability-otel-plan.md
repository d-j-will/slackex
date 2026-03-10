# Observability & OpenTelemetry Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add OpenTelemetry tracing and Prometheus metrics to Slackex so that application behaviour is observable via Grafana dashboards, enabling faster incident diagnosis and future MCP-based agent debugging.

**Architecture:** Phoenix/Ecto/Oban/Req auto-instrumented via OTEL contrib libraries. BEAM VM and custom application metrics exported via Prometheus. All telemetry flows to an OTEL Collector, which routes traces to Tempo and metrics to Prometheus. Grafana visualises both. Infrastructure services run as Docker containers alongside the existing app.

**Tech Stack:** OpenTelemetry Erlang SDK, opentelemetry_phoenix/ecto/oban/bandit, Prometheus, Grafana, Tempo, OTEL Collector, Docker Compose.

**Discovery Doc:** `docs/research/observability-otel-discovery-2026-03-08.md`

---

## Existing State

- `SlackexWeb.Telemetry` supervisor exists with `telemetry_poller` and metric definitions — but **no reporter consumes them**
- `Slackex.AI.Telemetry` attaches custom handlers for AI events (completion, embedding) — logs to Logger only
- `Plug.Telemetry` configured in endpoint with `[:phoenix, :endpoint]` prefix
- Bandit adapter (not Cowboy) — use `OpentelemetryBandit` + `OpentelemetryPhoenix.setup(adapter: :bandit)`
- Two app nodes in production (`app1`, `app2`), each with 2GB mem limit
- `docker-compose.prod.yml` has no monitoring services
- No `releases` config in `mix.exs` — needs adding for OTEL app start ordering
- Config files: `config.exs`, `dev.exs`, `prod.exs`, `runtime.exs`

---

## Phase 1: OTEL SDK + Automatic Instrumentation (Elixir Side)

### Task 1: Add OpenTelemetry Dependencies

**Files:**
- Modify: `mix.exs` (deps section, ~line 96-98 and project/0)

**Step 1: Add OTEL deps to mix.exs**

Add after the existing `# Telemetry` section (~line 96):

```elixir
# Telemetry
{:telemetry_metrics, "~> 1.0"},
{:telemetry_poller, "~> 1.0"},

# OpenTelemetry — tracing & metrics
{:opentelemetry_api, "~> 1.4"},
{:opentelemetry, "~> 1.5"},
{:opentelemetry_exporter, "~> 1.8"},

# OTEL automatic instrumentation
{:opentelemetry_bandit, "~> 0.2"},
{:opentelemetry_phoenix, "~> 2.0"},
{:opentelemetry_ecto, "~> 1.2"},
{:opentelemetry_oban, "~> 1.1"},
{:opentelemetry_req, "~> 0.2"},

# Prometheus metrics export
{:telemetry_metrics_prometheus_core, "~> 1.2"},
{:plug_telemetry_server_timing, "~> 0.3", only: :dev},
```

**Step 2: Add release configuration to mix.exs**

In the `project/0` function, add a `releases` key. The OTEL SDK and exporter must start **before** the app so spans are captured from the first request:

```elixir
releases: [
  slackex: [
    applications: [
      opentelemetry_exporter: :permanent,
      opentelemetry: :temporary
    ]
  ]
]
```

**Step 3: Fetch dependencies**

Run: `mix deps.get`
Expected: All new deps resolve without conflicts.

**Step 4: Compile**

Run: `mix compile`
Expected: Clean compilation, no warnings from new deps.

**Step 5: Commit**

```
feat(otel): add OpenTelemetry and Prometheus dependencies
```

---

### Task 2: Configure OTEL Exporter

**Files:**
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/prod.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

**Step 1: Add base OTEL config to config.exs**

Add before the `import_config` line:

```elixir
# OpenTelemetry — default to console exporter for dev
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: {:otel_exporter_stdout, []}
```

**Step 2: Configure dev.exs — stdout exporter for local development**

Add:

```elixir
# OpenTelemetry — log traces to console in dev
config :opentelemetry,
  traces_exporter: {:otel_exporter_stdout, []}
```

**Step 3: Configure test.exs — disable OTEL in tests**

Add:

```elixir
# Disable OpenTelemetry tracing in tests to avoid noise
config :opentelemetry,
  traces_exporter: :none
```

**Step 4: Configure prod.exs — OTLP exporter**

Add:

```elixir
# OpenTelemetry — export via OTLP to collector
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://otel-collector:4318"
```

**Step 5: Add runtime.exs override for OTEL endpoint**

Inside the `if config_env() == :prod do` block, add:

```elixir
if otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry_exporter,
    otlp_endpoint: otel_endpoint
end
```

**Step 6: Verify compilation**

Run: `MIX_ENV=prod mix compile`
Expected: No warnings.

**Step 7: Commit**

```
feat(otel): configure OTEL exporters per environment
```

---

### Task 3: Wire Up Automatic Instrumentation

**Files:**
- Modify: `lib/slackex/application.ex`

**Step 1: Add OTEL setup calls in Application.start/2**

Add the instrumentation setup calls **before** the children list, after the existing `Slackex.AI.Telemetry.attach_handlers()`:

```elixir
def start(_type, _args) do
  _ = Slackex.AI.Telemetry.attach_handlers()

  # OpenTelemetry automatic instrumentation
  OpentelemetryBandit.setup()
  OpentelemetryPhoenix.setup(adapter: :bandit)
  OpentelemetryEcto.setup([:slackex, :repo])
  OpentelemetryOban.setup()

  children =
    [
      # ... existing children unchanged
    ]
```

**Important:** The Ecto telemetry prefix must match the repo's telemetry prefix. Check `Slackex.Repo` config — Phoenix generates repos with `telemetry_prefix: [:slackex, :repo]` by default. Verify this by checking:

```elixir
# In config.exs, the repo config should have:
config :slackex, Slackex.Repo, ...
# The telemetry prefix defaults to [:slackex, :repo] based on the module name
```

**Step 2: Verify in dev**

Run: `mix phx.server`
Expected: When you hit any page, trace spans should print to stdout (from the stdout exporter). You should see spans like:
- `GET /` (Bandit/Phoenix)
- `slackex.repo.query:*` (Ecto)

**Step 3: Run tests**

Run: `mix test`
Expected: All 1132+ tests pass. OTEL is disabled in test env so no interference.

**Step 4: Commit**

```
feat(otel): wire up automatic instrumentation for Bandit, Phoenix, Ecto, Oban
```

---

### Task 4: Add Prometheus Metrics Endpoint

**Files:**
- Create: `lib/slackex_web/plugs/metrics_exporter.ex`
- Modify: `lib/slackex_web/endpoint.ex`
- Modify: `lib/slackex_web/telemetry.ex`

**Step 1: Write a test for the metrics endpoint**

**Files:**
- Create: `test/slackex_web/plugs/metrics_exporter_test.exs`

```elixir
defmodule SlackexWeb.Plugs.MetricsExporterTest do
  use SlackexWeb.ConnCase, async: true

  test "GET /metrics returns prometheus text format", %{conn: conn} do
    conn = get(conn, "/metrics")
    assert conn.status == 200
    assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
    assert content_type =~ "text/plain"
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex_web/plugs/metrics_exporter_test.exs`
Expected: FAIL — route doesn't exist.

**Step 3: Create the metrics exporter plug**

```elixir
defmodule SlackexWeb.Plugs.MetricsExporter do
  @moduledoc """
  Serves Prometheus metrics at /metrics.

  Collects metrics defined in SlackexWeb.Telemetry and formats
  them in Prometheus text exposition format.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    metrics = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end
end
```

**Step 4: Update SlackexWeb.Telemetry to start the Prometheus core reporter**

Replace the children list in `init/1`:

```elixir
def init(_arg) do
  children = [
    {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
    {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: :slackex_metrics}
  ]

  Supervisor.init(children, strategy: :one_for_one)
end
```

And update the `TelemetryMetricsPrometheus.Core.scrape()` call in the plug to use the name:

```elixir
def call(conn, _opts) do
  metrics = TelemetryMetricsPrometheus.Core.scrape(:slackex_metrics)

  conn
  |> put_resp_content_type("text/plain")
  |> send_resp(200, metrics)
end
```

**Step 5: Add the /metrics route to the endpoint**

In `lib/slackex_web/endpoint.ex`, add **before** the router plug (but after `Plug.Telemetry`):

```elixir
plug SlackexWeb.Plugs.MetricsExporter, at: "/metrics"
```

Wait — this needs to be a simple path match, not a full plug pipeline. Better approach: add it in the router as a forward, or use a simple `Plug.Router`-style match in the endpoint. Actually, simplest approach — add a route in the router:

In `lib/slackex_web/router.ex`, add a pipeline-free scope:

```elixir
# Prometheus metrics endpoint — no auth, no CSRF
scope "/metrics", SlackexWeb do
  get "/", Plugs.MetricsExporter, :call
end
```

Hmm, but MetricsExporter is a Plug, not a controller. Simplest approach: just match the path directly in the endpoint before the router:

```elixir
# In endpoint.ex, before `plug SlackexWeb.Router`:
plug :maybe_metrics

# ... at the bottom of the module:
defp maybe_metrics(%{request_path: "/metrics"} = conn, _opts) do
  metrics = TelemetryMetricsPrometheus.Core.scrape(:slackex_metrics)

  conn
  |> Plug.Conn.put_resp_content_type("text/plain")
  |> Plug.Conn.send_resp(200, metrics)
  |> Plug.Conn.halt()
end

defp maybe_metrics(conn, _opts), do: conn
```

This avoids the router entirely — Prometheus scrapes `/metrics` directly and it bypasses auth/CSRF.

**Step 6: Run the test**

Run: `mix test test/slackex_web/plugs/metrics_exporter_test.exs`
Expected: PASS.

**Step 7: Verify manually in dev**

Run: `mix phx.server`
Visit: `http://localhost:4000/metrics`
Expected: Prometheus text format output with metrics like `phoenix_endpoint_stop_duration_milliseconds`.

**Step 8: Run full test suite**

Run: `mix test`
Expected: All tests pass.

**Step 9: Commit**

```
feat(otel): add Prometheus metrics endpoint at /metrics
```

---

### Task 5: Add Custom BEAM VM Metrics

**Files:**
- Modify: `lib/slackex_web/telemetry.ex`

**Step 1: Add BEAM VM metrics to the metrics list**

Add to the `metrics/0` function:

```elixir
# BEAM VM Metrics
last_value("vm.memory.total", unit: :byte),
last_value("vm.memory.processes", unit: :byte),
last_value("vm.memory.binary", unit: :byte),
last_value("vm.memory.ets", unit: :byte),
last_value("vm.memory.atom", unit: :byte),
last_value("vm.system_counts.process_count"),
last_value("vm.system_counts.port_count"),
last_value("vm.total_run_queue_lengths.total"),
last_value("vm.total_run_queue_lengths.cpu"),
last_value("vm.total_run_queue_lengths.io"),
```

**Step 2: Add custom periodic measurements**

Update `periodic_measurements/0`:

```elixir
defp periodic_measurements do
  [
    {SlackexWeb.Telemetry, :measure_oban_queue_depth, []},
    {SlackexWeb.Telemetry, :measure_connected_users, []}
  ]
end
```

**Step 3: Implement the measurement functions**

Add to `SlackexWeb.Telemetry`:

```elixir
@doc false
def measure_oban_queue_depth do
  case Oban.check_queue(queue: :default) do
    %{running: running, available: available} ->
      :telemetry.execute(
        [:slackex, :oban, :queue_depth],
        %{running: running, available: available},
        %{queue: :default}
      )
    _ ->
      :ok
  end
end

@doc false
def measure_connected_users do
  count = SlackexWeb.Presence |> Phoenix.Presence.list() |> map_size()
  :telemetry.execute([:slackex, :presence, :connected_users], %{count: count}, %{})
rescue
  _ -> :ok
end
```

And add corresponding metrics:

```elixir
# Application Metrics
last_value("slackex.oban.queue_depth.running", tags: [:queue]),
last_value("slackex.oban.queue_depth.available", tags: [:queue]),
last_value("slackex.presence.connected_users.count"),
```

**Step 4: Verify in dev**

Run: `mix phx.server`
Visit: `http://localhost:4000/metrics`
Expected: See `vm_memory_total_bytes`, `slackex_presence_connected_users_count` etc.

**Step 5: Run tests**

Run: `mix test`
Expected: All pass.

**Step 6: Commit**

```
feat(otel): add BEAM VM and application metrics
```

---

### Task 6: Add Req Instrumentation for External HTTP Calls

**Files:**
- Modify: `lib/slackex/ai/openai_compatible_client.ex` (or wherever Req is called)

**Step 1: Check how Req is used**

Search for `Req.post`, `Req.get`, `Req.new` in the codebase to find where external HTTP calls are made (DeepInfra, link previews, etc.).

`opentelemetry_req` works as a Req plugin. Attach it to Req calls:

```elixir
Req.new(url: url)
|> OpentelemetryReq.attach()
|> Req.post(json: body)
```

Or configure it globally if there's a shared Req client module.

**Step 2: Verify traces include outbound HTTP**

Run: `mix phx.server`
Trigger an action that calls DeepInfra (e.g., a summarisation or embedding request).
Expected: Stdout trace output includes a span for the outbound HTTP call.

**Step 3: Run tests**

Run: `mix test`
Expected: All pass.

**Step 4: Commit**

```
feat(otel): instrument outbound Req HTTP calls with OpenTelemetry
```

---

## Phase 2: Infrastructure (Docker Side)

### Task 7: Create OTEL Collector Configuration

**Files:**
- Create: `infra/otel-collector-config.yaml`

**Step 1: Create the infra directory**

Run: `mkdir -p infra`

**Step 2: Create the collector config**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024

  memory_limiter:
    check_interval: 1s
    limit_mib: 256

exporters:
  otlphttp/tempo:
    endpoint: http://tempo:4318

  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: slackex

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

**Step 3: Commit**

```
feat(infra): add OTEL Collector configuration
```

---

### Task 8: Create Prometheus Configuration

**Files:**
- Create: `infra/prometheus.yml`

**Step 1: Create Prometheus config**

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Scrape Slackex app nodes directly
  - job_name: "slackex"
    static_configs:
      - targets: ["app1:4000", "app2:4000"]
    metrics_path: /metrics

  # Scrape OTEL Collector's Prometheus exporter
  - job_name: "otel-collector"
    static_configs:
      - targets: ["otel-collector:8889"]

  # Scrape Prometheus itself
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
```

**Step 2: Commit**

```
feat(infra): add Prometheus scrape configuration
```

---

### Task 9: Create Tempo Configuration

**Files:**
- Create: `infra/tempo.yaml`

**Step 1: Create Tempo config**

```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        http:
          endpoint: 0.0.0.0:4318
        grpc:
          endpoint: 0.0.0.0:4317

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
    pool:
      max_workers: 10
      queue_depth: 100

  # 7-day retention
  block:
    retention: 168h

metrics_generator:
  processor:
    service_graphs:
      dimensions: ["service.name"]
    span_metrics:
      dimensions: ["service.name", "http.method", "http.route", "http.status_code"]
  storage:
    path: /var/tempo/metrics
    remote_write:
      - url: http://prometheus:9090/api/v1/write
```

**Step 2: Commit**

```
feat(infra): add Tempo trace storage configuration
```

---

### Task 10: Create Grafana Provisioning

**Files:**
- Create: `infra/grafana/provisioning/datasources/datasources.yaml`

**Step 1: Create datasource provisioning**

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false

  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    editable: false
    jsonData:
      tracesToMetrics:
        datasourceUid: prometheus
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
```

**Step 2: Commit**

```
feat(infra): add Grafana datasource provisioning
```

---

### Task 11: Add Observability Services to Docker Compose

**Files:**
- Modify: `docker-compose.prod.yml`

**Step 1: Add OTEL Collector, Prometheus, Grafana, Tempo**

Add to the `services:` section:

```yaml
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    restart: unless-stopped
    mem_limit: 256m
    volumes:
      - ./infra/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml
    ports:
      - "4317:4317"   # OTLP gRPC
      - "4318:4318"   # OTLP HTTP
    networks:
      - default

  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    mem_limit: 256m
    volumes:
      - ./infra/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=14d'
      - '--storage.tsdb.retention.size=2GB'
      - '--web.enable-remote-write-receiver'
    networks:
      - default

  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    mem_limit: 128m
    ports:
      - "3001:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD:-admin}"
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./infra/grafana/provisioning:/etc/grafana/provisioning
    depends_on:
      - prometheus
      - tempo
    networks:
      - default

  tempo:
    image: grafana/tempo:latest
    restart: unless-stopped
    mem_limit: 256m
    command: ["-config.file=/etc/tempo.yaml"]
    volumes:
      - ./infra/tempo.yaml:/etc/tempo.yaml
      - tempo_data:/var/tempo
    networks:
      - default
```

**Step 2: Add volumes**

Add to the `volumes:` section:

```yaml
  prometheus_data:
  grafana_data:
  tempo_data:
```

**Step 3: Add OTEL endpoint env var to app defaults**

In the `x-app` environment section (`&app-env`), add:

```yaml
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4318"
    OTEL_SERVICE_NAME: "slackex"
```

**Step 4: Commit**

```
feat(infra): add OTEL Collector, Prometheus, Grafana, Tempo to Docker Compose
```

---

## Phase 3: Verification & Dashboard

### Task 12: Create a Basic Grafana Dashboard (as code)

**Files:**
- Create: `infra/grafana/provisioning/dashboards/dashboard.yaml`
- Create: `infra/grafana/dashboards/slackex-overview.json`

**Step 1: Create dashboard provisioning config**

```yaml
apiVersion: 1

providers:
  - name: "Slackex"
    orgId: 1
    folder: "Slackex"
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

**Step 2: Update Grafana volume mount in docker-compose.prod.yml**

Add a volume for dashboards:

```yaml
      - ./infra/grafana/dashboards:/var/lib/grafana/dashboards
```

**Step 3: Create a basic overview dashboard JSON**

This should include panels for:
- BEAM memory (total, processes, binary, ETS)
- Phoenix request rate and latency (p50, p95, p99)
- Ecto query duration and pool wait time
- Oban job execution rate and failures
- Connected users count
- VM run queue lengths

The JSON is verbose — generate it by creating panels in Grafana UI first, then export. For the plan, note the panels needed and the PromQL queries:

| Panel | PromQL |
|-------|--------|
| BEAM Memory | `vm_memory_total_bytes` |
| Request Rate | `rate(phoenix_endpoint_stop_duration_milliseconds_count[5m])` |
| Request Latency p95 | `histogram_quantile(0.95, rate(phoenix_endpoint_stop_duration_milliseconds_bucket[5m]))` |
| Ecto Query Time | `rate(slackex_repo_query_total_time_milliseconds_sum[5m]) / rate(slackex_repo_query_total_time_milliseconds_count[5m])` |
| Ecto Pool Wait | `slackex_repo_query_queue_time_milliseconds` |
| Oban Jobs/min | `rate(oban_job_stop_duration_count[5m]) * 60` |
| Connected Users | `slackex_presence_connected_users_count` |
| Run Queue | `vm_total_run_queue_lengths_total` |

**Step 4: Commit**

```
feat(infra): add Grafana dashboard provisioning and overview dashboard
```

---

### Task 13: Local Integration Test

**Step 1: Start everything locally**

You'll need a local docker compose that includes the observability stack. Create a `docker-compose.observability.yml` override for local testing, or test directly against prod compose (with local app).

Alternatively, test the Elixir side in dev (stdout traces work), then test the infra stack separately:

```bash
cd infra
docker compose -f ../docker-compose.prod.yml up -d otel-collector prometheus grafana tempo
```

**Step 2: Configure local app to point at collector**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 mix phx.server
```

**Step 3: Verify traces appear in Grafana**

1. Open Grafana at `http://localhost:3001`
2. Go to Explore → select Tempo data source
3. Search for traces — should see Phoenix request traces

**Step 4: Verify metrics appear in Grafana**

1. Go to Explore → select Prometheus data source
2. Query: `vm_memory_total_bytes`
3. Should see BEAM memory data

**Step 5: Verify the overview dashboard**

1. Go to Dashboards → Slackex → Overview
2. All panels should render with data

---

### Task 14: Secure the /metrics Endpoint

**Files:**
- Modify: `lib/slackex_web/endpoint.ex` (the `maybe_metrics` plug)

**Step 1: Restrict /metrics to internal networks only**

In production, `/metrics` should only be accessible from within the Docker network (Prometheus scraping). Add an IP check or rely on the fact that the port isn't exposed externally (only via Docker internal network).

Since the app `expose`s port 4000 (not `ports`), only containers on the same Docker network can reach it. Prometheus is on the `default` network. External access goes through Caddy, which can be configured to block `/metrics`.

Check if Caddy already has path restrictions. If not, add to the Caddyfile:

```
@blocked path /metrics
respond @blocked 403
```

Or in the app, check the connection's remote IP:

```elixir
defp maybe_metrics(%{request_path: "/metrics", remote_ip: remote_ip} = conn, _opts) do
  if internal_network?(remote_ip) do
    # ... serve metrics
  else
    conn
    |> Plug.Conn.send_resp(403, "Forbidden")
    |> Plug.Conn.halt()
  end
end

defp internal_network?({172, _, _, _}), do: true   # Docker bridge
defp internal_network?({10, _, _, _}), do: true     # Private
defp internal_network?({192, 168, _, _}), do: true  # Private
defp internal_network?({127, _, _, _}), do: true    # Loopback
defp internal_network?(_), do: false
```

**Step 2: Commit**

```
feat(otel): restrict /metrics endpoint to internal networks
```

---

## Phase 4: Deploy

### Task 15: Deploy and Verify

**Step 1: Update pre-deploy checks**

Ensure `scripts/pre-deploy` passes with new deps.

**Step 2: Deploy via standard process**

Use `/deploy` — the standard CI pipeline will:
- Build Docker image with new OTEL deps
- SCP updated `docker-compose.prod.yml` and `infra/` configs to server
- Pull and recreate all containers (including new observability services)

**Step 3: Verify in production**

1. SSH into server, check all containers are running:
   ```bash
   docker compose -f docker-compose.prod.yml ps
   ```
2. Check Grafana is accessible at `http://<server>:3001`
3. Verify Prometheus is scraping:
   ```bash
   curl http://localhost:9090/api/v1/targets
   ```
4. Verify traces in Tempo via Grafana Explore
5. Check overview dashboard populates

**Step 4: Tag and commit**

```
feat(otel): observability stack — OTEL, Prometheus, Grafana, Tempo
```

---

## Summary

| Task | Component | Effort |
|------|-----------|--------|
| 1 | Add OTEL dependencies | 5 min |
| 2 | Configure OTEL per environment | 10 min |
| 3 | Wire up auto-instrumentation | 10 min |
| 4 | Prometheus /metrics endpoint | 20 min |
| 5 | Custom BEAM/app metrics | 15 min |
| 6 | Req HTTP instrumentation | 10 min |
| 7-10 | Infrastructure configs (Collector, Prometheus, Tempo, Grafana) | 20 min |
| 11 | Docker Compose services | 10 min |
| 12 | Grafana dashboard | 30 min |
| 13 | Local integration test | 20 min |
| 14 | Secure /metrics | 10 min |
| 15 | Deploy and verify | 20 min |

**Total: ~3 hours** across 15 tasks.

---

## Future Tasks (Not in This Plan)

These are documented in the discovery doc but deferred:

- **Alerting rules** — Grafana alert rules for supervisor cascades, memory, error rate spikes
- **Alert → Slackex channel** — Post alerts to a `#ops` channel (requires webhook or bot)
- **MCP exposure** — Expose metrics/traces via MCP for agent debugging
- **Structured logging** — JSON logs to Loki for log correlation with traces
- **ReadRepo instrumentation** — Add OTEL setup for the read replica repo
- **Custom Oban per-worker metrics** — Instrument individual workers (EmbeddingWorker, LinkPreviewWorker)
- **Multi-node trace correlation** — Verify trace context propagates across Erlang distribution
