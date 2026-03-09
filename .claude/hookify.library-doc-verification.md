---
name: warn-library-doc-verification
enabled: true
event: file
conditions:
  - field: new_text
    operator: regex_match
    pattern: (OpentelemetryReq|OpentelemetryEcto|OpentelemetryPhoenix|OpentelemetryOban|OpentelemetryBandit|TelemetryMetricsPrometheus|Oban\.|Req\.(post|get|put|delete|request)|Nx\.|Bumblebee\.|EXLA\.|Ecto\.Adapters|Phoenix\.LiveView\.JS\.|Plug\.|Tesla\.)
---

⚠️ **Library API usage detected — doc verification required**

You are writing code that depends on a library's API. Before proceeding, you **must** verify the API against current documentation.

**Required steps:**
1. Use `context7` MCP tool to resolve the library ID and query its docs, OR
2. Use `WebFetch` to fetch the hex.pm docs or GitHub README directly, OR
3. Run `mix hex.info <package>` to verify version compatibility

**What must be verified:**
- Function signatures and required options
- Return value shapes (don't assume — verify)
- Metric/event naming conventions
- Configuration options and defaults

**Why this matters:**
Training data assumptions caused 6 bugs in observability v1 (wrong metric types, wrong return shapes, wrong API signatures). Every library-dependent line of code must be traceable to a documentation source.

See CLAUDE.md § "Library Documentation Verification (NON-NEGOTIABLE)" and `docs/runbooks/observability.md` § "Known Gotchas".
