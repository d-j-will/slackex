# Slackex

## Project Overview

Elixir/Phoenix LiveView messaging application (Slack/Discord-style). PostgreSQL database with Docker for development. Snowflake IDs for message ordering. PubSub for real-time updates.

Key directories:
- `lib/slackex/` — domain contexts (Chat, Messaging, Accounts)
- `lib/slackex_web/` — LiveView, components, router
- `test/` — ExUnit tests (1,600+ tests)
- `priv/repo/migrations/` — Ecto migrations
- `docs/` — feature specs, evolution docs, research

## Environment Prerequisites

Always ensure Docker Desktop and PostgreSQL are running before attempting to start the Phoenix dev server or run tests. Run `docker ps | grep postgres` as a quick check.

## Development Paradigm

functional
@nw-functional-software-crafter

## Architecture Patterns

### Gather → Decide → Act

The default shape for any context function that mixes **database reads, business rules, and side-effects** (the typical "do a thing and apply its consequences" operation). Split the function into three stages so the rules become a pure, independently-testable core:

1. **Gather** — run the read-only `Repo` queries and assemble a plain context struct. No decisions here; just facts. Where the decision depends on the *post-write* state (counts that include the row you are about to insert), the Gather must **project** that state explicitly, and a comment must say so — the decision is then made on the same numbers the side-effects will produce.
2. **Decide** — a **pure** function (`@spec evaluate_*(%Context{}) :: %Action{}`) in a dedicated `Rules` module. No `Ecto`, no `Repo`, no IO — only thresholds (as module attributes) and branching. It returns an `Action` struct of booleans/flags (plus an `error` field for pre-flight rejections). Dispatch on the input struct with function-head guards rather than `if` chains.
3. **Act** — read the `Action` and execute the flagged side-effects. When several writes must succeed or fail together, wrap them in a single `Ecto.Multi` transaction. If `action.error` is set, return `{:error, reason}` and write nothing.

**Why:** the rules can be exercised with plain structs (no DB fixtures), the thresholds live in one obvious place, and the boundary between "what we decided" and "what we did" is explicit. This is the functional-core / imperative-shell idea applied at the context-function level, and it complements the LiveView anti-corruption rule below (validate at the boundary, trust the shape inside).

**Reference implementation:** `Slackex.Chat.Moderation.create_abuse_report/3` (orchestrator) + `Slackex.Chat.Moderation.Rules` (pure core: `ModerationContext`, `ModerationAction`, `evaluate_abuse_report/1`). Pure-core tests in `test/slackex/chat/moderation/rules_test.exs` need no database.

**When to apply:**
- **New features** — any new context operation that gathers data, applies business rules, and produces side-effects should be built this way from the start. Put the rules in a `Rules` (or similarly-named pure) module and unit-test them directly.
- **Refactoring** — candidates are existing context functions that interleave `Repo` calls with `if`/`case` policy logic and writes (often a `with` chain doing pre-flight checks, then a cascade of `upsert_*`/`maybe_apply_*` side-effects). Extract the policy into a pure core, leave a thin orchestrator. Preserve behaviour exactly — pin it with the existing tests first, and watch for post-write timing (project it in Gather).

Not every function needs this. A pure read, a trivial single insert, or a function with no branching policy stays as-is — the pattern earns its keep when **rules** and **IO** are tangled.

## Development Principles

**Delivery philosophy (read first): [`docs/software-delivery-principles.md`](docs/software-delivery-principles.md).** This is the project-agnostic *why* behind how we ship — Lean flow (Muda/Mura/Muri), trunk-based development / one-piece flow, build-quality-in (jidoka) via a single gate with no local↔remote seam, fast feedback as a defended constraint, and the two decoupling mechanisms that make small-batch delivery safe (dark shipping for release, expand/contract for migration). When a delivery trade-off is unclear, reason in flow/batch-size terms and prefer integrating small over batching onto branches. The concrete instantiation of these principles in this repo lives in [`docs/engineering-principles.md`](docs/engineering-principles.md).

When encountering unfamiliar tools or protocol issues (e.g., MCP, SSE, external integrations), research documentation FIRST before attempting trial-and-error fixes. Do not deploy broken iterations to production.

## Production Resilience

Before adding any new supervised process, background worker, or external dependency:

1. **What happens when this fails?** Does the app keep serving traffic, or does it cascade?
2. **Is this essential or non-essential?** Essential (DB, PubSub, Endpoint) gets `restart: :permanent`. Non-essential (embeddings, analytics, sync) gets `restart: :temporary`.
3. **How are errors surfaced?** Silent failures (swallowed errors, `_ = result; :ok`) are worse than loud crashes. Every failure must be visible in logs and metrics.
4. **What is the blast radius?** A crash in one subsystem must not propagate to unrelated subsystems. Use dedicated supervisors with appropriate restart budgets.
5. **How does the system recover?** Degraded functionality should self-heal on next deploy or process restart, without manual intervention.

Incident precedent: v0.5.36 — EmbeddingWorker swallowed errors, cascaded through supervisor, took down the entire app. All CI gates had passed.

## Spec-Driven Acceptance Tests

Every spec that introduces a **PubSub event bridge**, **Oban job pipeline**, or **cross-context integration point** must have at least one integration test that verifies the full producer → consumer path exists. Do not test consumers in isolation by faking the upstream event — that proves the handler works, not that the wiring exists.

```elixir
# BAD: fakes the upstream — proves handler, not wiring
PubSub.broadcast(Slackex.PubSub, "pipeline:events", {:messages_persisted, [id]})
assert_enqueued(worker: LinkPreviewWorker)

# GOOD: exercises the full path — proves the bridge exists
{:ok, _} = Messaging.send_message(channel_id, user_id, "https://example.com")
assert_receive {:batch_result, _, :ok}, 5000
assert_enqueued(worker: LinkPreviewWorker)
```

Incident precedent: v0.5.47-v0.5.64 — `pipeline:events` broadcast was designed in spec but never implemented. Listeners subscribed to a dead topic for 18 hours. All unit tests passed because they faked the upstream event. See `docs/rca/2026-03-06-pipeline-events-bridge-missing.md`.

## Feature Development

When adding feature flags, gate ALL user-facing surfaces (UI, routes, tests) behind the flag from the start. Do not wait for the user to remind you.

## Test Environment

Docker required: `docker compose up -d postgres_test redis` then `mix test`. Test DB on port 5433, Redis on 6379.

**Never write to the database in `on_exit`.** `on_exit` runs in a separate process after the test process — the sandbox owner — has died, so any Repo-backed call there (including `FunWithFlags.enable/disable`, which uses the Ecto persistence adapter) races connection teardown: green locally by timing, `DBConnection.OwnershipError` on slow CI runners. It is also redundant — sandboxed writes roll back with the test's transaction, so there is nothing to clean up. Establish state in `setup`; let the sandbox roll it back. Likewise **never call `Sandbox.mode/2` in a test file**: `setup_sandbox` already gives `async: false` tests shared mode via `start_owner!`, with a durable owner whose teardown flushes and stops ChannelServers *before* revoking the connection — manual `{:shared, self()}` + `:manual` resets re-point ownership at the mortal test pid and cause "ChannelServer flush crashed: cannot find ownership" noise. Both enforced by `test/slackex/test_teardown_safety_test.exs` (escape hatch: `# teardown-db-ok`). Incident: CI run 27250196864 failed after the local pre-commit suite passed — exactly the local↔remote seam the single-gate principle exists to prevent.

**Never dismiss test failures, including intermittent/flaky ones.** If tests fail due to infrastructure, fix the environment first. Don't rationalize a flaky failure as "not a real failure" and move on — investigate it, or if it's a known benign race, document why with evidence rather than waving it away.

This project uses Elixir/Phoenix with LiveView. Target the CI Elixir version for API compatibility — do not use functions like `Enum.sum_by` that may not exist in the CI version. Check `.tool-versions` or CI config for the exact version.

### Ecto upsert safety

**Never use `on_conflict: :nothing` without handling the nil-id ghost struct.** When a conflict occurs, Ecto returns `{:ok, %Struct{id: nil}}` — a struct that looks successful but has no database identity.

```elixir
case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [...]) do
  {:ok, %MySchema{id: nil}} ->
    {:ok, Repo.get_by!(MySchema, unique_field: value)}
  other ->
    other
end
```

## UI Component Conventions

All modals and popovers must implement three dismiss mechanisms:
1. Backdrop click (`phx-click="close_..."` on the overlay div)
2. Escape key (`phx-window-keydown="close_..."` with `phx-key="Escape"`)
3. Explicit close button (X) using `<button phx-click="close_..." class="btn btn-ghost btn-sm btn-square"><span class="hero-x-mark size-5" /></button>`

## Skills and Hooks

The following are **enforced by hooks or guided by skills** — use them instead of manual steps:

- **Migrations**: Use `/new-migration`. Safety hook warns on NOT NULL without default, renames, drops, type changes.
- **Feature flags**: Use `/new-feature`. Guards both context module and LiveView template.
- **Deploy**: Use `/deploy`. Runs `scripts/pre-deploy` (full verification: compile/format/credo/dialyzer/tests/contract/e2e/audit/YAML/Mermaid/Docker build/release boot) then tags.
- **Oban workers**: Hook warns on `_ =` in `_worker.ex` files. Never discard `perform/1` return values.
- **Listener wiring**: Hook warns on `*_listener.ex` files with PubSub subscriptions — reminds to add integration tests for full producer → consumer path.
- **CI deploy edits**: Hook warns on SSH heredoc issues in `ci-deploy.yml`.
- **Docker/Caddy**: Hooks block bare `docker pull`, `caddy reload`, `build:` in prod compose, `--no-verify`.

## Git & Deployment

Always stage ALL changed/renamed files before committing. After any file rename or move, run `git status` to verify nothing is unstaged before proceeding with CI/deploy.

Do not work on branches unless explicitly asked. Commit directly to main. Resolve any existing branch state before starting new work.

## Deployment Summary

- Deploys trigger on version tags (`refs/tags/v*`) only. Pushing to `master` runs CI checks only.
- **GPU is OFF-LIMITS** on the production server. Never enable EXLA/CUDA/OpenCL in prod config.
- Full deployment details: `docs/runbooks/deployment.md`
- Model deployment: `docs/runbooks/model-deployment.md`

## Required Reading

Read the relevant doc **before** working in these areas:

- **How we ship (philosophy)**: `docs/software-delivery-principles.md` — Lean flow, trunk-based development, jidoka gate, dark shipping, expand/contract (project-agnostic *why*)
- **Infrastructure, deployment, CI/CD, Docker, migrations**: `docs/engineering-principles.md` — expand/contract migrations, feature flag lifecycle, test isolation, deploy-safety rules, SSH heredoc gotchas
- **Deployment runbook**: `docs/runbooks/deployment.md`
- **UI/UX decisions**: `docs/design/` — component system, design system, information architecture
- **Incident history**: `docs/rca/` — root cause analyses for past production incidents

## Req Streaming (into: :self)

When using `Req.post(..., into: :self)` for streaming responses:
- The response body is a `%Req.Response.Async{}` struct, **not** a raw reference
- The process receives **raw Mint HTTP messages** (e.g., `{:ssl, socket, binary}`), not `{ref, {:data, data}}` tuples
- You **must** use `Req.parse_message(resp, message)` to translate messages into `[{:data, chunk}]` / `[:done]`
- Clean up with `Req.cancel_async_response(resp)` passing the full `%Req.Response{}`

Incident precedent: v0.5.58-v0.5.61 -- streaming connected (200) but yielded zero tokens because raw Mint messages never matched the receive patterns. See `docs/rca/2026-03-06-summarization-streaming-failure.md`.

## Library Documentation Verification (NON-NEGOTIABLE)

**Never assume library behavior from memory or training data.** Before writing any plan step, config snippet, or implementation that depends on library-specific behavior (metric naming, API shape, config options, supported types), you **must** fetch and verify against current documentation.

**Required sources** (use at least one per library dependency):
- `context7` MCP tool — resolve library ID then query docs
- `WebFetch` — fetch hex.pm docs or GitHub README directly
- `mix hex.info <package>` — verify version compatibility

**What must be verified:**
- Metric/event naming conventions (e.g., does the library append unit suffixes?)
- Supported metric types or configuration options
- Function signatures and required options (e.g., mandatory `buckets` for distribution metrics)
- Setup/initialization APIs (e.g., `setup/0` vs `attach/2` vs plugin-based)
- Wire format and protocol details

**Contract tests are mandatory** when the codebase depends on library-generated names (metric names, event names, header values). These tests assert against actual library output at CI time, catching naming mismatches before they reach production dashboards or alerts.

**Infrastructure image pinning:** Never use `:latest` for Docker infrastructure images (Tempo, Prometheus, Grafana, OTEL Collector). Pin to specific versions. Major version changes break configs silently — there is no test to catch a YAML schema change in a Docker image.

**No silent failure in periodic measurements:** Never `rescue _ -> :ok` in telemetry pollers or periodic measurement functions. If a measurement can't produce data, it must log a warning. Silent rescues hide broken metrics for days — the only symptom is a blank Grafana panel that nobody notices until they need the data.

**Agent cross-checking is mandatory during feature development.** After implementation, dispatch a separate reviewer agent to verify:
1. All library-dependent code matches actual library documentation (not assumptions)
2. Config files reference correct field names for the pinned version of the tool
3. Contract tests exist for every name/format the codebase depends on from an external library
4. No silent error handling (`rescue _ -> :ok`) in periodic or background work

Do not rely on the implementing agent to catch its own assumption errors — the same context that produced the assumption will not question it.

Incident precedent: Observability v1 — plan assumed `summary` metric type support, unit suffixes on metric names, `attach/2` API for Req instrumentation, Oban `check_queue` return shape, and Tempo v2 config compatibility with `:latest` tag. Six bugs discovered during integration testing that should have been caught during planning or review. See `docs/runbooks/observability.md` § "Known Gotchas".

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
