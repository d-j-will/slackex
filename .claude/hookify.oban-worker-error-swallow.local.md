---
name: oban-worker-error-swallow
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: _worker\.ex$
  - field: new_text
    operator: regex_match
    pattern: _\s*=
action: warn
---

**Oban worker discarding a return value with `_ =`**

Discarding the return value of the main operation in an Oban `perform/1` function caused a production outage. When a worker returns `:ok` regardless of the actual result, Oban treats every job as successful — no retries, no error tracking, silent data loss.

**Dangerous pattern:**
```elixir
def perform(%Oban.Job{args: args}) do
  _ = do_work(args)  # discards {:error, reason}
  :ok                # Oban thinks it succeeded
end
```

**Correct pattern:**
```elixir
def perform(%Oban.Job{args: args}) do
  with :ok <- ensure_dependencies_available() do
    do_work(args)  # returns :ok | {:error, reason} | {:snooze, seconds}
  end
end
```

**Rules:**
- `perform/1` must return the result of its core operation directly
- Use `{:error, reason}` to trigger Oban retries with backoff
- Use `{:snooze, seconds}` when a backing service is temporarily unavailable
- Only use `_ =` for truly fire-and-forget side effects (logging, PubSub), never for the main operation
