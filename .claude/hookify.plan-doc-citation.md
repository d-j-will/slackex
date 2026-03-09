---
name: block-plan-without-doc-citation
enabled: true
event: file
action: block
conditions:
  - field: file_path
    operator: regex_match
    pattern: docs/plans/.*\.md$
  - field: content
    operator: not_contains
    pattern: "context7"
---

🚫 **BLOCKED: Plan step written without documentation citation**

You are writing to a plan file without referencing a documentation source. Every plan step that depends on library-specific behavior (metric naming, API shape, config options, supported types) **must** cite where the information was verified.

**Required before this file can be written:**
1. Fetch docs via `context7` MCP tool, `WebFetch`, or `mix hex.info`
2. Include a citation in the plan (e.g., "Verified via context7: TelemetryMetricsPrometheus.Core does not append unit suffixes")
3. Reference the specific version of the library being used

**Acceptable citation formats:**
- `Verified via context7: [library] [specific fact]`
- `Verified via hex.pm docs: [URL or package@version]`
- `Verified via WebFetch: [URL]`

**Why this is a blocking rule:**
Observability v1 plan assumed `summary` metric type support, unit suffixes on metric names, `attach/2` API for Req instrumentation, Oban `check_queue` return shape, and Tempo v2 config compatibility with `:latest` — six bugs from uncited assumptions in the plan that were faithfully implemented by the coding agent.

Plans that contain uncited library assumptions will be implemented literally, propagating the error through the entire feature.

See CLAUDE.md § "Library Documentation Verification (NON-NEGOTIABLE)".
