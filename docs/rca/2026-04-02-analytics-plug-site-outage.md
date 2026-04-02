# RCA: v0.8.4 Site-Wide Outage — AnalyticsPlug Crash on Flag Enable

**Date:** 2026-04-02
**Severity:** Critical (complete site outage)
**Duration:** ~15 minutes (until v0.8.5 deployed)
**Versions affected:** v0.8.0–v0.8.4

## Summary

Enabling the `:website_analytics` feature flag caused a complete site outage (503 on all routes). The `AnalyticsPlug`, mounted in the endpoint pipeline, crashed on every HTTP request when the flag was enabled, taking down the entire site including the admin flags page needed to disable the flag.

## Timeline

1. **v0.8.0** — Analytics feature deployed successfully (migration ran, code deployed)
2. **v0.8.1** — Push notifications deployed but crashed on boot (missing VAPID env vars in runtime.exs)
3. **v0.8.2** — Fixed boot crash, added boot check to deploy workflow
4. **v0.8.3** — Added VAPID secrets to deploy workflow
5. **v0.8.4** — Fixed `Preference.resolve_level` crash on nil channel_id
6. **User enables `:website_analytics` flag** — Site goes down immediately
7. **User enables `:push_notifications` flag** — Also crashes (same pattern in index.ex mount)
8. **v0.8.5** — Wrapped all analytics/notification code in try/rescue, site recovers

## Root Cause

`SlackexWeb.Plugs.AnalyticsPlug` runs in the **endpoint pipeline** — it executes on every HTTP request (chat pages, admin pages, health checks, API endpoints). When `:website_analytics` was enabled:

1. The Plug called `Analytics.track/3`
2. `track/3` called `TrackWorker.new() |> Oban.insert()`
3. The insert raised an exception (likely due to the analytics_events table state or an Oban schema issue)
4. The exception propagated up through the Plug pipeline
5. Phoenix returned 500 Internal Server Error for the request
6. Every subsequent request hit the same crash path

The admin flags page (`/admin/flags`) also goes through the endpoint pipeline, so it was also unreachable — the user had no way to disable the flag without direct database access or a code deploy.

## Contributing Factors

### 1. Non-essential code in critical path without isolation

Analytics tracking is non-essential — if it fails, the user should still see their chat page. But the Plug was mounted in the endpoint pipeline (the most critical path in the app) with zero error handling. A crash in tracking killed the entire HTTP request.

### 2. No recovery path

The admin flags page uses the same endpoint pipeline as all other pages. When the Plug crashed, the flag management UI was also unreachable. The only recovery options were:
- Deploy a code fix (10+ minutes)
- SSH to prod and update the database directly

### 3. Feature flag activated untested code path

The analytics code was deployed with the flag OFF. When the flag was turned ON, it activated a code path that had never run in production. The boot check (added in v0.8.2) only verifies the release can start — it doesn't test feature-flag-gated code paths.

### 4. Repeat of v0.5.36 pattern

This is structurally identical to the v0.5.36 EmbeddingWorker incident: non-essential feature (analytics/embeddings) placed in a critical path without blast-radius isolation, where a failure cascades to take down the entire app. The CLAUDE.md Production Resilience rules were written after that incident but were not followed here.

## Fix (v0.8.5)

- `AnalyticsPlug.call/2` — wrapped in `try/rescue`, logs warning on error, returns `conn` unchanged
- `AnalyticsTracker.on_mount` — wrapped `track_mount` and `track_navigation` calls in `try/rescue`
- `Preference.resolve_level/2` — added `rescue` fallback to `"all"` (v0.8.4)

## Prevention

### Rules (add to CLAUDE.md)

1. **Any code in the endpoint pipeline that is gated behind a feature flag MUST be wrapped in try/rescue.** Feature-flagged code is, by definition, non-essential — it must never crash the essential path.

2. **on_mount hooks must never raise.** A crash in on_mount kills the LiveView mount for every user. Non-essential hooks (analytics, tracking, telemetry) must rescue all errors.

3. **Feature flags that activate new endpoint/on_mount code paths should be tested with the flag ON in a staging or local environment before enabling in production.** The deploy boot check doesn't cover runtime flag activation.

4. **Admin pages must remain accessible during failures.** Consider moving `/admin/flags` to a separate endpoint pipeline that skips non-essential plugs, or ensure all non-essential plugs are individually resilient.

## Affected Components

- `lib/slackex_web/plugs/analytics_plug.ex` — Plug in endpoint pipeline
- `lib/slackex_web/live/analytics_tracker.ex` — on_mount hook in `:chat` live_session
- `lib/slackex/notifications/preference.ex` — `resolve_level/2` query function
