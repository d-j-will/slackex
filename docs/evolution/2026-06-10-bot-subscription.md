# Bot Channel Subscription

**Date:** 2026-06-10
**Flag:** `:bot_subscription`
**Status:** In development

## Summary

Owner-driven `/subscribe-bot <name>` and `/unsubscribe-bot <name>` slash commands that add/remove an existing MCP bot's `subscriptions` row in the active public channel, unlocking the MCP write tools (`send_message`, `reply_to_thread`, `react_to_message`) for that channel. No new tables, no token handling. Design: `docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md`.

## Lifecycle
- [x] Develop (flag off)
- [ ] Deploy behind flag
- [ ] PO validation
- [ ] Global enable
- [ ] Contract (remove flag)
