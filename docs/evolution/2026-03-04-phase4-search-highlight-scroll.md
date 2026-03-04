# Evolution: Phase 4 Search — Highlight & Scroll-to-Message

**Date**: 2026-03-04
**Project ID**: phase4-search
**Status**: IMPLEMENTED

## Summary

Completed the final two acceptance criteria for Phase 4 Intelligence & Search:
1. Search result match highlighting using PostgreSQL `ts_headline()`
2. Scroll-to-message navigation from search results

## Changes

### Phase 1: Search Result Match Highlighting (steps 01-01 through 01-03)

- Added `:headline` virtual field to `Message` schema
- `ts_headline()` generates `<mark>`-tagged snippets in FTS queries (`build_search_query/3`)
- Extended semantic search with `ts_headline` + `HighlightAll=true` via `plainto_tsquery`
- Hybrid search preserves FTS headline through RRF merge (`Map.put_new` keeps first occurrence)
- `sanitize_headline/1` in `SearchComponent` escapes all HTML then restores only `<mark>`/`</mark>` — XSS-safe
- `SearchComponent` renders sanitized headline with `Phoenix.HTML.raw/1`, falls back to truncated content
- CSS styles `mark` element with daisyUI `--color-warning` background

### Phase 2: Scroll-to-Message Navigation (steps 02-01 through 02-04)

- `Chat.list_messages_around/3` loads a centered window using `UNION ALL` (before + target + after)
- `HistoryLoader.around/3` delegates to `list_messages_around`, bypassing cache
- `enter_channel/5` and `enter_dm/3` accept optional `target_message_id`
- `jump_to_message` handlers include `?target=message_id` in `push_patch` URLs
- `handle_params` extracts target, loads around-window, pushes `scroll_to_message` event
- `MessageList` JS hook handles `scroll_to_message` via `handleEvent` with smooth scroll + center
- `highlight-flash` CSS keyframe animation fades from warning-color over 2 seconds

### Refactoring (L1-L4)

- Extracted `SCROLL_THRESHOLD` constant in JS hook (L1)
- Extracted `@headline_options` module attribute for shared ts_headline config (L1)
- Consolidated 5 `jump_to_message` handler clauses into 1 with `to_integer/1` helper (L2)

## Files Modified

| File | Change |
|------|--------|
| `lib/slackex/chat/message.ex` | Added `:headline` virtual field |
| `lib/slackex/chat/chat.ex` | Added `list_messages_around/3` |
| `lib/slackex/search/message_search.ex` | `ts_headline` in FTS/semantic/hybrid, `@headline_options` |
| `lib/slackex/search/history_loader.ex` | Added `around/3` |
| `lib/slackex_web/live/chat_live/index.ex` | Target param handling, consolidated jump_to_message |
| `lib/slackex_web/live/chat_live/search_component.ex` | `sanitize_headline/1`, headline rendering |
| `assets/js/hooks/message_list.js` | `scroll_to_message` handleEvent, `SCROLL_THRESHOLD` |
| `assets/css/app.css` | `mark` styling, `highlight-flash` keyframes |

## Test Coverage

- 1001 tests, 0 failures
- New test files: `list_messages_around_test.exs`, `history_loader_test.exs`
- Extended: `message_search_test.exs`, `search_component_test.exs`, `index_test.exs`

## Execution Stats

| Metric | Value |
|--------|-------|
| Steps | 7 |
| Phases | 2 |
| Total TDD cycles | 7 (all PASS) |
| Commits | 9 (7 steps + 1 refactor + 1 review fix) |
| Elapsed | ~30 minutes |

## Phase 4 Acceptance Criteria

All 19 criteria now checked off in `specs/04-phase-4-intelligence.md`.
