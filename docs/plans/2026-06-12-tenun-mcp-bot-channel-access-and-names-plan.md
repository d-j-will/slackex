# Tenun MCP: Bot Channel Subscription Completion + Human-Readable Channel Names

**Date:** 2026-06-12  
**Status:** Proposed / Planning  
**Parent bead:** slackex-cdi (P2)  
**Related spec:** `docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md` (Draft)  
**Feature flag:** `:bot_subscription` (already defined in the spec)  
**Goal:** Make it practical for a human to grant an MCP bot access to channels from inside the app (slash commands, not DB seeding), and make channel identity (human names + slugs) first-class and convenient inside the MCP tool/resource surface so agents don't have to reverse-engineer numeric IDs.

## Problem Statement (from user + investigation)

Two tightly related Tenun MCP integration pain points:

1. **Bot access is not self-service from the app.**  
   An MCP bot (authenticated via bearer token → `is_bot` user `mcp-<name>`) can only write to a channel (`send_message`, `reply_to_thread`, `react_to_message`, scoped search) if a `Subscription` row exists for it. Currently the three visible channels (1, 4, 5) are reachable because of prior seeding or manual setup. The 2026-06-06 spec defined the correct in-app mechanism (`/subscribe-bot <name>` / `/unsubscribe-bot <name>`), and a surprising amount of the implementation has already landed (parser, dedicated `BotSubscription` handler, `Chat.Members.add_bot_member/remove_bot_member`, flashes that already show `##{name}` + id, and the critical producer→consumer integration test). However it is not yet the *supported, documented* way for operators, and some polish + rollout artifacts are missing.

2. **Only numeric channel_ids are ergonomic for agents.**  
   The `tenun:///channels` resource + `Serializer.channel/2` already return `name`, `slug`, `description`, etc. But:
   - Message/search result serializers only ever emit `channel_id`.
   - There is no convenient "list the channels *this bot* is a member of, with their names".
   - Tool `inputSchema` descriptions and the server instructions only talk about "Channel ID".
   - When an agent (or factory coordinator) is told "use channel 5 for status", or gets search hits, it has no immediate human context. Agents end up doing extra `search_messages` or resource reads just to label the IDs.

The combination means: even when access is granted, the agent experience remains clunky (ID-heavy, discovery-heavy).

## Current State (post-implementation of the 2026-06-06 spec)

**Subscription path (largely complete):**
- `SlashCommand` parses `/subscribe-bot ...` and `/unsubscribe-bot ...` → `{:bot_subscription, ...}`.
- `ChatLive.BotSubscription` module fully implements the handler (flag check with "Unknown command" discipline on flag-off, bot resolution via `Accounts.get_bot_by_username("mcp-"<>name)`, delegation to `Members`, nice flashes that include the human `##{channel.name}` + the id, error cases for private/unauthorized/not-a-bot/etc.).
- `Chat.Members.add_bot_member/3` and `remove_bot_member/3` exist, reuse `manage_members` + `public_channel` + `ensure_bot`, use the correct `on_conflict: :nothing` + explicit existence check (ghost handling noted in comments).
- Dispatch wired in `ChatLive.Index`.
- `subscribe_bot_test.exs` has unit coverage + the **mandatory** full-path integration test: owner runs the slash command in the LiveView → the *same* raw bearer token can now successfully call the MCP `send_message` tool (before = "Not a member", after = success + message persisted). This test caught a real teardown race (FunWithFlags + on_exit) that was fixed in the recent RCA.
- Webhook bots already had a similar `subscribe_bot` pattern that was lifted.

**Names exposure (partially done, MCP surface is the gap):**
- `Channel` schema: `name`, `slug`, `description`, `is_private`.
- `Serializer.channel/2`: already emits `id`, `name`, `slug`, `description`, `member_count`, `inserted_at`.
- `read_resource("tenun:///channels")` serves the public list using the serializer.
- `BotSubscription` success messages already surface the human name to the *operator*.
- `list_user_channels/1` exists for the human sidebar.
- **Missing for agents:** bot-scoped view, names attached to messages/search results, improved tool ergonomics and instructions, no `get_channel` or equivalent helper.

**Other relevant:**
- `check_membership` (used by all write tools) is simply presence of a role via `get_role`.
- Factory tools (`queue_factory_run` etc.) take a `channel_id` for status updates/heartbeats — names would make choosing that ID far less painful.
- No schema or migration changes required for either item.

## Constraints & Principles (must be respected)

- Everything user-facing (commands, any new MCP surface) stays behind `:bot_subscription` (already the case for the slash commands).
- Full producer→consumer integration test discipline (CLAUDE.md): a change that affects "bot can now act in a channel" or "agent can discover by name" must have at least one test that exercises the real MCP call after the UI action.
- Ecto upsert safety (nil-id ghosts) — already handled correctly in the Members functions.
- Test teardown safety — no `on_exit` DB/flag writes (the recent RCA is the precedent).
- Flag-off behavior never leaks the feature ("Unknown command").
- Public channels only (mirrors webhook constraint).
- Feedback for subscribe is private flash to owner (never a persisted/broadcast/indexed system message containing credentials or coordinates).
- Boundary hygiene: `Chat.Members` owns the authorization + subscription writes; web layer stays thin.
- Dark shipping / small-batch: ship the names enhancements even if subscription flag is still rolling out to the operator.
- Architecture docs + ADRs must be updated (or the existing spec promoted from Draft).

## Proposed Plan (vertical slices, minimal coupling)

### Slice 0 — Baseline & tracking (this session / immediate)
- [x] Create parent bead `slackex-cdi`.
- Audit current code vs 2026-06-06 spec (done in this investigation).
- Run the existing `subscribe_bot_test.exs` (especially the INTEGRATION case) and the MCP router tests locally.
- Confirm the flag can be enabled for the operator account via FunWithFlags UI.
- Write this plan document and commit it.
- Break the remaining work into 1–3 child beads under `slackex-cdi` (subscription polish, MCP names discoverability, docs + rollout).

### Slice 1 — Subscription production polish & operator enablement (small, behind existing flag)
- Operator-facing docs: how to mint a bot token once, then repeatedly `/subscribe-bot <name>` from any public channel the operator manages. Include the exact flash output the agent will later consume.
- Optional small UX: a way for the operator to discover candidate bot usernames (e.g. extend `Accounts.search_users` usage or add a tiny `list_bots` helper surfaced in a help flash or a new `/bots` command — keep scope tiny).
- Verify boundary declarations (new code paths in `Chat.Members` and the web `BotSubscription` module).
- Add or update a contract/integration test that also exercises `search_messages` (scoped) and `reply_to_thread` after subscribe (not just `send_message`).
- Promote the 2026-06-06 spec to "Implemented" (or move key sections into evolution/ or architecture/integrations.md).
- Update the dark-factory / tenun-polish docs that reference channel subscription.

**Acceptance for slice 1:** Operator with the flag on can subscribe the real MCP bot identity to any public channel from chat; the bot can immediately use all write tools + scoped search in that channel via the MCP endpoint. No seeding required. Tests green.

### Slice 2 — Human-readable names as a first-class MCP concern (the main agent-experience win)
Focus here is making names *convenient* inside the agent loop, not just available in one resource.

- Add/enhance a bot-scoped channel listing:
  - Preferred: new tool `list_channels` (or `list_my_channels`) that returns only channels the authenticated `session.bot_user` is a member of, using the existing `Serializer.channel` shape (so names + slugs + ids + counts are all there). This is more useful than the global public list for an agent.
  - Alternative / complement: make the existing `tenun:///channels` resource respect the authenticated bot and filter to member channels when called by an MCP client (or add a query param). Document the choice clearly.
- Enrich message payloads for agent context:
  - Extend `Serializer.message/1` (and `message_from_map`) to include `channel_name` and `channel_slug` (denormalized from the message's preloaded or looked-up channel, or passed through from search results). Keep it cheap — only when the data is already in the query.
  - Update `search_messages` responses to carry this (agents doing broad or hybrid search benefit enormously).
- Improve the surface for agents:
  - Update every tool `inputSchema` description that takes `channel_id` to say: "Channel ID. Discover human names + IDs via the `list_channels` tool or `tenun:///channels` resource. Prefer using the name in your reasoning."
  - Update the server `@instructions` string to mention names and the discovery flow.
  - Consider a tiny `get_channel` tool (id → full Serializer.channel) for symmetry with `find_user`.
- Factory coordination polish: when `queue_factory_run` (or the coordinator) chooses a status `channel_id`, the human-readable name should be visible in the plan / logs so the operator knows where the thread will appear.
- Add serializer contract tests for the new fields.

**Acceptance for slice 2:** An agent connected as a freshly subscribed bot can:
1. Call the new/updated listing mechanism and see entries like `{id: "5", name: "deploys", slug: "deploys", ...}` without prior knowledge.
2. Perform `search_messages` (or receive send results) and have `channel_name` present in the returned objects.
3. Reason in natural language about "#deploys" or "the CI channel" while still passing the correct numeric `channel_id` to tools.

All existing MCP clients continue to work (additive fields only).

### Slice 3 — Documentation, rollout, and cross-checks
- Update `docs/architecture/integrations.md` (MCP section) and `docs/feature/mcp-server/design/architecture.md` with the new capabilities and the subscription story.
- Update or close the "tenun polish" plan / superpowers specs that reference channel access.
- Add a short note in `docs/architecture/chat.md` or realtime docs about bot membership.
- Operator runbook section: "Granting an agent access to a channel" (mint token once → enable flag for the operator → `/subscribe-bot` in the desired public channels → tell the agent the name + id pair).
- Run full quality gate + the specific subscribe + MCP integration paths.
- If any new MCP surface is added, consider whether it needs a small contract test (like the existing boundary one).
- Mark the parent bead done only after the integration test (subscribe in UI → agent uses name + id successfully) is green and docs are updated.

**Optional nice-to-have (later bead):** A `resources/list` or prompt that gives the agent a "channel directory" with names + short descriptions + recent activity hint.

## Non-Goals (for this plan)
- Private channel bot subscriptions.
- Automatic subscription at bot creation time (the mental model in the spec is deliberate: one bot + N explicit subscriptions).
- Changing the auth model or returning tokens from chat.
- Full real-time SSE for the new listing (the existing resource model is pull-based for channels).
- Renaming the numeric IDs (they remain the stable identifiers for all APIs).

## Risks & Mitigations
- Test isolation for the flag (already burned us once) → use per-test `FunWithFlags.enable` inside the sandbox transaction; the safety test will catch regressions.
- Agents start hard-coding names in prompts → the plan explicitly improves the *machine-readable* surface (serialized names) so the LLM sees them in tool output rather than having to be told in natural language.
- Subscription vs global public channels list → we surface a *member* list for the bot so it doesn't have to filter the global list itself.
- Boundary creep → keep new logic in `Chat.Members` or a small MCP-specific context helper; the web `BotSubscription` stays a thin coordinator.

## Verification Before "Done"
- All new/modified code covered by tests (unit + the full subscribe → real MCP call integration test).
- `mix test --only contract` (or equivalent) still passes.
- `credo --strict`, dialyzer, format.
- Manual smoke: enable flag for operator, subscribe bot to a public channel via slash command in the UI, use an MCP client (Claude Code harness or curl) with that bot's token to list channels (see the name), search, send a message using the ID, see the name in the response.
- Pre-deploy script (or at least the ci alias) green.
- Relevant architecture / runbook / spec docs updated and cross-linked.
- No new beads left open for this work (or they are explicitly deferred with reasons).

## Tracking
- Parent: `slackex-cdi`
- Child beads will be created for the slices (or individual verticals) as they are claimed. Use `bd update ... --claim`, `bd close` etc.
- This plan document lives at `docs/plans/2026-06-12-tenun-mcp-bot-channel-access-and-names-plan.md` and should be referenced from the bead and from the 2026-06-06 spec when it is promoted.

This gives us a clean, spec-anchored, test-driven path that directly solves the two issues the user described while staying inside the project's existing rigorous delivery model. The heavy lifting on subscription is already done; most of the remaining effort is making the *agent's* view of channels as pleasant as the human operator's view already is in the flashes.