# Observability & OpenTelemetry: Feature Discovery

**Research Date:** 2026-03-08
**Method:** Architecture brainstorm, incident analysis
**Status:** Discovery / Idea capture
**Related:**
- `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md` (agents need observability to debug effectively)
- `docs/research/mcp-product-discovery-workflow-discovery-2026-03-08.md` (MCP as interface for agent access to metrics)
- `docs/rca/2026-03-05-embedding-cascade-app-crash.md` (v0.5.36 — 8 deploys to diagnose)
- `docs/rca/2026-03-06-summarization-streaming-failure.md` (v0.5.58 — 4 deploys to diagnose)

---

## 1. Problem Statement

Slackex has experienced incidents that took multiple deploy cycles to diagnose because the failure mode wasn't visible. The symptoms were clear (app crash, zero tokens), but the root cause required guessing → deploying a fix → observing → guessing again.

### What Would Have Helped

**v0.5.36 (Supervisor cascade, 8 deploys):**
- Process tree visualisation showing which supervisor was restarting
- Memory usage per process (would have shown EXLA OOM immediately)
- Error rate metrics on EmbeddingWorker (would have shown swallowed errors)
- Supervisor restart count metric (would have shown cascade in real-time)

**v0.5.58 (Streaming failure, 4 deploys):**
- Trace of the Req HTTP call showing 200 response received
- Trace of the receive loop showing no messages matched
- Metric on "tokens received per summarisation request" (would have shown zero immediately)
- Log correlation between the HTTP connection and the message processing

Both incidents: **the information existed inside the BEAM, but nobody could see it.**

### The Agent Angle

When an AI agent is debugging a production issue (in the dark factory model or just assisting), it's currently working blind — reading logs, reading code, making educated guesses. With proper observability exposed via MCP:

- Agent queries Prometheus: "What's the error rate on EmbeddingWorker in the last hour?"
- Agent queries traces: "Show me the trace for the last failed summarisation request"
- Agent queries metrics: "What's the memory usage of the EXLA process?"
- Agent correlates: Error spike started at 14:32, which matches deploy v0.5.36

**Observability turns agent debugging from "guess and deploy" into "observe and fix."**

---

## 2. Architecture

### 2.1 The Stack

```
Slackex (BEAM)                    Docker Host (Proxmox LXC)
+------------------+              +---------------------------+
| OpenTelemetry    |              |                           |
| SDK (Elixir)     |              |  OpenTelemetry Collector  |
|                  |--OTLP-----→|  (receives, processes,     |
| - Traces         |              |   exports)                |
| - Metrics        |              |           |               |
| - Logs           |              |           ↓               |
+------------------+              |  +-------------------+    |
                                  |  | Prometheus        |    |
                                  |  | (metrics storage) |    |
                                  |  +-------------------+    |
                                  |           |               |
                                  |           ↓               |
                                  |  +-------------------+    |
                                  |  | Grafana           |    |
                                  |  | (dashboards, alerts)|  |
                                  |  +-------------------+    |
                                  |           |               |
                                  |           ↓               |
                                  |  +-------------------+    |
                                  |  | Tempo / Jaeger    |    |
                                  |  | (trace storage)   |    |
                                  |  +-------------------+    |
                                  +---------------------------+
                                              |
                                              | MCP / API
                                              ↓
                                  +---------------------------+
                                  | AI Agent                  |
                                  | (queries metrics, traces, |
                                  |  logs for debugging)      |
                                  +---------------------------+
```

### 2.2 Why OTEL (OpenTelemetry)

- **Vendor-neutral** — Single instrumentation, export to any backend
- **Elixir support** — `opentelemetry_api`, `opentelemetry`, `opentelemetry_exporter` are mature
- **Three signals** — Traces, metrics, logs through one framework
- **Automatic instrumentation** — Libraries exist for Phoenix, Ecto, Oban, Req, Finch
- **BEAM-aware** — `opentelemetry_process_propagator` for cross-process trace context

### 2.3 Where It Runs

All observability infrastructure runs on the Docker host (Proxmox LXC) alongside Slackex:

- **OTEL Collector** — Lightweight Go binary, ~50MB RAM
- **Prometheus** — Time-series DB, ~100-200MB RAM depending on retention
- **Grafana** — Dashboard UI, ~50-100MB RAM
- **Tempo or Jaeger** — Trace storage, ~100-200MB RAM

**Total additional memory: ~300-550MB** on a 20GB LXC. Manageable, especially since these are operationally essential, not nice-to-have.

Alternatively, Grafana Cloud has a free tier (10K metrics, 50GB traces, 50GB logs) which offloads storage entirely.

---

## 3. What to Instrument

### 3.1 Automatic Instrumentation (Libraries Exist)

| Library | What It Captures |
|---------|-----------------|
| `opentelemetry_phoenix` | HTTP request traces, duration, status codes |
| `opentelemetry_ecto` | Database query traces, duration, query text |
| `opentelemetry_oban` | Job execution traces, queue time, worker duration |
| `opentelemetry_req` | Outbound HTTP request traces (DeepInfra, Cloudflare) |
| `opentelemetry_liveview` | LiveView mount/handle_event/handle_info traces |

Drop-in — add to deps, configure, get traces immediately.

### 3.2 Custom BEAM/OTP Metrics

These are specific to Slackex and the BEAM:

**Process Health:**
- Supervisor restart counts (per supervisor)
- Process memory by registered name / module
- Message queue lengths for GenServers (ChannelServer, Huddle, etc.)
- ETS table sizes

**Application Metrics:**
- Messages sent per channel per minute
- Active WebSocket connections (LiveView)
- Active huddle participants
- Search queries per minute (FTS vs semantic vs hybrid)
- Embedding pipeline throughput and error rate
- Oban job queue depth, execution time, failure rate per worker

**Resource Metrics:**
- BEAM memory (total, processes, binary, ETS, atom)
- BEAM scheduler utilisation
- BEAM IO (bytes in/out)
- BEAM reduction counts
- Docker container memory/CPU (via cAdvisor or node_exporter)

### 3.3 Business Metrics

- Users online (Phoenix.Presence count)
- Messages per day/hour
- Feature flag usage (which flags are active, how often checked)
- Channel activity heatmap
- Search relevance (click-through on search results)

---

## 4. Trace Examples

### 4.1 Message Send (Full Path)

```
Trace: send_message
├── Phoenix.LiveView.handle_event("send_message")     12ms
│   ├── Messaging.send_message()                        8ms
│   │   ├── Ecto: INSERT INTO messages                  2ms
│   │   ├── PubSub.broadcast("channel:123")             1ms
│   │   └── PubSub.broadcast("pipeline:events")         1ms
│   └── LiveView.push_event()                           1ms
├── [async] MessageBatchIngestion                       50ms
│   ├── Ecto: INSERT INTO message_embeddings            5ms
│   └── EmbeddingProvider.generate()                   40ms
│       └── Req.post(DeepInfra)                        35ms
└── [async] LinkPreviewWorker (Oban)                  200ms
    ├── Req.get(url)                                  150ms
    └── Ecto: INSERT INTO link_previews                10ms
```

With this trace, debugging "link previews aren't appearing" is immediate — you can see exactly where the pipeline breaks.

### 4.2 Incident Replay: v0.5.36

If OTEL had been in place:

```
14:32:00  Metric: beam.memory.total = 18.5GB (threshold: 16GB) ← ALERT
14:32:01  Metric: supervisor.restart_count{supervisor="EmbeddingSupervisor"} += 1
14:32:01  Trace: EmbeddingWorker.perform() → error: EXLA OOM
14:32:02  Metric: supervisor.restart_count{supervisor="EmbeddingSupervisor"} += 1
14:32:02  Metric: supervisor.restart_count{supervisor="EmbeddingSupervisor"} += 1
14:32:03  Metric: supervisor.restart_count{supervisor="AppSupervisor"} += 1  ← CASCADE
14:32:03  Event: Application terminated
```

Root cause visible in seconds, not 8 deploys.

---

## 5. Exposing to AI Agents via MCP

This is the key differentiator. Observability isn't just for humans staring at Grafana dashboards — it's data that agents can query programmatically.

### 5.1 MCP Resources

Expose observability data as MCP resources:

| Resource | URI Pattern | Description |
|----------|-------------|-------------|
| Current metrics | `slackex://metrics/{metric_name}` | Latest value of a metric |
| Metric range | `slackex://metrics/{metric_name}?range=1h` | Time series over a period |
| Recent traces | `slackex://traces?service=slackex&limit=10` | Recent trace summaries |
| Trace detail | `slackex://traces/{trace_id}` | Full span tree for a trace |
| Active alerts | `slackex://alerts` | Currently firing Grafana alerts |
| Process health | `slackex://beam/processes` | Top processes by memory/message queue |
| Oban dashboard | `slackex://oban/queues` | Queue depths, failure rates |

### 5.2 MCP Tools

| Tool | Description |
|------|-------------|
| `query_prometheus` | Run a PromQL query and return results |
| `search_traces` | Search traces by service, operation, duration, status |
| `get_logs` | Fetch structured logs filtered by level, module, time range |
| `get_beam_info` | BEAM VM stats — memory, schedulers, process count |

### 5.3 Agent Debugging Workflow

```
Agent investigating "messages are slow":

1. query_prometheus("rate(phoenix_endpoint_duration_seconds_sum[5m])")
   → Response times spiked at 14:30

2. search_traces(service="slackex", min_duration="500ms", since="14:25")
   → 3 traces found, all in send_message path

3. get_trace("abc123")
   → Ecto INSERT is taking 400ms (normally 2ms)

4. query_prometheus("pg_stat_activity_count{state='active'}")
   → 95 active connections (pool max: 100)

5. Agent concludes: connection pool exhaustion, likely from a long-running query or connection leak
```

No guessing. No deploy-and-pray. The agent has the same visibility a human SRE would have.

### 5.4 Dark Factory Integration

In the dark factory model, the observability MCP is essential:

- **During implementation:** Agent can check current system state before making architectural decisions
- **During testing:** Agent can observe the impact of its changes on metrics/traces
- **During verification:** Tier 2 scenarios can include performance criteria checked via Prometheus
- **During incidents:** Agent queries real telemetry instead of reading stale logs

---

## 6. Alerting

### 6.1 Grafana Alerts

Critical alerts that should page (or notify via Slackex channel):

| Alert | Condition | Severity |
|-------|-----------|----------|
| App down | `up{job="slackex"} == 0` for 1m | Critical |
| High memory | `beam_memory_total > 16GB` for 5m | Warning |
| Supervisor cascade | `rate(supervisor_restart_total[1m]) > 5` | Critical |
| Oban queue backlog | `oban_queue_depth > 1000` for 5m | Warning |
| DB connection exhaustion | `pg_active_connections / pg_max_connections > 0.9` | Warning |
| Error rate spike | `rate(phoenix_errors_total[5m]) > 0.05` | Warning |
| Embedding pipeline stalled | `rate(embedding_requests_total[10m]) == 0` when expected | Info |

### 6.2 Alert → Slackex Channel

Alerts should post to a dedicated `#ops` or `#alerts` channel in Slackex. This creates a natural feedback loop:

- Alert fires → posts to Slackex
- AI agent (via MCP) sees the alert in the channel AND can query Prometheus for detail
- Agent investigates and proposes a fix
- Human approves or the dark factory implements

Dogfooding: Slackex monitors itself through itself.

---

## 7. Infrastructure Considerations

### 7.1 Memory Budget on the LXC

| Service | Estimated RAM |
|---------|--------------|
| OTEL Collector | 50 MB |
| Prometheus (2-week retention) | 150-200 MB |
| Grafana | 50-100 MB |
| Tempo (trace storage) | 100-200 MB |
| **Total** | **350-500 MB** |

On 20GB this is acceptable — ~2.5% overhead for full observability. Can be tuned with shorter retention periods.

### 7.2 Storage

- Prometheus TSDB: ~1-2 GB for 2-week retention with moderate cardinality
- Tempo traces: Depends on sampling rate. 100% sampling for low-traffic app is fine. At scale, head-based sampling at 10-50%.
- Grafana: Negligible (dashboards are config, not data)

### 7.3 Docker Compose Addition

All observability services run as additional Docker containers alongside Slackex:

```yaml
# Sketch — not final
otel-collector:
  image: otel/opentelemetry-collector-contrib
  ports:
    - "4317:4317"   # OTLP gRPC
    - "4318:4318"   # OTLP HTTP

prometheus:
  image: prom/prometheus
  volumes:
    - prometheus_data:/prometheus
    - ./prometheus.yml:/etc/prometheus/prometheus.yml

grafana:
  image: grafana/grafana
  ports:
    - "3001:3000"   # Avoid conflict with Phoenix
  volumes:
    - grafana_data:/var/lib/grafana

tempo:
  image: grafana/tempo
  volumes:
    - tempo_data:/tmp/tempo
```

### 7.4 Elixir Dependencies

```elixir
# Core OTEL
{:opentelemetry_api, "~> 1.3"},
{:opentelemetry, "~> 1.4"},
{:opentelemetry_exporter, "~> 1.7"},

# Automatic instrumentation
{:opentelemetry_phoenix, "~> 1.2"},
{:opentelemetry_ecto, "~> 1.2"},
{:opentelemetry_oban, "~> 1.1"},
{:opentelemetry_req, "~> 0.2"},
{:opentelemetry_liveview, "~> 1.0"},

# Prometheus metrics export (BEAM-specific)
{:telemetry_metrics_prometheus, "~> 1.1"},

# BEAM VM metrics
{:opentelemetry_process_propagator, "~> 0.3"},
```

---

## 8. Implementation Phases

### Phase 1: Metrics Foundation
- Add Prometheus metrics exporter to Slackex
- BEAM VM metrics (memory, schedulers, process count)
- Phoenix request metrics (duration, status codes)
- Ecto query metrics (duration, pool usage)
- Oban job metrics (queue depth, execution time, failures)
- Deploy Prometheus + Grafana on Docker host
- Basic dashboard: system health, request rates, error rates

### Phase 2: Distributed Tracing
- Add OTEL SDK and automatic instrumentation (Phoenix, Ecto, Oban, Req)
- Deploy OTEL Collector + Tempo
- Trace correlation across async boundaries (PubSub, Oban jobs)
- Grafana trace exploration integrated with metrics

### Phase 3: Alerting
- Grafana alert rules for critical conditions
- Alert notifications to Slackex `#ops` channel
- On-call / escalation rules

### Phase 4: MCP Exposure
- MCP resources for metrics, traces, alerts, BEAM info
- MCP tools for PromQL queries, trace search, log search
- Agent debugging workflows documented
- Dark factory integration — agents query telemetry during implementation and verification

---

## 9. Open Questions

1. **Grafana Cloud vs self-hosted** — Free tier (10K metrics, 50GB traces/logs) would eliminate local storage. Worth the external dependency?
2. **Trace sampling** — 100% sampling is fine for current traffic. At what point does head-based sampling become necessary?
3. **Custom BEAM metrics** — Which GenServers are worth instrumenting individually? ChannelServer, Huddle, EmbeddingWorker — others?
4. **Log aggregation** — Structured logging (JSON) to Loki? Or just rely on traces + metrics and keep logs as-is?
5. **Cardinality** — Per-channel metrics could explode cardinality. Use channel_id as a label or aggregate?
6. **LiveView instrumentation** — `opentelemetry_liveview` maturity? Does it capture handle_event/handle_info traces?
7. **Multi-node tracing** — Trace context propagation across Erlang distribution? `opentelemetry_process_propagator` handles this?
8. **MCP security** — Exposing Prometheus/traces via MCP needs auth. Same token model as the Slackex MCP server?
9. **Retention policy** — 2 weeks of metrics, 1 week of traces? What's the right balance for a small deployment?
10. **Dashboard as code** — Grafana dashboards in version control (JSON/YAML) for reproducibility?
