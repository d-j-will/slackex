# Bot Channel Subscription

**Date:** 2026-06-10
**Flag:** `:bot_subscription`
**Status:** Implemented (Slice 1 subscription + docs; Slices 2 names/ergonomics + list_channels/enriched payloads/guidance; Slice 3 docs/rollout/final verification + cross-cutting integration + parent close 2026-06-12)

## Summary

Owner-driven `/subscribe-bot <name>` and `/unsubscribe-bot <name>` slash commands that add/remove an existing MCP bot's `subscriptions` row in the active public channel, unlocking the MCP write tools (`send_message`, `reply_to_thread`, `react_to_message`) **and scoped `search_messages`** for that channel. No new tables, no token handling. 

The subscription is the supported production path (replaces seeding). See the full operator instructions (including "Granting an agent access to a channel" flow: mint once → flag → `/subscribe-bot` → tell agent name+id pair + exact flash) in the design spec: `docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md` (promoted Implemented across slices; key decisions archived in post-implementation section). 

Slices 2 added bot-scoped `list_channels` (with human names/slugs via Serializer.channel + count_members), `channel_name`/`channel_slug` enrichment in message/search payloads (Search preloads + additive serializer guards), `get_channel` helper, and tool schema + server instruction updates guiding agents: "Discover human names + IDs via the `list_channels` tool or `tenun:///channels` resource. Prefer using the name in your reasoning." Factory responses also surface names for status channels.

Slice 3 (d50): architecture/integrations + mcp design updates with capabilities + subscription story; short bot membership note in chat.md; tenun polish plan channel ref updated; operator runbook section added; cross-cutting end-to-end integration test (UI subscribe producer → agent list_by_name + enriched results + schema-guided acts + success) green; full quality gates; parent slackex-cdi closed after evidence. All docs current. No open items under cdi.

Expanded integration coverage in `subscribe_bot_test.exs` (and layered MCP server tests) proves the full story: subscribe in UI → agent discovers and acts using human names + ids successfully via real `/mcp` tools/call.

## Lifecycle
- [x] Develop (flag off)
- [x] Slice 1 polish + docs + tests (bead slackex-si7)
- [ ] Deploy behind flag (per-operator enable first)
- [ ] PO validation
- [ ] Global enable
- [ ] Contract (remove flag)
