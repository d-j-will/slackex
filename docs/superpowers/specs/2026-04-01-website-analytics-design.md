# Website Analytics Design Spec

**Date:** 2026-04-01
**Status:** Draft
**Feature Flag:** `:website_analytics`

## Overview

A homegrown analytics system for Tenun that combines **product analytics** (feature usage, user behavior, hotspots) with **operational analytics** (errors, performance, pain points). Built on the existing PostgreSQL + Prometheus + Grafana stack with no new infrastructure dependencies.

Data surfaces in two places:
- **In-app admin UI** (`/admin/analytics`) for quick product insights
- **Grafana dashboards** for deep operational analysis and alerting

## Constraints

- ~50 active users (homelab/team scale)
- Runs on unprivileged LXC (CT 100) — no heavy new services
- Multi-node deployment — analytics must work across nodes
- Feature-flagged behind `:website_analytics` for staged rollout

## Data Model

### `analytics_events` Table

| Column | Type | Notes |
|--------|------|-------|
| `id` | `bigint` | Snowflake ID (consistent with messages table) |
| `event_type` | `string` | `page_view`, `feature_used`, `js_error`, `server_error`, `oban_error`, `performance`, `click` |
| `event_category` | `string` | `product`, `error`, `performance` |
| `event_name` | `string` | Specific event, e.g. `search_opened`, `unhandled_exception`, `slow_mount` |
| `user_id` | `bigint, nullable` | FK to `users`. Null for unauthenticated events |
| `session_id` | `string` | Unique identifier correlating events within a user's browsing session (see Session ID Scope below) |
| `metadata` | `jsonb` | Flexible payload per event type (see below) |
| `inserted_at` | `utc_datetime_usec` | |

**Indexes:**
- `(event_type, inserted_at)` — query by type within time range
- `(user_id, inserted_at)` — query by user within time range
- GIN on `metadata` — flexible querying of jsonb fields

**No partitioning** — at ~50 users, volume is trivial (~5,000 events/day, ~450K rows at 90-day retention, ~225MB). Can add time-based partitioning later if needed.

### Metadata Shapes by Event Type

Descriptions use observable behavior, not implementation details:

```
page_view:
  path         — page URL path
  live_action  — which LiveView action was active
  referrer     — HTTP Referer header (initial load only)
  duration_ms  — elapsed time from request start to LiveView mount completion
  is_reconnect — true if this mount followed a WebSocket reconnect (not a fresh navigation)

feature_used:
  feature      — feature name (e.g. "search", "reactions", "threads")
  action       — specific action within the feature (e.g. "add", "remove", "open")
  channel_id   — channel context (if applicable)
  context      — UI location where the feature was used

js_error:
  message      — error message string
  stack        — stack trace
  url          — page URL where the error occurred
  line         — source line number
  column       — source column number
  user_agent   — browser user agent string

server_error:
  kind         — error kind (:error, :exit, :throw)
  reason       — error reason/message
  stacktrace   — Elixir stacktrace
  plug_status  — HTTP status code (e.g. 500)
  path         — request path
  trace_id     — OTEL trace ID for Grafana/Tempo drill-through

oban_error:
  worker       — Oban worker module name
  queue        — queue name
  args         — job arguments
  error        — error reason/message
  attempt      — which attempt failed
  trace_id     — OTEL trace ID for Grafana/Tempo drill-through

performance:
  metric       — metric name (e.g. "lcp", "fid", "long_task")
  value        — measured value in milliseconds
  path         — page URL path
  live_view    — LiveView module name

click:
  target       — tracked element identifier (from data-track attribute)
  context      — UI context (from data-track-context attribute)
  path         — page URL path
```

## Event Collection — Server Side

### Analytics.Plug (HTTP Boundary)

A Plug in the endpoint pipeline that handles the HTTP request layer:

- Records `page_view` events for the initial HTTP page load
- Sets/reads `session_id` from the session (generated if missing)
- Catches HTTP-level errors (500s) with path, user, and params context
- **Excludes bot users** — checks `user.is_bot` and skips tracking
- **Excludes admin/dev traffic** — checks `:exclude_from_analytics` per-user FunWithFlags flag
- No-op when `:website_analytics` flag is disabled

### Analytics.LiveViewTracker (WebSocket Boundary)

An `on_mount` hook attached in the router's authenticated live session:

```elixir
live_session :authenticated, on_mount: [...existing..., Analytics.LiveViewTracker] do
```

Captures:
- **LiveView navigations** — `attach_hook(:handle_params)` fires on every `live_patch`/`live_navigate`, recording path, live_action, and timing
- **Mount duration** — measures initial mount time, flags slow mounts (>500ms)
- **Reconnect detection** — distinguishes initial mounts from WebSocket reconnects. Reconnects are tagged with `is_reconnect: true` to avoid inflating page view counts during deploys
- **OTEL trace correlation** — reads the current `trace_id` from the OpenTelemetry span context and includes it in error event metadata, enabling click-through from admin UI to Grafana/Tempo traces

### Telemetry Listeners

Attach to existing telemetry events (no custom emission needed):

- `[:phoenix, :live_view, :handle_event, :exception]` — LiveView crash tracking
- `[:oban, :job, :exception]` — Failed Oban job tracking
- Both include `trace_id` from the current span context

### Feature Usage Tracking

Explicit `Analytics.track/3` calls at key interaction points:

```elixir
Analytics.track(socket, "feature_used", %{feature: "search", query_type: "hybrid"})
Analytics.track(socket, "feature_used", %{feature: "reactions", action: "add"})
```

Initial instrumentation covers feature-flagged features: search, threads, reactions, summarization, link previews, markdown rendering, quick switcher.

### Write Path

`Analytics.track/3` inserts asynchronously via an Oban job (`Analytics.TrackWorker` on the `:analytics` queue). Keeps user interactions non-blocking. At ~50 users the volume is negligible, but async is good hygiene and works correctly across multiple nodes (Oban handles distributed job execution).

## Event Collection — Client Side

### analytics.js LiveView Hook

A single JS hook attached to a persistent root element:

```html
<div id="app-container" phx-hook="Analytics">
```

Captures three categories:

#### JavaScript Errors

Global `window.onerror` and `window.onunhandledrejection` handlers. Captures message, stack trace, source URL, line/column. Pushes via `this.pushEvent("analytics:error", payload)`.

**Rate limiting:** Same error message only reported once per 60 seconds. Prevents flood from errors in loops or rendering cycles.

#### Performance Metrics

Uses browser `PerformanceObserver` API:
- **Largest Contentful Paint (LCP)** — perceived load speed
- **First Input Delay (FID)** — responsiveness to first interaction
- **Long tasks** — anything blocking main thread >50ms

Batched and sent every 30 seconds to avoid chattiness.

#### Declarative Click Tracking

Opt-in via `data-track` HTML attributes:

```html
<button phx-click="send_message" data-track="send_message" data-track-context="channel">
  Send
</button>
```

The hook listens for clicks on `[data-track]` elements, extracts event name and context, pushes to server. Tracking is explicit and self-documenting in the markup.

### Server-Side Event Handling

A `handle_event("analytics:*", ...)` clause receives client events and routes through `Analytics.track/3`. Authenticated via the existing LiveView WebSocket session — no additional auth needed.

## Query Layer — Analytics Context

### Slackex.Analytics

Core query functions, all accepting a `period` option:

```elixir
Analytics.page_views(period: :last_7_days)
# → [%{path: "/chat/general", count: 142, unique_users: 8}, ...]

Analytics.feature_usage(period: :last_30_days)
# → [%{feature: "search", count: 47, unique_users: 12}, ...]

Analytics.errors(period: :last_24_hours, category: :js_error)
# → [%{message: "Cannot read...", count: 3, last_seen: ~U[...], metadata: %{...}}, ...]

Analytics.slow_pages(threshold_ms: 500, period: :last_7_days)
# → [%{path: "/chat/general", avg_duration_ms: 620, p95_ms: 1200, count: 15}, ...]

Analytics.user_activity(user_id, period: :last_30_days)
# → [%{date: ~D[2026-03-28], events: 42, features_used: ["search", "threads"]}, ...]

Analytics.hotspots(period: :last_7_days)
# → ranked by composite score: (visit_count * 0.4) + (avg_duration_ms * 0.3) + (error_rate * 0.3)
```

### Analytics.PruneWorker

Oban cron job running nightly. Deletes events older than 90 days (configurable via application env).

### Analytics.MetricsBridge

Periodic task (every 60s) that queries aggregate counts and pushes Prometheus gauges:

- `tenun.analytics.page_views` — gauge (by path)
- `tenun.analytics.errors` — gauge (by category)
- `tenun.analytics.feature_usage` — gauge (by feature)
- `tenun.analytics.active_users` — gauge

Metric names follow existing conventions (`slackex.oban.queue_depth.running`, `slackex.presence.connected_users.count`) — no redundant `.count` suffix on names that are already clearly gauges.

**Important:** Exact metric names as exported by TelemetryMetricsPrometheus.Core must be verified against library documentation during implementation. The names above are logical names — the actual Prometheus export format (e.g., underscores vs dots, namespace prefixing) depends on the library. Contract tests must assert on the real exported names.

**Multi-node execution:** Runs as an Oban cron job with `unique: [period: 55]` to ensure only one node executes per cycle. If a node has already inserted the job within the uniqueness window, other nodes' cron insertions are no-ops. This is Oban's built-in mechanism for distributed cron deduplication — no Horde or custom leader election needed.

Feeds the existing `/metrics` endpoint and Prometheus scrape pipeline.

## Routing & Access Control

The admin analytics UI lives at `/admin/analytics`, protected by the same basic auth pattern as the existing `/admin/flags` route:

```elixir
scope "/admin/analytics" do
  pipe_through [:browser, :admin_flags_auth]

  live_session :admin_analytics, on_mount: [Analytics.LiveViewTracker] do
    live "/", AdminLive.Analytics, :overview
    live "/hotspots", AdminLive.Analytics, :hotspots
    live "/errors", AdminLive.Analytics, :errors
    live "/features", AdminLive.Analytics, :features
  end
end
```

Access is gated by the existing `flags_basic_auth` plug (username/password from `config :slackex, :flags_admin_auth`). No new user schema changes needed — this reuses the same admin auth that protects FunWithFlags UI.

The analytics LiveView tracker is included in the admin live session so admin page views are tracked (useful for verifying the pipeline), but admin users with `:exclude_from_analytics` flag set will have their events filtered from product analytics queries.

## Admin UI — `/admin/analytics`

A LiveView page (`AdminLive.Analytics`) behind existing admin auth, with four tabs routed via `live_action`.

### Overview Tab
- Active users: today, 7d, 30d (unique users with events)
- Page views: inline SVG sparkline over last 7 days
- Error count: with trend indicator (up/down vs previous period)
- Top features: bar chart ranked by usage count

### Hotspots Tab
- Pages ranked by composite score: `(visit_count * 0.4) + (avg_duration_ms * 0.3) + (error_rate * 0.3)`
- Each row: path, visits, avg load time, error count, heat indicator
- Clickable to drill into page-specific event timeline

### Errors Tab
- Grouped by error message (deduplicated), sorted by frequency
- Each group: count, last seen, affected users, category (JS/server/Oban)
- Expandable for stack trace, metadata, and **trace_id link** (click through to Grafana/Tempo)
- Filterable by category and time period

### Feature Adoption Tab
- Table of feature-flagged features: total uses, unique users, 7d sparkline trend
- Correlates with FunWithFlags flags — shows which enabled features are used vs. ignored

### Shared Controls
- **Date range picker** — shared across all tabs, with presets (24h, 7d, 30d, 90d) and custom range
- **Real-time updates** — PubSub pushes counter updates to connected admin sessions
- **Server-rendered charts** — inline SVG sparklines/bars, no JS charting library needed at this scale

## Grafana Integration

### New Dashboard: "Tenun — User Analytics"

Auto-provisioned via `infra/grafana/dashboards/tenun-analytics.json`, alongside existing `slackex-overview.json`.

Panels:
- **Error rate over time** — time series by category (JS, server, Oban) with alerting threshold
- **Slowest pages (p95)** — table ranked by 95th percentile mount/load duration
- **Feature adoption trend** — stacked area chart, 30-day feature usage
- **Active users heatmap** — hour-of-day x day-of-week activity grid
- **Error log** — table of recent errors with message, count, last occurrence

Data source: Prometheus metrics from `Analytics.MetricsBridge`. No direct Postgres queries.

### Alerting

Grafana alert rule: if `tenun.analytics.errors` in the last 15 minutes exceeds threshold (default: 10), fire notification. Routes to configured alert channel (email, webhook, Discord). Uses existing Grafana alerting — no new infrastructure.

## Data Hygiene

### Bot User Exclusion
Both `Analytics.Plug` and `Analytics.LiveViewTracker` check `user.is_bot` and skip tracking for bot users. Webhook API hits from bot users do not pollute product analytics.

### Admin/Dev Traffic Exclusion
Exclusion via `:exclude_from_analytics` per-user flag in FunWithFlags. Consistent with existing per-user feature flag pattern. Enable this flag for admin/developer accounts whose activity would skew product analytics data. Dev environment events are collected by default (useful for testing the pipeline) but can be excluded via `config :slackex, Analytics, exclude_dev: true`.

### Reconnect Deduplication
LiveView reconnects (network blips, deploys) tagged with `is_reconnect: true`. Query functions exclude reconnects from page view counts by default, with an option to include them for debugging.

### Session ID Scope

`session_id` is a UUID generated client-side and persisted in the browser's session storage. This means:
- Each browser tab gets a distinct `session_id`
- Events are split across multiple "sessions" if a user opens multiple tabs
- Clearing browser storage resets the `session_id`

At ~50 users this is acceptable. Session counts will be higher than actual distinct users (due to tab splits), but trends remain valid. For per-user activity analysis, use `user_id` directly (available on all authenticated events).

### Client-Side Rate Limiting
JS error events deduplicated by message — same error reported at most once per 60 seconds. Prevents event floods from errors in rendering loops.

## Feature Flag & Rollout

Gated behind `:website_analytics` FunWithFlags flag:

- **Flag off** — All collection modules are no-ops. No events collected, no Oban jobs queued. Admin UI shows "Analytics disabled." The flag check happens at the entry point of each module:
  - `Analytics.Plug` — checked in `call/2` before any processing
  - `Analytics.LiveViewTracker` — checked in `on_mount` before attaching hooks
  - `analytics.js` hook — checks a `data-analytics-enabled` attribute on the root element (set server-side based on the flag)
  - `Analytics.TelemetryHandler` — checked before inserting Oban job
- **Flag on** — Full collection and UI
- **Per-user gating** — Enable for specific users first for validation before global rollout

## Testing Strategy

### Integration Test (Pipeline Verification)

At least one test that exercises the full path per CLAUDE.md spec-driven testing rules:

```
track event → Oban job runs → row in analytics_events → query function returns it
```

No faking the upstream — the test calls `Analytics.track/3` and asserts on the database result after draining the Oban queue.

### Unit Tests
- `Analytics.Event` changeset validation
- Query functions with seeded data
- `Analytics.Plug` skips bots, respects feature flag
- `Analytics.LiveViewTracker` reconnect detection
- Client-side rate limiting logic

### Client-Side Rate Limiting Test
LiveView integration test that verifies JS error deduplication:
1. Trigger a JS error event via the analytics hook
2. Immediately trigger the same error again
3. Assert only 1 event recorded in `analytics_events`
4. The 60-second window is a client-side concern — server-side tests verify that duplicate events received within a short window are both persisted (rate limiting is enforced in JS, not the server)

### Contract Tests
- Prometheus metric names emitted by `MetricsBridge` match Grafana dashboard PromQL queries (exact export format verified against TelemetryMetricsPrometheus.Core docs)
- Event metadata shapes match what query functions expect

## Module Summary

| Layer | Module | Responsibility |
|-------|--------|---------------|
| Schema | `Analytics.Event` | Ecto schema + migration |
| Collection | `Analytics.Plug` | HTTP tracking, session_id, HTTP errors |
| Collection | `Analytics.LiveViewTracker` | LiveView navigation, mount timing, reconnect detection |
| Collection | `analytics.js` hook | JS errors, performance, click tracking |
| Telemetry | `Analytics.TelemetryHandler` | Listens to Phoenix/Oban exception events |
| Write path | `Analytics.TrackWorker` | Async Oban insert |
| Query | `Slackex.Analytics` | Query functions for UI + metrics |
| Metrics | `Analytics.MetricsBridge` | Prometheus gauge export (Oban cron, single-node) |
| Cleanup | `Analytics.PruneWorker` | 90-day retention Oban cron |
| UI | `AdminLive.Analytics` | In-app analytics dashboard |
| Grafana | `tenun-analytics.json` | Operational analytics panels + alerting |
| Gate | `:website_analytics` flag | Feature flag for rollout |
