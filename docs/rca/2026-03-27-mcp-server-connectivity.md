# RCA: MCP Server Connectivity (v0.6.1 → v0.7.3)

**Date:** 2026-03-27
**Feature:** Connect Claude Code to Tenun's MCP server
**Duration:** ~12 deploys across one session
**Expected effort:** 1 deploy (simple protocol, existing tools)
**Severity:** No production outage, but massive waste of deploy cycles

## Timeline

| Version | What happened | Outcome |
|---------|--------------|---------|
| v0.6.1 | Added `mcp.davewil.dev` subdomain | Cloudflare buffers SSE |
| v0.6.2 | Added caddy labels for subdomain | Infra correct, still SSE |
| v0.6.3 | Tried `type: sse` → `streamable-http` → `http` | All failed, guessing |
| v0.6.4 | Fixed dialyzer warning | Cleanup |
| v0.6.5 | Added `Phantom.Cache.register` | Capabilities now show |
| v0.6.6 | Removed SSE branch, always return JSON | Still fails |
| v0.6.7 | Handle notifications as 202 | Still fails |
| v0.6.8 | Fix notification dispatch crash | Still fails |
| v0.6.9 | Handle protocol version negotiation | Stdio proxy works |
| v0.7.0 | Wrote pure MCP server from scratch | HTTP works |
| v0.7.1 | Added try/rescue (removed same deploy) | Bandaid |
| v0.7.2 | Added find_user + send_dm tools | Feature complete |
| v0.7.3 | Fixed find_user serialization | Working |

## 5 Whys

**Why did this take 12 deploys instead of 1?**

Because I iterated through fixes without understanding what was actually failing. Each deploy addressed a guess, not a diagnosis.

**Why was I guessing instead of diagnosing?**

Because I never looked at what Claude Code actually sent to the server. I tested with curl using `protocolVersion: "2024-11-05"` — which worked. Claude Code sends `"2025-11-25"` — which crashed. I was testing a different protocol version than the client uses.

**Why didn't I test with the actual client protocol version?**

Because I never read the MCP spec before writing code. The spec defines how version negotiation works. I assumed the version I knew (`2024-11-05`) was current. I also never checked Claude Code's debug logs or server-side error logs to see what was actually happening.

**Why didn't I read the spec first?**

Because I treated this as a configuration problem ("just get the URL and type right") instead of a protocol implementation problem. Each small failure reinforced the "one more tweak" mindset instead of triggering "stop and research."

**Why did I treat it as configuration instead of implementation?**

Because phantom_mcp existed and I assumed it handled the protocol correctly. I trusted the library to do the right thing without verifying. When it didn't work, I blamed the transport config, the URL, the subdomain, Cloudflare — everything except the library's actual protocol handling.

## Root Causes

1. **Untested assumption about phantom_mcp** — assumed it supported current MCP protocol versions. It doesn't (`2025-06-18` max, Claude Code sends `2025-11-25`). One curl with the real client payload would have caught this immediately.

2. **Testing with different inputs than the real client** — curl with `2024-11-05` passed. Claude Code with `2025-11-25` crashed. The diagnostic test didn't match the production input.

3. **No observability into the failure** — "Failed to connect" with zero detail. No server logs checked, no client debug logs checked, no request/response captured until v0.6.9 when a diagnostic proxy was added that logged the actual request.

4. **Spec not read before implementation** — the MCP Streamable HTTP spec defines notification handling (202), content negotiation (JSON vs SSE), and version negotiation. All three were bugs shipped and fixed incrementally.

5. **Sunk cost / "almost there" bias** — each deploy felt like the last one needed. The iterative-fix hook (`block-iterative-fixes.sh`) now exists specifically to interrupt this pattern.

## What Should Have Happened

1. Read the MCP Streamable HTTP spec (10 min)
2. Curl the server with the exact headers/body Claude Code sends — including the correct `protocolVersion` (5 min)
3. Discover Phantom returns 500 for the version Claude Code sends
4. Write `Server.ex` with proper version negotiation, notification handling, JSON responses (30 min)
5. Deploy once, test, done

**Total: ~45 minutes, 1 deploy.**

## Preventive Measures

| Measure | Status |
|---------|--------|
| `block-iterative-fixes.sh` hook — blocks 3+ fix(scope) in 2h without `[doc-verified]` | Deployed |
| Feedback memory: "No iterative guessing" | Saved |
| CLAUDE.md: "Library Documentation Verification (NON-NEGOTIABLE)" | Already existed, was ignored |
| Always test with actual client inputs, not assumed ones | Lesson learned |
| When "Failed to connect" — check server logs and client debug logs first, not guess at fixes | Lesson learned |

## Resolution

Replaced phantom_mcp transport layer with `SlackexWeb.MCP.Server` — a ~300-line Plug that implements the MCP Streamable HTTP spec directly. Returns `application/json` for all requests, handles any protocol version by responding with the latest supported version (`2025-03-26`), and returns `202 Accepted` for notifications. No phantom_mcp dependency for the transport layer.

The phantom_mcp library remains as a dependency for the Router DSL (tool/resource/prompt macros) used by `SlackexWeb.MCP.Router`, but the HTTP transport is entirely custom.
