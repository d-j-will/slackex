# Bot Channel Subscription

**Date:** 2026-06-10
**Flag:** `:bot_subscription`
**Status:** Implemented (Slice 1; operator docs, test expansion, spec promotion complete 2026-06-12)

## Summary

Owner-driven `/subscribe-bot <name>` and `/unsubscribe-bot <name>` slash commands that add/remove an existing MCP bot's `subscriptions` row in the active public channel, unlocking the MCP write tools (`send_message`, `reply_to_thread`, `react_to_message`) **and scoped `search_messages`** for that channel. No new tables, no token handling. 

The subscription is the supported production path (replaces seeding). See the full operator instructions and exact flash output in the design spec: `docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md` (now marked Implemented). Expanded integration coverage in `subscribe_bot_test.exs` proves the full MCP unlock for all relevant tools via the real `/mcp` endpoint.

## Lifecycle
- [x] Develop (flag off)
- [x] Slice 1 polish + docs + tests (bead slackex-si7)
- [ ] Deploy behind flag (per-operator enable first)
- [ ] PO validation
- [ ] Global enable
- [ ] Contract (remove flag)
