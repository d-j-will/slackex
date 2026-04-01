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
| `session_id` | `string` | UUID generated client-side in `sessionStorage`, correlates events within a browsing session |
| `metadata` | `jsonb` | Flexible payload per event type (see below) |
| `inserted_at` | `utc_datetime_usec` | |

**Indexes:**
- `(event_type, inserted_at)` — query by type within time range
- `(user_id, inserted_at)` — query by user within time range
- GIN on `metadata` — flexible querying of jsonb fields

**No partitioning** — at ~50 users, volume is trivial (~5,000 events/day, ~450K rows at 90-day retention, ~225MB). Can add time-based partitioning later if needed.

### Metadata Shapes by Event Type

```
page_view:     %{path, live_action, referrer, duration_ms, mount_type}
feature_used:  %{feature, action, channel_id, context}
js_error:      %{message, stack, url, line, column, user_agent}
server_error:  %{kind, reason, stacktrace, plug_status, path, trace_id}
oban_error:    %{worker, queue, args, error, attempt, trace_id}
performance:   %{metric, value, path, live_view}
click:         %{target, context, path}
```

## Event Collection — Server Side

### Analytics.Plug (HTTP Boundary)

A Plug in the endpoint pipeline that handles the HTTP request layer:

- Records `page_view` events for the initial HTTP page load
- Sets/reads `session_id` from the session (generated if missing)
- Catches HTTP-level errors (500s) with path, user, and params context
- **Excludes bot users** — checks `user.is_bot` and skips tracking
- **Excludes admin/dev traffic** — configurable list of excluded user IDs or an `:exclude_from_analytics` user flag
- No-op when `:website_analytics` flag is disabled

### Analytics.LiveViewTracker (WebSocket Boundary)

An `on_mount` hook attached in the router's authenticated live session:

```elixir
live_session :authenticated, on_mount: [...existing..., Analytics.LiveViewTracker] do
```

Captures:
- **LiveView navigations** — `attach_hook(:handle_params)` fires on every `live_patch`/`live_navigate`, recording path, live_action, and timing
- **Mount duration** — measures initial mount time, flags slow mounts (>500ms)
- **Reconnect detection** — distinguishes initial mounts from WebSocket reconnects using `connected?(socket)`. Reconnects are tagged with `mount_type: :reconnect` to avoid inflating page view counts during deploys
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

- `tenun.analytics.page_views.count` (by path)
- `tenun.analytics.errors.count` (by category)
- `tenun.analytics.feature_usage.count` (by feature)
- `tenun.analytics.active_users.count`

Feeds the existing `/metrics` endpoint and Prometheus scrape pipeline. Runs on a single node via Oban cron to avoid duplicate gauge emission in multi-node.

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

Grafana alert rule: if `tenun.analytics.errors.count` in the last 15 minutes exceeds threshold (default: 10), fire notification. Routes to configured alert channel (email, webhook, Discord). Uses existing Grafana alerting — no new infrastructure.

## Data Hygiene

### Bot User Exclusion
Both `Analytics.Plug` and `Analytics.LiveViewTracker` check `user.is_bot` and skip tracking for bot users. Webhook API hits from bot users do not pollute product analytics.

### Admin/Dev Traffic Exclusion
Exclusion via `:exclude_from_analytics` per-user flag in FunWithFlags. Consistent with existing per-user feature flag pattern. Enable this flag for admin/developer accounts whose activity would skew product analytics data. Dev environment events are collected by default (useful for testing the pipeline) but can be excluded via `config :slackex, Analytics, exclude_dev: true`.

### Reconnect Deduplication
LiveView reconnects (network blips, deploys) tagged with `mount_type: :reconnect`. Query functions exclude reconnects from page view counts by default, with an option to include them for debugging.

### Client-Side Rate Limiting
JS error events deduplicated by message — same error reported at most once per 60 seconds. Prevents event floods from errors in rendering loops.

## Feature Flag & Rollout

Gated behind `:website_analytics` FunWithFlags flag:

- **Flag off** — Plug, hook, and JS hook are no-ops. No events collected, no Oban jobs queued. Admin UI shows "Analytics disabled."
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

### Contract Tests
- Prometheus metric names emitted by `MetricsBridge` match Grafana dashboard PromQL queries
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
