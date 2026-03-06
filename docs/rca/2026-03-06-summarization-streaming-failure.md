# RCA: Channel Summarization Streaming Failure (v0.5.58 - v0.5.61)

**Date:** 2026-03-06
**Severity:** P2 -- feature broken in production, no data loss
**Duration:** ~4 deploy cycles over ~2 hours
**Trigger:** User clicked "Summarize" in Channel Summary modal; feature showed "Something went wrong"
**Versions affected:** v0.5.58 through v0.5.60 (fixed in v0.5.61)

## Impact

- Channel Summary feature non-functional for all users across 3 versions
- No data loss or application instability -- failure was contained to the summary modal
- 4 deploys required to fully diagnose and fix

## Timeline

| Version | Change | Outcome |
|---------|--------|---------|
| v0.5.58 | Added specific error messages to summary modal | Revealed "Stream error: no function clause matching in anonymous fn/1" |
| v0.5.59 | Added catch-all clauses to Stream.resource cleanup and next_chunk | Revealed "empty response" -- stream connected but yielded zero tokens |
| v0.5.60 | Added diagnostic logging to start_stream and next_chunk | Logs showed `is_struct=true, is_ref=false` -- Req.Response.Async body, not a reference |
| v0.5.61 | Replaced raw `receive` with `Req.parse_message/2` | Fixed -- summaries stream correctly |

## Root Cause Analysis (5 Whys)

**WHY 1: Why did summarization fail in production?**
The `Stream.resource` cleanup function threw a `FunctionClauseError` -- it didn't handle all possible accumulator states from the streaming pipeline.

**WHY 2: Why didn't the cleanup function handle all states?**
The original code assumed the accumulator would always be a `reference` or `{:done, ref}`, but `start_stream` could also return `{:error, _}` or a `Req.Response.Async` struct. No exhaustive pattern matching was enforced.

**WHY 3: Why did fixing the cleanup reveal a second bug (empty response)?**
After the cleanup crash was fixed, the stream connected successfully (HTTP 200) but yielded zero content tokens. This was a different root cause masked by the first crash.

**WHY 4: Why did the stream yield zero tokens despite a 200 response?**
The code pattern-matched on `{^ref, {:data, data}}` in the `receive` block, but with Req's `into: :self`, the process receives raw Mint HTTP messages (e.g., `{:ssl, socket, binary}`), not clean `{ref, {:data, data}}` tuples. The receive block never matched, silently timed out after 60s, and the stream appeared empty.

**WHY 5: Why was the wrong message format used in the first place?**
The streaming code was written against an assumed Req API pattern without consulting the actual Req documentation for `into: :self`. Unit tests mock the HTTP layer and don't exercise the actual Req async message protocol.

## Root Causes

| # | Root Cause | Category |
|---|-----------|----------|
| RC1 | Non-exhaustive pattern matching in Stream.resource cleanup | Code quality |
| RC2 | Wrong Req streaming API usage (raw receive vs Req.parse_message/2) | API misunderstanding |
| RC3 | No integration test for real streaming behavior | Test gap |
| RC4 | Generic error message ("Something went wrong") delayed diagnosis by one full deploy cycle | Observability |

## Fix

`lib/slackex/ai/openai_compatible_client.ex` rewritten:
1. `start_stream` returns `{:streaming, resp}` (full `%Req.Response{}`) instead of just the ref
2. `next_chunk` uses `Req.parse_message(resp, message)` to translate raw Mint messages
3. `handle_stream_parts` handles batched SSE parts, error detection, and `[DONE]` markers
4. Cleanup function uses `Req.cancel_async_response(resp)` for proper connection teardown

## Corrective Actions

| # | Action | Status |
|---|--------|--------|
| CA1 | Add streaming integration test with simulated SSE server | Done (v0.5.62) |
| CA2 | Add Req streaming guidance to CLAUDE.md | Done |
| CA3 | Update project memory with Req.parse_message/2 requirement | Done |

## Lessons Learned

1. **Consult library docs for async patterns** -- Req's `into: :self` requires `Req.parse_message/2`; this is well-documented but was not consulted.
2. **Test the actual protocol, not just the mock** -- Unit tests that mock HTTP responses don't catch message-format mismatches in streaming code.
3. **Never ship generic error messages** -- "Something went wrong" cost one full deploy cycle of debugging. Specific error messages should exist from day one.
4. **Diagnostic logging is cheap and effective** -- One log line (`is_struct=true, is_ref=false`) immediately identified the root cause after two blind deploys.
