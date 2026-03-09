---
name: warn-silent-rescue-failure
enabled: true
event: file
conditions:
  - field: new_text
    operator: regex_match
    pattern: rescue[\s\S]*?->\s*(:ok|nil|:error)\s*$
---

⚠️ **Silent failure pattern detected — `rescue _ -> :ok`**

You are writing a rescue clause that silently discards errors. This hides broken functionality — the only symptom is missing data that nobody notices until they need it.

**What to do instead:**
```elixir
# BAD — hides broken metrics/jobs/workers for days
rescue
  _ -> :ok

# GOOD — makes failures visible immediately
rescue
  error ->
    Logger.warning("function_name failed: #{inspect(error)}")
    :ok
```

**Why this matters:**
- Observability v1: `rescue _ -> :ok` in Oban queue depth measurement silently emitted zero data when `Oban.check_queue/1` changed its return shape
- v0.5.36: EmbeddingWorker swallowed errors, cascaded through supervisor, took down the entire app

Every failure must be visible in logs. If a measurement can't produce data, log a warning.

See CLAUDE.md § "Production Resilience" and `docs/runbooks/observability.md` § "Silent failures in periodic measurements".
