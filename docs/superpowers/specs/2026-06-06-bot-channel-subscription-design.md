# Bot Channel Subscription Design Spec

**Date:** 2026-06-06
**Status:** Implemented (2026-06-12; Slice 1 subscription polish + operator docs; Slices 2a-c names + ergonomics; Slice 3 docs/rollout/final verification complete)
**Feature Flag:** `:bot_subscription`

> **Operator note:** With the flag enabled for your account, simply run `/subscribe-bot <name>` (or `/unsubscribe-bot`) from any public channel you manage. See the runbook guidance in `docs/runbooks/agent-ops-dogfood.md` and the exact success flash below. No seeding required. Full producer→consumer path (UI subscribe → real MCP tools/call) is covered by `test/slackex_web/live/chat_live/subscribe_bot_test.exs`.

## Overview

MCP bot users are not auto-subscribed to any channel (unlike webhook bots, which are subscribed atomically at webhook-creation time). An agent harness authenticated as an MCP bot can therefore connect successfully but every write tool — `send_message`, `reply_to_thread`, `react_to_message` — fails the membership check with `"Not a member of this channel"` until the bot is subscribed by some out-of-band means.

This spec adds an in-chat, owner-driven way to subscribe (and unsubscribe) an existing MCP bot to a channel via two slash commands: `/subscribe-bot <name>` and `/unsubscribe-bot <name>`. The command runs server-side in the channel LiveView as the logged-in owner, resolves the bot by name, and inserts (or deletes) a `subscriptions` row for that bot user in the active channel. No new settings surface, no new tables, no token handling.

The mental model the command implements:

```
ONE bot user (minted in IEx)  +  ONE harness connection (hermes mcp add)  +  N channel subscriptions (/subscribe-bot ×N)
```

Minting the token and configuring the harness happen once and are out of scope here. `/subscribe-bot` is the only repeated step — once per channel — and each invocation adds a single membership row for the one pre-existing, pre-authenticated bot user.

## Constraints

- ~50 active users (homelab/team scale); typically a single operator running one Claude Code MCP bot
- The command must not mint, store, or return any token — the MCP bearer is show-once and only its SHA-256 hash is persisted (see `docs/architecture/integrations.md` §6.1)
- Subscription is pure authorization: it references the bot user created at token-mint time; it never creates a user
- Public channels only — mirrors the webhook subscription constraint (`private_channel_not_supported`)
- Owner-driven and feature-flagged behind `:bot_subscription`
- Reuses the existing role model (`subscriptions.role`) and authorization seam (`manage_members`) — no new permission concepts

## Background: What Already Exists

| Component | Status | Notes |
|-----------|--------|-------|
| `ChatLive.SlashCommand` | Exists | Pure parser: string → tagged tuple. Extensible via `do_parse/1` clauses. Currently handles `/summarize`, `/decide`. |
| `ChatLive.Index` `"send_message"` handler | Exists | Pattern-matches the parsed tuple (`index.ex:350`). Has `current_user`, active channel, and flag context in scope. `/decide` (`index.ex:359`) is the template for a flag-gated, owner-context command. |
| `Chat.Members` | Exists | `update_member_role/4`, `kick_member/3`, `list_members/1` — all gated on `manage_members`. **No `add_member`-style function exists yet.** |
| `Chat.Permissions.can?/2` | Exists | Role hierarchy: owner(4) > admin(3) > member(2) > viewer(1). `manage_members` requires level 3 (admin+). |
| `Integrations.Webhooks.subscribe_bot/2` | Exists | Proven `Subscription` insert with `role: "member"`, `on_conflict: :nothing`, with the nil-id ghost-struct guard. The pattern to lift. |
| `Accounts.search_users/2` | Exists | Trigram user search. Used to resolve the bot by name. |
| Bot user (`is_bot: true`, username `mcp-<name>`) | Exists | Created atomically at `McpTokens.create_mcp_token/1` time. The subscription target. |

## Why a Slash Command (Not a Settings Surface)

Channels currently have no settings concept at all (the schema is `name`, `slug`, `description`, `is_private`). A slash command keeps the entire flow inside the chat UI where the owner already is, reuses the existing two-stage parse → handle seam, and avoids building a channel-settings page solely to host one toggle. It also runs server-side as `socket.assigns.current_user`, so the owner identity is trustworthy and authorization is enforced where the rest of `Chat.Members` enforces it.

## Command Surface

### Parse Stage (`ChatLive.SlashCommand`)

Add `do_parse/1` clauses mirroring the existing `{:summarize, range}` shape (command takes one argument):

```elixir
["subscribe-bot", bot_name]   -> {:subscribe_bot, String.trim(bot_name)}
["subscribe-bot"]             -> {:subscribe_bot_help}
["unsubscribe-bot", bot_name] -> {:unsubscribe_bot, String.trim(bot_name)}
["unsubscribe-bot"]           -> {:unsubscribe_bot_help}
```

The `_help` variants (no argument) flash a usage hint rather than silently doing nothing.

Extend the `@type result` union with the four new tuples.

### Bot Name Resolution

The owner supplies the **bare** name as it was given at mint time (e.g. `/subscribe-bot claude-code-max`). The command prepends the `mcp-` prefix internally to match the bot username (`mcp-claude-code-max`), then resolves to a user where `username == "mcp-#{name}"` **and** `is_bot: true`.

- A non-matching name is a user error, not a silent no-op: flash `"No bot named 'claude-code-max' found"`.
- Requiring `is_bot: true` prevents the command from being used to subscribe arbitrary human users (that is a separate concern with its own invite/join flows).

### Handle Stage (`ChatLive.Index`)

Two new clauses in the `"send_message"` handler, structured exactly like `/decide`:

```elixir
{:subscribe_bot, bot_name} ->
  if FunWithFlags.enabled?(:bot_subscription, for: user) do
    # 1. authorize: owner of the active channel (manage_members)
    # 2. resolve bot user by "mcp-#{bot_name}" + is_bot
    # 3. Chat.Members.add_bot_member(channel_id, actor_id, bot_user_id)
    # 4. flash success (with channel_id) or a specific error; clear input
  else
    # Flag off: behave like an unrecognised command — do not leak the feature.
    {:noreply, put_flash(socket, :error, "Unknown command: /subscribe-bot")}
  end

{:unsubscribe_bot, bot_name} ->
  # same shape, calls Chat.Members.remove_bot_member/3 (delegates to kick_member/3)
```

The flag-off branch reproduces the `/decide` discipline (`index.ex:366-368`): an off flag responds `"Unknown command"`, never `"permission denied"`, so the command's existence is not leaked when the feature is dark.

## Context Layer (`Chat.Members`)

Keep the LiveView thin; put authorization and the insert/delete in the context where the rest of member management lives.

### New: `add_bot_member/3`

```elixir
def add_bot_member(channel_id, actor_id, bot_user_id) do
  with :ok <- authorize(actor_id, channel_id, :manage_members),
       {:ok, channel} <- public_channel(channel_id),
       :ok <- ensure_bot(bot_user_id) do
    %Subscription{}
    |> Subscription.changeset(%{user_id: bot_user_id, channel_id: channel.id, role: "member"})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :channel_id])
    |> case do
      {:ok, %Subscription{user_id: nil}} -> {:ok, :already_subscribed}
      {:ok, subscription} -> {:ok, subscription}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
```

- Reuses the existing private `authorize/3` (the same `manage_members` gate as `update_member_role` and `kick_member`).
- `public_channel/1` rejects private channels (`{:error, :private_channel_not_supported}`), mirroring the webhook constraint.
- `ensure_bot/1` rejects a non-bot target (`{:error, :not_a_bot}`).
- The nil-id ghost-struct guard is honored — a conflict returns `{:ok, :already_subscribed}` rather than treating the nil-id struct as a real row (per CLAUDE.md "Ecto upsert safety").
- Role is always `"member"`. **Pitfall:** the MCP server's `check_membership` treats any role as present, but the actual send re-checks `can?(role, :send_message)` which needs member+. A bot added as `viewer` would pass the membership gate and silently fail to send — so this function hardcodes `"member"`.

### New: `remove_bot_member/3`

Delegates to the existing `kick_member/3` (already `manage_members`-gated, already guards `cannot_kick_owner`), or a thin wrapper that additionally asserts `is_bot` for symmetry. No new authorization logic.

## Return Value: Channel Coordinates, Never Config

`/subscribe-bot` does **not** return MCP harness config. The harness config (server URL + bearer) is a global property of the bot, set once at `hermes mcp add`; subscribing the bot to additional channels does not change it. The bearer also cannot be recovered — only its hash is stored — and anything a slash command emits as a posted message would be Snowflake-ordered, broadcast, batch-persisted, and FTS/embedding-indexed, which is an unacceptable home for a credential.

What the agent genuinely gains from a subscribe is the **channel id** it may now target. The command surfaces that as a private flash to the owner (ephemeral, owner-only, never a posted message):

```
✓ claude-code-max subscribed to #engineering
  channel_id: 7283910011223344  (use as the target for send_message / reply_to_thread)
```

Connection config remains the responsibility of token-mint time (where the raw token is in hand), out of scope for this spec.

## Feedback Channel: Flash, Not System Message

Feedback is a **private flash to the owner**, not a system message posted into the channel. Rationale:

- The webhook subscription path posts nothing — flash-only is the lower-surface, consistent default.
- The typical setup is a single operator; a broadcast "bot was added" message has no audience.
- Keeping the `channel_id` hint in an ephemeral flash avoids persisting coordinates into channel history.

A visible system message ("`claude-code-max` was added by `@david`") is deliberately **not** included; it would only matter in channels with other humans who should notice the bot's arrival, which is not the target scenario. This can be revisited if multi-human channels become a use case.

## Feature Flag & Rollout

Gated behind `:bot_subscription` FunWithFlags flag:

- **Flag off** — Both commands behave as unrecognised commands (`"Unknown command: /subscribe-bot"`); the feature's existence is not leaked. `Chat.Members.add_bot_member/3` is unreferenced from any live surface.
- **Flag on** — Owners (admin+ via `manage_members`) can subscribe/unsubscribe MCP bots in public channels they manage.
- **Per-user gating** — Enable for the operator account first for validation.
- **Rollback:** Disabling the flag re-darkens both commands. Subscriptions already created remain valid (a bot stays a member); to fully reverse, the owner runs `/unsubscribe-bot <name>` per channel while the flag is on, or the rows are deleted directly. No migration is involved, so rollback is flag-only.

Per CLAUDE.md, all user-facing surfaces are gated from the start: parser clauses still parse (harmless), but both the LiveView handler and the absence of any other caller of `add_bot_member/3` keep the behavior fully behind the flag.

## Authorization Summary

| Concern | Decision | Rationale |
|---------|----------|-----------|
| Who may subscribe a bot | `manage_members` (admin+, level 3) | Reuses the existing gate for all member mutations; consistent with `update_member_role`/`kick_member`. Owner (level 4) is included. |
| Channel visibility | Public channels only | Mirrors the webhook constraint; private-channel bot subscription is out of scope. |
| Target user | Must be `is_bot: true` | Prevents the command from subscribing arbitrary humans; bots have their own membership path. |
| Subscription role | Always `"member"` | `viewer` would pass `check_membership` but fail `can?(:send_message)` — silent write failure. |
| Identity binding | Resolve `mcp-<name>` to the bot user the harness token points at | Subscribing the wrong bot user → harness connects as bot A, authorized as bot B → `"Not a member"`. |

## Testing Strategy

### Integration Test (full path — required)

Per CLAUDE.md's spec-driven acceptance rule, exercise the full producer → consumer path, not the parser in isolation:

Owner runs `/subscribe-bot <name>` in a public channel → assert a `subscriptions` row exists for the bot user in that channel → authenticate an MCP request as that bot's token → call `send_message` → assert it succeeds (no `"Not a member"`). This proves the command actually unlocks the MCP write path, not just that a row was inserted.

### Unit Tests

- `SlashCommand` — parses `/subscribe-bot name`, `/subscribe-bot` (help), `/unsubscribe-bot name`, `/unsubscribe-bot` (help), and unknown variants.
- `SlashCommand` — bot name with surrounding whitespace is trimmed.
- `Chat.Members.add_bot_member/3` — happy path inserts `role: "member"`.
- `Chat.Members.add_bot_member/3` — non-owner/non-admin actor → `{:error, :unauthorized}`.
- `Chat.Members.add_bot_member/3` — private channel → `{:error, :private_channel_not_supported}`.
- `Chat.Members.add_bot_member/3` — non-bot target → `{:error, :not_a_bot}`.
- `Chat.Members.add_bot_member/3` — already subscribed → `{:ok, :already_subscribed}` (nil-id ghost-struct guard), idempotent.
- `Chat.Members.remove_bot_member/3` — removes the row; cannot remove a non-member.
- `ChatLive.Index` — flag off → `/subscribe-bot` flashes `"Unknown command"`, inserts nothing (no feature leak).
- `ChatLive.Index` — flag on, non-matching name → flashes `"No bot named '…' found"`.
- `ChatLive.Index` — flag on, success → flash includes the channel id; input cleared.

## Module Summary

| Layer | Module | Change |
|-------|--------|--------|
| Parser | `ChatLive.SlashCommand` | Modify (add `subscribe-bot` / `unsubscribe-bot` clauses + `@type` union entries) |
| LiveView | `ChatLive.Index` (`"send_message"` handler) | Modify (add `{:subscribe_bot, _}` / `{:unsubscribe_bot, _}` clauses, flag-gated like `/decide`) |
| Context | `Chat.Members` | Modify (add `add_bot_member/3`; add `remove_bot_member/3` delegating to `kick_member/3`; private `public_channel/1`, `ensure_bot/1`) |
| Accounts | `Accounts` | No change (reuse `search_users/2` / `get_user` for name resolution) |
| Schema | `Chat.Subscription` | No change (existing `role`/`on_conflict` semantics reused) |
| Gate | `:bot_subscription` flag | New |
| Migration | — | None (no schema change) |

## Implementation Status (Slice 1 complete)

The core implementation, flag gating ("Unknown command" on off), boundary placement (authorization/writes in `Chat.Members`, thin handler in `BotSubscription`), and full integration test were delivered prior to this slice. Slice 1 (bead slackex-si7) added:

- Operator-facing documentation (this section + runbook updates).
- Test expansion in `subscribe_bot_test.exs` exercising `search_messages` (with `channel_id` scope), `reply_to_thread`, and `react_to_message` after a fresh `/subscribe-bot` (in addition to the original `send_message` producer→consumer path). TDD approach: new test cases written first to demonstrate the MCP JSON-RPC calls, then confirmed against the live server implementation.
- Minor UX polish in help text to aid discovery of bot `<name>` values (no new commands or large surface).
- Promotion of this spec and related docs.
- Verification that `FunWithFlags` handling follows the teardown-safety contract (per-test enable in setup; no `on_exit` writes) and that boundary declarations cover the call sites (`Chat` boundary exports `Members`; web layer is intentionally permissive for LiveView internals).

## Operator Runbook (how to subscribe the real MCP bot)

1. Ensure the `:bot_subscription` flag is enabled **for your operator account only** (use FunWithFlags admin UI or IEx: `FunWithFlags.enable(:bot_subscription, for: <your_user>)`). This keeps the feature dark for others until validated.

2. In any **public** channel where you have manage-members permission (owner or admin+), type:

   ```
   /subscribe-bot <name>
   ```

   - `<name>` is the exact label you supplied when running the mint (e.g. `McpTokens.create_mcp_token(%{name: "claude-code-max"})` in IEx). The system resolves internally to the bot user `mcp-<name>` (with `is_bot: true`).
   - The command is **not** available in private channels (error: "Bots can only be subscribed to public channels").
   - Only the actor with manage_members can succeed; otherwise "You need the manage-members permission...".
   - Bare command or unknown bot name gives clear usage / not-found flashes.
   - Idempotent: second subscribe reports "already subscribed".

3. Success flash (private to you, never broadcast as a channel message; exact text the MCP agent later consumes for channel_id):

   ```
   ✓ claude-code-max subscribed to #engineering — channel_id: 123456789012345678 (use as the target for send_message / reply_to_thread)
   ```

   (The human `##{channel.name}` and the raw `channel_id` are both present for convenience.)

4. To revoke: `/unsubscribe-bot <name>` in the same channel. Success: "✓ ... unsubscribed from ##{name}"

5. After subscribe, any agent harness using that bot's raw bearer token (the one-time shown at mint) can immediately call the MCP endpoint (`/mcp`, `tools/call` for `send_message` / `reply_to_thread` / `react_to_message` / `search_messages` with optional `channel_id` for scope) and the membership gate will pass for that channel. No restart or re-auth of the harness needed.

6. Discovery of candidate names: the `<name>` you use is the one you chose at `create_mcp_token` time (the part after the `mcp-` prefix on the bot user). The in-chat help text for bare `/subscribe-bot` now includes a reminder. You can also list your tokens via the domain API or IEx for reference.

References: `docs/evolution/2026-06-10-bot-subscription.md`, `docs/runbooks/agent-ops-dogfood.md`, `docs/architecture/integrations.md` §6.

This replaces any prior seeding scripts for MCP bot channel access. Subscriptions persist across deploys; flag controls only the command surface.

## Post-implementation notes (Slice 3 — docs + rollout + final verification)

Full end-to-end story verified and documented:

- Subscribe in-app (UI `/subscribe-bot` by owner with flag) → bot gains membership.
- Agent discovers subscribed channels by human name via `list_channels` MCP tool (bot-scoped, rich Serializer.channel shape with name/slug/id/etc; also `count_members`).
- Message/search payloads enriched with `channel_name` + `channel_slug` (when channel preloaded/passed; additive, no breakage for bare/DM cases).
- Tool inputSchemas for every `channel_id` (send/reply/react/search/prompts/factory) + server `@instructions` updated with discovery guidance: "Channel ID. Discover human names + IDs via the `list_channels` tool or `tenun:///channels` resource. Prefer using the name in your reasoning." (numeric IDs + names story).
- Small `get_channel` helper (base tool, symmetric to find_user; thin safe_get + Serializer.channel).
- Factory coordination: name attached in queue/claim responses when channel_id chosen (via thin lookup).
- Cross-cutting integration test (subscribe_bot_test.exs): real UI producer flow (/subscribe-bot) → real `/mcp` consumer (list_channels by name, enriched results visible, schema-guided discovery, successful send/search/reply/react using id while name-aware). Full producer→consumer per CLAUDE.md.
- Operator runbook section "Granting an agent access to a channel" (exact mint-once → flag → /subscribe-bot → tell name+id flow + exact flash).
- Architecture docs updated (integrations.md MCP section, mcp-server/design/architecture.md, chat.md bot membership note, tenun-polish-plan.md channel ref closed).
- Spec promoted; evolution + runbook + integrations reference the supported path.
- Quality gates (format/credo/dialyzer/compile --warnings-as-errors + targeted/full test + contract) + specific subscribe/MCP paths green.
- No open work under parent slackex-cdi. Dark shipping preserved (additive for names; subscription flag per-operator).

Key decisions archived (implemented as specified):
- Subscription is the sole supported in-app grant mechanism for MCP bots (no token handling in command, flash-only id surfacing, public-only, manage_members reuse, ghost-struct guard, "Unknown command" on flag off).
- list_channels as the preferred bot-scoped discovery tool (additive to global tenun:///channels resource).
- Names first-class in common payloads + ergonomics (no extra roundtrips for agents; guidance to prefer names for reasoning).
- get_channel as small symmetric helper (documented rationale).
- All surfaces (commands, MCP tools, factory) stay behind appropriate flags from the start.
- Producer-consumer integration tests mandatory for the subscribe + MCP unlock paths.

References for operators/agents: runbook "Granting..." section, `docs/evolution/2026-06-10-bot-subscription.md`, `docs/architecture/integrations.md` §6, `docs/architecture/chat.md`, full test evidence in subscribe_bot_test.exs (and sibling MCP integration tests), prior slices (si7/ih6/dx5/209).

Parent bead (slackex-cdi) marked done only after this evidence + all listed docs current.
