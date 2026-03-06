# Test Gap Remediation — Design

## Goal

Fill the two remaining gaps in the testing strategy spec (06-testing-strategy.md): contract test tagging and multi-session E2E tests.

## Part 1: Contract Test Tagging

Add `@moduletag :contract` to existing test files that verify API and WebSocket payload stability:
- `test/slackex_web/channels/envelope_contract_test.exs`
- `test/slackex_web/controllers/api/auth_controller_test.exs`
- `test/slackex_web/controllers/api/bootstrap_controller_test.exs`
- `test/slackex_web/controllers/api/serializer_test.exs`
- `test/slackex_web/controllers/api/device_token_controller_test.exs`

Keep contract tests in the default suite (no `:contract` exclude in test_helper.exs) so developers run them locally. Add a dedicated `mix test --only contract` CI step for visibility/reporting.

## Part 2: Multi-Session E2E Tests (LiveView)

Use LiveView test helpers (ConnCase) instead of Wallaby. No new dependencies.

Tests in `test/slackex_web/live/chat_live/e2e_test.exs`, tagged `@moduletag :e2e`:

1. **Register, create channel, send message, other user sees it** — Two `live/2` connections. Alice creates channel, bob joins, alice sends message, bob's view receives it via PubSub. Use `assert_receive` for async PubSub delivery.

2. **DM request flow** — Alice sends DM request to bob, bob accepts, alice sends message, bob sees it. Tests the full request/accept gate, not just direct messaging.

## Edge Cases

- PubSub delivery is async in LiveView tests — use `assert_receive` or `render` after PubSub broadcast, not `Process.sleep`
- DM tests must go through the request/accept flow to reflect real usage
- Contract tests stay in default suite to catch breakage locally; CI `--only contract` step is for reporting

## Out of Scope

- Distributed tests (LocalCluster, Horde failover, split-brain) — separate design, already multi-node in production
- Wallaby browser tests — deferred unless JS hook bugs become a real problem
