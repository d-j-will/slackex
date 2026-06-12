# Agent Ops Snapshot Dogfood Runbook

## Purpose

This runbook verifies the MVP agent-visible ops loop:

1. an authenticated MCP client lists resources
2. it reads `tenun:///ops/summary`
3. it posts a short human-readable status message back into a Slackex channel

This is intentionally narrow. It validates inspectability plus reporting, not full operational automation.

---

## Preconditions

- Slackex is running locally
- test or dev PostgreSQL and Redis are running
- you have a valid MCP bearer token tied to a bot user (`McpTokens.create_mcp_token/1` in IEx or equivalent; note the raw token shown once and the `<name>` you supplied)
- the `:bot_subscription` flag is enabled **for your operator user** (e.g. `FunWithFlags.enable(:bot_subscription, for: operator_user)`)
- the bot user is a member of the channel you will post into — **achieved by the operator running the in-chat command below (no seeding)**

### Subscribe the MCP bot to a channel (operator step — replaces seeding)

From any **public** channel in the Slackex UI (as a user with manage-members permission):

1. Type `/subscribe-bot <name>` (where `<name>` is the label you chose at token mint time; do **not** include the `mcp-` prefix).
2. Expect a private success flash (only you see it):

   ```
   ✓ claude-code-max subscribed to #engineering — channel_id: 123456789012345678 (use as the target for send_message / reply_to_thread)
   ```

   The `channel_id` value is exactly what you pass in subsequent MCP `tools/call` arguments.

3. To remove later: `/unsubscribe-bot <name>` (same channel).

Flag-off or unauthorized use yields either "Unknown command: /subscribe-bot" (no leak) or precise errors ("Bots can only be subscribed to public channels", permission message, "No bot named '…' found", etc.). See full details + test coverage in `docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md`.

After this one-time (per channel) step, the agent harness using the bearer can use all write + scoped search tools in the channel immediately.

---

## Granting an agent access to a channel

**Mint token once → enable flag for the operator → `/subscribe-bot` in the desired public channels → tell the agent the name + id pair.**

This is the supported, documented operator path for giving a Tenun MCP bot (agent) access to public channels. It replaces any prior seeding. The flow keeps token minting out-of-band (one time), uses the in-app slash command for repeatable per-channel grants, and hands the agent human-friendly coordinates (name + id) so it can discover and act without memorizing bare IDs.

1. **Mint the token once (out of band)**: Run in IEx (production path):
   ```
   {:ok, %{bot_user: bot, raw_token: raw_token}} = McpTokens.create_mcp_token(%{name: "claude-code-max"})
   ```
   Record the `<name>` you supplied ("claude-code-max") and the **raw bearer token** (shown once only; its SHA-256 hash is stored). The bot identity is the user `mcp-<name>` (`is_bot: true`). Configure your MCP client/harness (e.g. hermes `mcp add` or `.mcp.json`) with the server URL + this bearer. One agent identity, N channels.

2. **Enable the flag for the operator (per-user, initially)**: 
   ```
   FunWithFlags.enable(:bot_subscription, for: <your_operator_user>)
   ```
   (Or use the FunWithFlags admin UI.) This keeps the command surface dark for everyone else. The flag also gates the MCP list_channels scoping and related ergonomics in a dark-shippable way (additive reads).

3. **Subscribe the bot via `/subscribe-bot <name>` in the desired public channels** (repeat for each channel you want the agent in):
   - In the Slackex UI, enter any **public** channel where you have `manage_members` permission (owner/admin+).
   - Type exactly:
     ```
     /subscribe-bot claude-code-max
     ```
     (Use the bare `<name>` from mint time; the system resolves `mcp-<name>` internally.)
   - Success is a **private flash** (only the operator sees it; never broadcast to the channel):
     ```
     ✓ claude-code-max subscribed to #engineering — channel_id: 123456789012345678 (use as the target for send_message / reply_to_thread)
     ```
     (Exact flash text; includes the human `##{channel.name}` and the raw Snowflake `channel_id` for convenience.)
   - The bot is now a member (Subscription row, role "member"). It can immediately use `send_message`, `reply_to_thread`, `react_to_message`, and scoped `search_messages` (and see itself in `list_channels`).
   - Idempotent; errors are clear ("Bots can only be subscribed to public channels", permission denied, "No bot named '…' found", "Unknown command: /subscribe-bot" when flag off — no leak).
   - Revoke with `/unsubscribe-bot claude-code-max` in the same channel.

4. **Tell the agent the name + id pair**: Pass the channel human name (e.g. "engineering" or "#engineering") and/or id to the agent (in its initial prompt, a config note, or a setup message in a channel it can see). The agent is expected to:
   - Discover/confirm via the `list_channels` tool (bot-scoped; returns rich `{id, name, slug, description, member_count, ...}` for only the channels this bot is subscribed to) or the `tenun:///channels` resource.
   - Use human names in its reasoning (per updated tool `inputSchema` descriptions and server `@instructions`).
   - Pass the `channel_id` (string) to action tools.

Full details, rationale, error cases, and authorization matrix: `docs/superpowers/specs/2026-06-06-bot-channel-subscription-design.md` (Implemented). Evolution: `docs/evolution/2026-06-10-bot-subscription.md`. Architecture: `docs/architecture/integrations.md` §6 (MCP) and `docs/architecture/chat.md`. Cross-cutting integration test (UI subscribe producer → real MCP consumer using names + ids + enriched results) lives in `test/slackex_web/live/chat_live/subscribe_bot_test.exs`.

Subscriptions are durable (survive deploys/restarts). The `:bot_subscription` flag controls only the command/UX surface.

---

## 1. Initialize MCP

Send an authenticated JSON-RPC request to `/mcp`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize"
}
```

Expected result:

- HTTP `200`
- JSON-RPC result with `protocolVersion`
- `mcp-session-id` response header present

---

## 2. Discover The Resource

Call `resources/list`:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "resources/list"
}
```

Expected result:

- `tenun:///ops/summary` appears exactly once in the returned resources

---

## 3. Read The Ops Snapshot

Call `resources/read`:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "resources/read",
  "params": {
    "uri": "tenun:///ops/summary"
  }
}
```

Expected payload fields:

- `generated_at`
- `node`
- `active_channel_servers`
- `lobby_presence_count`
- `queue_running_counts`
- `partial_failures`

Notes:

- `lobby_presence_count` is only the count visible in `users:lobby`
- `queue_running_counts` is not backlog depth
- if `partial_failures.<key>` is non-null, treat the paired field as fallback-only

---

## 4. Post A Human-Readable Status Message

Use the existing `send_message` MCP tool and derive a short summary from the snapshot.

Example message:

```text
Ops snapshot: node=slackex@app1 active_channel_servers=3 lobby_presence_count=1
```

Example tool call:

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "send_message",
    "arguments": {
      "channel_id": "123",
      "content": "Ops snapshot: node=slackex@app1 active_channel_servers=3 lobby_presence_count=1"
    }
  }
}
```

Expected result:

- tool call succeeds
- the returned message payload contains the same text
- the message appears in the target channel as the bot user

---

## 5. Success Criteria

The dogfood loop is successful when:

- the MCP client can authenticate successfully
- `resources/list` exposes `tenun:///ops/summary`
- `resources/read` returns the expected snapshot shape
- a derived status message can be posted back into Slackex using `send_message`

If any snapshot field reports a partial failure, the loop still counts as successful as long as:

- the JSON shape remains valid
- the failure is sanitized
- the posted message is still derived from the available snapshot fields

---

## 6. Things This Runbook Does Not Prove

- queue backlog accuracy
- full observability coverage
- factory run inspection
- SSE or subscription-based updates
- agent authorization scopes beyond the current bearer-token model
