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
- you have a valid MCP bearer token tied to a bot user
- the bot user is a member of the channel you will post into

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
