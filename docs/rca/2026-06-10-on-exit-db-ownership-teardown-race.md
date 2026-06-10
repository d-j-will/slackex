# RCA: DBConnection.OwnershipError in on_exit Teardown (CI run 27250196864)

**Date:** 2026-06-10
**Severity:** P3 — CI-only failure, no production impact, no data loss
**Duration:** ~9 minutes from red CI (`ac3c3f26`, 03:01 UTC) to fix merged (`1f79194c`, 12:08 local / verified green by 11:11 UTC run on the fix commit)
**Trigger:** `slackex-luc` push (`ac3c3f26`, "chore(beads): close slackex-luc") went red on the Quality job's Tests step
**Surfaces affected:** Test suite only — `SlackexWeb.ChatLive.SubscribeBotTest` and 22 other latent offender sites across the suite

## Impact

- One test failed on CI: `INTEGRATION: /subscribe-bot unlocks MCP send_message for the bot` (`test/slackex_web/live/chat_live/subscribe_bot_test.exs:137`), exit code 2, 1 failure of 1647 tests.
- The Tests step failed, which gated the pipeline: Contract tests, E2E tests, Hex audit, and Deploy were all skipped.
- **No production impact.** This was a test-teardown race, not an application bug. The feature under test worked correctly.
- The same code **passed the local pre-commit suite** — the failure only manifested on slower CI runners. This is the local↔remote seam the single-gate delivery principle exists to close.

## Architecture Context

`FunWithFlags` persists feature-flag state through its **Ecto persistence adapter** — `FunWithFlags.enable/2` and `disable/2` are database writes, not in-memory toggles.

The test followed a since-corrected folklore pattern:

```elixir
# FunWithFlags state is shared (not sandboxed); re-enable per test so
# the flag-off test cannot leak into siblings.
FunWithFlags.enable(:bot_subscription)
on_exit(fn -> FunWithFlags.disable(:bot_subscription) end)   # ← the bug
```

The comment's premise ("state is shared, not sandboxed") was **wrong**. Flag writes go through the Repo and therefore roll back with each test's Sandbox transaction, like any other write. The compensating `on_exit` disable was both racy *and* redundant.

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 2026-06-10 03:00 | `d6823e5d` feat(chat): /subscribe-bot slash command — introduces the test with `on_exit` disable. CI red (run 27250133107). |
| 2026-06-10 03:01 | `ac3c3f26` chore(beads): close slackex-luc — same race, CI run 27250196864 red on Tests step |
| 2026-06-10 ~12:08 (local) | `1f79194c` test(chat): fix DB-ownership race in subscribe-bot teardown — removes the `on_exit` disable |
| 2026-06-10 11:11 UTC | CI run on `1f79194c` green |
| 2026-06-10 ~12:24 (local) | `10d55967` test: forbid DB writes in on_exit — generalizes the fix: static-analysis guard + 22 offender sites removed + CLAUDE.md rule |
| 2026-06-10 11:41 / 11:55 UTC | `df3d2589`, `2566000b` — harden related ChannelServer flush/teardown races; CI green |

## Root Cause Analysis (5 Whys)

**WHY 1: Why did the test fail on CI?**
The `on_exit` callback called `FunWithFlags.disable(:bot_subscription)`, which issued a DB write that raised `DBConnection.OwnershipError` ("cannot find ownership process … using mode :manual").

**WHY 2: Why did the DB write have no connection?**
`on_exit` callbacks run inside `ExUnit.OnExitHandler` — a **separate process that executes after the test process has already exited**. In this suite the test process was the Sandbox connection owner, so by teardown time ownership had been revoked. The write had no checked-out connection to use.

**WHY 3: Why was a DB write being done in teardown at all?**
A comment-encoded misunderstanding: the author believed `FunWithFlags` state was global and unsandboxed, so they "cleaned it up" with a compensating disable. In reality the writes roll back with the test transaction — there was nothing to clean up.

**WHY 4: Why did the local pre-commit suite pass while CI failed?**
Pure timing. The race is between "test process dies / Sandbox checks the connection in" and "OnExitHandler runs the DB write." Fast local machines win that race; slower CI runners lose it. Green-locally / red-on-CI is the signature of a timing-dependent teardown race.

**WHY 5: Why did this pattern exist in 22 other places?**
The folklore comment ("FunWithFlags state is shared (not sandboxed)") was copied across test files as an idiom, propagating both the unnecessary `enable` and the racy compensating `disable` as a paired unit.

## Root Causes

| # | Root Cause | Category |
|---|-----------|----------|
| RC1 | DB write (`FunWithFlags.disable`) performed in `on_exit`, which runs after the Sandbox owner has exited | Test teardown / lifecycle |
| RC2 | Incorrect mental model that `FunWithFlags` state is unsandboxed, justifying redundant cleanup | Knowledge / folklore |
| RC3 | Timing-dependent: passed the local commit gate, failed only on slow CI — a local↔remote seam | Delivery / fast-feedback |
| RC4 | The anti-pattern was copy-propagated to 22 sites with no guard preventing it | Systemic / missing enforcement |

## Fix

**Direct fix (`1f79194c`):** Removed the `on_exit(fn -> FunWithFlags.disable(...) end)` line from `subscribe_bot_test.exs`. The per-test `FunWithFlags.enable/1` in `setup` is sufficient; the sandbox transaction rolls the flag state back automatically.

**Generalized fix (`10d55967`):**
- Added `test/slackex/test_teardown_safety_test.exs` — a static-analysis test that **fails the suite** if any `on_exit` block touches `Repo`, `ReadRepo`, or `FunWithFlags`. Escape hatch for genuine cases: a `# teardown-db-ok` comment.
- Removed all 22 existing offender sites (both the disables and the compensating re-enables — both halves of the same misunderstanding).
- Corrected the folklore comments in `decide_test.exs` and `subscribe_bot_test.exs` with the real mechanics.
- Added the rule, the *why*, and this incident reference to `CLAUDE.md` § Test Environment.

**Adjacent hardening (`df3d2589`, `2566000b`):** Forbade manual `Sandbox.mode/2` in test files and hardened the durable Sandbox owner's teardown to flush and stop ChannelServers *before* revoking the connection — eliminating the related "ChannelServer flush crashed: cannot find ownership" noise seen in the same run's logs.

## Corrective Actions

| # | Action | Status |
|---|--------|--------|
| CA1 | Remove the racy `on_exit` disable in `subscribe_bot_test.exs` | Done (`1f79194c`) |
| CA2 | Static-analysis guard forbidding Repo/ReadRepo/FunWithFlags in `on_exit` | Done (`10d55967`) |
| CA3 | Remove all 22 latent offender sites | Done (`10d55967`) |
| CA4 | Document the rule + mechanics + incident in CLAUDE.md | Done (`10d55967`) |
| CA5 | Forbid manual `Sandbox.mode/2`; harden durable-owner teardown | Done (`df3d2589`, `2566000b`) |
| CA6 | Write this RCA document | Done |
| CA7 | `test_helper.exs` "enable all flags" review (filed as `slackex-9jz`) | TODO |

## Lessons Learned

1. **`on_exit` runs after the sandbox owner dies — never touch the database there.** Any Repo-backed call in teardown (including `FunWithFlags`, which is Repo-backed) races connection revocation. State belongs in `setup`; the sandbox transaction rolls it back. There is nothing to clean up.

2. **Green-locally / red-on-CI means a timing race, not "flaky CI."** The honest move is to investigate the seam, not re-run until green. Here the slow CI runner was the *more correct* environment — it exposed a latent race the fast local machine was masking.

3. **Folklore in comments propagates bugs.** A single wrong premise ("state is shared, not sandboxed") spawned 22 copies of a racy idiom. When a fix corrects a misunderstanding, correct the *comment* too, and prefer a mechanical guard over hoping the next author reads it.

4. **Turn the one-off into enforcement.** The valuable artifact from this incident is not the one-line deletion — it is `test_teardown_safety_test.exs`, which makes the entire class un-reintroducible at the same gate that would otherwise pass it locally.
