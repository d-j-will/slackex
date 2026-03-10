# Design: LLM Foundation + Channel Summarization

**Date:** 2026-03-05
**Status:** Approved
**Feature flag:** `:channel_summarization`

---

## Overview

Add a configurable LLM client (same pattern as `EmbeddingClient`/`OpenAIClient`) and a channel summarization feature that streams AI-generated summaries to users via LiveView. Triggered by a button in the channel header or a `/summarize` slash command.

---

## Architecture

Three layers:

1. **`LLMClient` behaviour** — configurable API client for any OpenAI-compatible chat completions API
2. **`Slackex.AI.Summarizer`** — domain module that loads messages, builds prompts, streams results
3. **UI** — channel header button + slash command foundation + streaming modal

---

## Layer 1: LLMClient

### Behaviour

```
Slackex.AI.LLMClient (behaviour)
  callbacks:
    - complete(messages, opts) :: {:ok, String.t()} | {:error, term()}
    - stream(messages, opts) :: {:ok, Enumerable.t()} | {:error, term()}
```

### Implementations

```
Slackex.AI.OpenAICompatibleClient
  - Configurable: api_url, model, api_key, max_tokens, temperature
  - complete/2 → POST /v1/chat/completions (non-streaming)
  - stream/2 → POST /v1/chat/completions (stream: true)
    Returns an Enumerable that yields delta content strings from SSE chunks.
    Uses Req's streaming response with into: callback.

Slackex.AI.StubLLMClient
  - Returns deterministic canned responses for tests
  - stream/2 returns a Stream that yields words from a fixed string
```

### Delegation module

```
Slackex.AI.LLMClient
  - Delegates to configured client via Application.get_env(:slackex, :llm_client)
  - Same pattern as Slackex.Embeddings.EmbeddingClient
```

### Configuration

```elixir
# config/runtime.exs
if llm_api_key = System.get_env("LLM_API_KEY") do
  config :slackex, :llm_api, %{
    api_url: System.get_env("LLM_API_URL", "https://api.deepinfra.com/v1/openai"),
    model: System.get_env("LLM_MODEL", "google/gemma-3-4b-it"),
    api_key: llm_api_key,
    max_tokens: String.to_integer(System.get_env("LLM_MAX_TOKENS", "1024")),
    temperature: 0.3
  }
end

# config/prod.exs
config :slackex, :llm_client, Slackex.AI.OpenAICompatibleClient

# config/test.exs
config :slackex, :llm_client, Slackex.AI.StubLLMClient

# config/dev.exs — same as prod (use real API in dev)
config :slackex, :llm_client, Slackex.AI.OpenAICompatibleClient
```

Env vars: `LLM_API_KEY`, `LLM_API_URL`, `LLM_MODEL`, `LLM_MAX_TOKENS`
GH secret: `LLM_API_KEY` → CI → server `.env` (same pattern as `EMBEDDING_API_KEY`)

### Telemetry

Emit `[:slackex, :ai, :completion]` telemetry events with:
- `:prompt_tokens` — from API response `usage.prompt_tokens`
- `:completion_tokens` — from API response `usage.completion_tokens`
- `:model` — model name
- `:duration` — wall-clock time

Follows the universal usage tracking principle (see Cross-cutting concerns below).

---

## Layer 2: Summarizer

### Module: `Slackex.AI.Summarizer`

```elixir
Slackex.AI.Summarizer
  summarize_channel(channel_id, since, user_id, opts)
    1. Load messages from channel since timestamp (Chat context query)
    2. Format as context string (reuse RAGContext format_line/1 pattern)
    3. Build system prompt + user prompt from template
    4. Call LLMClient.stream/2
    5. Return {:ok, token_stream} or {:error, reason}
```

### Prompt template

```
System: You are a concise channel summarizer for a team chat app.
Summarize the conversation clearly and briefly. Include:
- Key topics discussed
- Decisions made
- Action items (with who owns them, if mentioned)
- Notable messages or announcements
Do not invent information not present in the messages.

User: Summarize the following conversation from #{{channel_name}}
since {{since_human}}:

{{context}}
```

### Early returns

- No messages in range → `{:error, :no_messages}`
- LLM not configured → `{:error, :not_configured}`
- Channel not accessible to user → `{:error, :unauthorized}`

---

## Layer 3: UI

### Channel header button

"Summarize" button in the channel header bar (alongside existing controls). Only visible when `:channel_summarization` flag is enabled.

Click opens a modal with:
- **Time range quick-select:** "Last 24h" | "Last 7 days" | "Last 30 days" | "Since [date]"
- **Streaming output area:** text appears token-by-token
- **Close button** (standard dismiss: backdrop click, Escape, X button)

### Streaming flow

```
User clicks "Summarize 24h"
  → LiveView handle_event("summarize_channel", %{"since" => "24h"})
  → Check rate limit (one active summary per user)
  → Spawns Task linked to LiveView process
  → Task calls Summarizer.summarize_channel/4
  → Summarizer calls LLMClient.stream/2
  → Stream yields token strings
  → Task sends each chunk: send(live_view_pid, {:summary_token, chunk})
  → LiveView handle_info appends to @summary_text assign
  → Template re-renders with new content (progressive display)
  → On stream end: Task sends {:summary_complete, full_text}
  → LiveView updates state (loading → complete)
```

### Slash command foundation

Parse messages starting with `/` in the message input component:

```
/summarize           → summarize current channel, last 24h
/summarize 7d        → summarize current channel, last 7 days
/summarize since mon → summarize since Monday
```

Routes to the same `Summarizer` pipeline. Result displayed in the summary modal (not as a chat message — keeps it private to the requesting user).

**Extensibility:** The slash command parser is a simple pattern match on the first word. Future commands (`/search`, `/translate`, `/ask`) plug into the same dispatcher without architectural changes.

---

## Cross-cutting concerns

### Rate limiting

One active summary per user at a time, tracked in LiveView assigns (`@active_summary_task`). If a user clicks "Summarize" while one is streaming:
- Cancel the previous Task (Process.exit)
- Start the new one

No database table needed — LiveView process state is sufficient.

### Summary caching

Lightweight ETS cache keyed on `{channel_id, time_bucket}` with a 5-minute TTL. If a matching summary exists:
- Return cached text immediately (no streaming, just render)
- Skip API call entirely

Time bucket rounds `since` to the nearest hour to increase cache hit rate. Optional for v1 — at $0.02/M tokens the cost savings are minimal, but the UX improvement (instant results) is nice.

### Universal usage tracking

**Architectural principle: every external AI service must emit usage telemetry.** This is not LLM-specific — it applies to embeddings, completions, reranking, moderation, translation, and any future external API. If the API reports token counts, emit tokens. If it reports request counts only, emit request counts.

Consistent telemetry namespace: `[:slackex, :ai, <service>]`

| Service | Event | Key metrics |
|---------|-------|-------------|
| Embeddings | `[:slackex, :ai, :embedding]` | `:tokens`, `:batch_size`, `:model`, `:duration` |
| LLM completions | `[:slackex, :ai, :completion]` | `:prompt_tokens`, `:completion_tokens`, `:model`, `:duration` |
| Reranking (future) | `[:slackex, :ai, :rerank]` | `:tokens`, `:candidates`, `:model`, `:duration` |
| Moderation (future) | `[:slackex, :ai, :moderation]` | `:requests`, `:model`, `:duration` |

Each client implementation extracts usage from the API response and calls `:telemetry.execute/3`. A shared `Slackex.AI.Telemetry` module attaches handlers that log a structured line per call:

```
[info] [AI] embedding model=all-MiniLM-L6-v2 tokens=156 batch=3 duration=0.4s
[info] [AI] completion model=gemma-3-4b-it tokens=2450/312 cost=$0.00006 duration=1.2s
```

**Retroactive:** The existing `OpenAIClient` (embeddings) should be updated to emit `[:slackex, :ai, :embedding]` events. This is a small addition to the existing client.

Foundation for: cost dashboards, per-user daily caps, anomaly detection, billing.

### Feature flag

`:channel_summarization` — guards:
- Channel header "Summarize" button (template check)
- Slash command `/summarize` (command dispatcher check)
- `Summarizer.summarize_channel/4` (context module check)

### Error handling

| Error | Handling |
|-------|----------|
| API key missing | `{:error, :not_configured}` → UI: "AI features not configured" |
| API error (429, 500) | Task catches, sends `{:summary_error, reason}` → UI: error + retry button |
| User navigates away | Task linked to LiveView — dies automatically, HTTP connection closes |
| Empty time range | Summarizer returns early → UI: "No messages in this time range" |
| User not in channel | Authorization check → `{:error, :unauthorized}` |

---

## Testing

| Test | Type | Notes |
|------|------|-------|
| `StubLLMClient` | Unit | Returns deterministic streaming responses |
| `OpenAICompatibleClientTest` | Unit | Configurable URL/model/key, batch rejection, dimensions |
| `SummarizerTest` | Unit | Prompt building, context formatting, early returns, token budget |
| `SummaryModalTest` | LiveView | Streaming updates render, time range selection, error states |
| `SlashCommandTest` | LiveView | `/summarize` parsing, routing, unknown command handling |

---

## Files to create/modify

### New files
- `lib/slackex/ai/llm_client.ex` — behaviour + delegation
- `lib/slackex/ai/openai_compatible_client.ex` — configurable implementation
- `lib/slackex/ai/stub_llm_client.ex` — test stub
- `lib/slackex/ai/summarizer.ex` — domain logic
- `lib/slackex_web/live/chat_live/summary_modal.ex` — streaming modal component
- `lib/slackex_web/live/chat_live/slash_command.ex` — command parser/dispatcher
- Tests for all of the above

### Modified files
- `config/prod.exs` — add `:llm_client` config
- `config/dev.exs` — add `:llm_client` config
- `config/test.exs` — add `:llm_client` → StubLLMClient
- `config/runtime.exs` — add `LLM_API_KEY`/`LLM_API_URL`/`LLM_MODEL` env vars
- `docker-compose.prod.yml` — add `LLM_API_KEY` env var
- `.github/workflows/ci-deploy.yml` — add `LLM_API_KEY` GH secret provisioning
- `lib/slackex_web/live/chat_live/index.ex` — add summary event handlers + slash command hook
- Channel header template — add "Summarize" button

---

## Cost estimate

| Scenario | Input tokens | Output tokens | Cost |
|----------|-------------|---------------|------|
| 1 summary (50 messages) | ~2,000 | ~300 | $0.00005 |
| 10 summaries/day | ~20,000 | ~3,000 | $0.0005/day |
| Monthly (moderate use) | ~600,000 | ~90,000 | ~$0.02/month |

At 10x scale: ~$0.20/month. At 100x: ~$2.00/month.
