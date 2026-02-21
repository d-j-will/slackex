# Testing Strategy — Testing Trophy

## Philosophy

We follow the **Testing Trophy** approach (Kent C. Dodds), not the traditional test pyramid. The bulk of tests are **behavioral integration tests** that exercise the system through its public APIs — the same interfaces that LiveView, Channels, and mobile clients use.

**Guiding principle:** _"The more your tests resemble the way your software is used, the more confidence they give you."_

### Test Distribution

```
         ╱╲           E2E (3-5 tests)
        ╱ 5% ╲         Critical user journeys via Wallaby
      ╱────────╲
     ╱          ╲
    ╱    75%     ╲     Behavioral Integration Tests
   ╱  Context APIs  ╲   LiveView interactions
  ╱  Channel protocol ╲  Cache cascade behavior
 ╱   Search behavior    ╲ Reconnection catch-up
╱────────────────────────╲
│      15% Unit           │ Snowflake, Permissions, RateLimiter
╠═════════════════════════╣ Pure functions only
│   5% Static Analysis    │ Dialyzer, Credo, Boundary, compiler
└─────────────────────────┘
```

### What We DON'T Test

- GenServer internal state shapes (test behavior instead)
- Ecto changeset validation in isolation (test through context API)
- Individual private functions
- Phoenix router/pipeline plumbing
- Third-party library internals

### What We DO Test

- User-meaningful behaviors through public APIs
- System behavior under realistic conditions (multiple users, concurrent messages)
- Cache cascade correctness (ETS → Redis → Postgres)
- Real-time message delivery across subscribers
- Authorization boundaries (who can do what)
- Reconnection and catch-up accuracy
- Search relevance (FTS + semantic)

## Static Analysis Layer

Zero-runtime-cost confidence. Runs on every commit via pre-commit hook and CI.

- **Compiler + Boundary** (`mix compile --warnings-as-errors`): catches unused variables/imports, pattern match warnings, boundary violations, missing function clauses, deprecated usage
- **Credo** (`mix credo --strict`): consistent code style, common anti-patterns (see `05-ci-cd-devops.md`)
- **Dialyzer** (`mix dialyzer`): type mismatches, unreachable code, contract violations

## Test Support Infrastructure

### Factory (ExMachina)

`Slackex.Factory` — `use ExMachina.Ecto, repo: Slackex.Repo`

Factories defined for all schemas:
- **user** — sequenced username/email, hashed password, status "offline"
- **channel** — sequenced name/slug, associated creator
- **private_channel** — channel with `is_private: true`
- **subscription** — user + channel, role "member"
- **message** — Snowflake ID, sequenced content, associated sender + channel
- **dm_conversation** — two users with `user_a_id < user_b_id` invariant
- **read_cursor** — user + channel, `last_read_message_id: 0`

Helper: `with_subscription(channel, user, role)` — inserts a subscription and returns the channel.

### Test Case Modules

- **`Slackex.DataCase`** — sets up Ecto sandbox (shared mode when not async), imports Repo/Ecto/Factory. Phase 3 adds `Slackex.ReadRepo` sandbox owner.
- **`SlackexWeb.ConnCase`** — builds `Phoenix.ConnTest` conn, provides `log_in_user/2` (session-based) and `generate_token/1` (JWT)
- **`SlackexWeb.ChannelCase`** — sets up sandbox for Phoenix Channel tests, provides `generate_token/1`

## Behavioral Integration Tests

### Accounts Behavior (`test/slackex/accounts_test.exs`)

- `describe "user registration"`
  - valid attributes create a user
  - duplicate username is rejected
  - weak password is rejected
  - username must be lowercase alphanumeric

- `describe "authentication"`
  - valid credentials return the user
  - wrong password returns nil
  - session token can be generated and verified
  - deleted session token no longer works

### Chat Behavior (`test/slackex/chat_test.exs`)

- `describe "channel lifecycle"`
  - creating a channel auto-subscribes creator as owner
  - channel slugs are unique and URL-safe
  - user can join a public channel
  - user cannot join a private channel without invite
  - leaving a channel removes subscription

- `describe "messaging behavior"` (setup: alice creates channel, bob joins)
  - subscribed user can send a message
  - messages appear in channel history in order
  - non-subscriber cannot send messages
  - message content is sanitized (XSS prevention)
  - messages use Snowflake IDs (monotonically increasing)

- `describe "unread tracking"`
  - unread count reflects messages since last read
  - marking as read resets unread count
  - new channel has zero unread

- `describe "direct messages"`
  - two users can start a DM conversation
  - DM conversation is the same regardless of who initiates
  - DM messages are persisted and retrievable
  - only DM participants can send messages

### LiveView Behavioral Tests (`test/slackex_web/live/chat_live_test.exs`)

- `describe "chat experience"` (setup: alice+bob in #general, conn logged in as alice)
  - user sees their channels in sidebar
  - selecting a channel shows its messages
  - sending a message makes it appear
  - real-time message from another user appears (via PubSub)
  - unauthenticated user is redirected to login

### Channel (Mobile) Behavioral Tests (`test/slackex_web/channels/chat_channel_test.exs`)

- `describe "mobile chat experience"` (setup: alice+bob sockets connected via JWT)
  - joining a channel succeeds for subscribers
  - joining returns recent message history
  - sending a message broadcasts to channel
  - unauthorized user cannot join private channel
  - invalid token rejects connection

### Search Behavioral Tests (`test/slackex/search_test.exs`)

- `describe "full-text search"` (setup: 4 messages with varied content)
  - finds messages matching keywords
  - returns empty list for no matches
  - search can be scoped to a specific channel

### Cache Behavioral Tests (`test/slackex/cache_test.exs`, async: false)

- `describe "cache cascade behavior"`
  - cache miss falls through to database
  - subsequent reads come from cache
  - cache invalidation forces DB re-read

## Unit Tests (Pure Functions Only)

### Snowflake (`test/slackex/infrastructure/snowflake_test.exs`)

- generates unique IDs (1000 IDs all unique)
- IDs are monotonically increasing
- IDs are positive 64-bit integers
- timestamp can be extracted from ID

### Permissions (`test/slackex/chat/permissions_test.exs`)

- owners can do everything
- admins can manage but not delete
- members can send and read
- viewers can only read
- nil role has no permissions

### RateLimiter (`test/slackex/infrastructure/rate_limiter_test.exs`)

- allows requests within rate limit
- rejects requests exceeding rate limit
- tokens refill after the time window elapses
- rate limiter is independent per instance

## E2E Tests (Critical Journeys Only)

Tagged `@tag :e2e`, excluded by default. Uses Wallaby with `SlackexWeb.FeatureCase`.

- **register → create channel → send message → other user sees it** — full registration through real-time message delivery across two browser sessions
- **direct message flow** — alice DMs bob, bob sees notification and message

## Distributed Tests (Phase 3)

Tagged `@moduletag :distributed`, excluded by default. Uses `LocalCluster` to start 3 BEAM nodes.

### Core Distribution Tests

- **channel process exists on exactly one node** — starts channel, verifiable from all nodes via Horde registry
- **channel process migrates on node failure** — kills hosting node, verifies channel restarts on surviving node within timeout

### Split-Brain & Fencing Tests

- **writer epoch prevents stale writes** — start ChannelServer, simulate epoch bump (another writer took over), verify batch write is rejected
- **concurrent ChannelServers during partition** — use `LocalCluster` to create a network partition (`:net_kernel.disconnect/1`), verify both sides can accept messages, heal partition, verify only the higher-epoch writer's pending writes succeed, verify Snowflake dedup resolves overlapping IDs via `ON CONFLICT DO NOTHING`

### Replica Consistency Tests

- **recent messages use primary after cache miss** — send message, immediately query via `HistoryLoader.recent/2`, verify it hits Primary (not ReadRepo)
- **lag fallback triggers on high replication delay** — mock `pg_last_wal_replay_lsn()` monitoring to simulate >5s lag, verify all queries fall back to Primary, verify telemetry event emitted

### Partition Migration Tests (tagged `@tag :migration`, manual only)

- **row count matches after migration** — run partition migration on test data, verify `count(*)` matches pre-migration count
- **Snowflake-based pagination with partition pruning** — query with `before_id`, verify `EXPLAIN` shows partition pruning (not scanning all partitions)
- **embedding join uses partition key** — verify `EXPLAIN` on semantic search join shows partition pruning via `(message_id, message_inserted_at)`

### Crash Recovery Tests

- **ChannelServer recovers un-persisted messages on restart** — send messages, kill ChannelServer before flush, restart, verify init/1 reconciliation re-persists from cache

## Test Configuration

- **Repo:** port 5433 (test Postgres), SQL Sandbox pool, `MIX_TEST_PARTITION` support
- **Endpoint:** port 4002, `server: false`
- **Logger:** level `:warning`
- **Oban:** `testing: :inline` (synchronous execution)
- **Embeddings:** `StubClient` (no API key needed)
- **Bcrypt:** `log_rounds: 4` (faster hashing in tests)
- **libcluster:** `topologies: []` (no clustering)
- **test_helper.exs:** `exclude: [:e2e, :distributed]`, `capture_log: true`, manual sandbox mode

## Running Test Subsets

```bash
mix test                           # Standard tests (excludes :e2e, :distributed)
mix test --include e2e             # Include browser tests
mix test --include distributed     # Include cluster tests
mix test test/slackex/chat_test.exs  # Specific file
mix test --only search             # Tests matching a tag
mix test --cover                   # With coverage report
```

## Acceptance Criteria

- [ ] All test support modules (Factory, DataCase, ConnCase, ChannelCase) are configured
- [ ] ExMachina factories exist for all schemas (User, Channel, Message, etc.)
- [ ] Behavioral integration tests cover: registration, auth, channel CRUD, messaging, DMs (including sender authorization), unread tracking
- [ ] LiveView tests verify: channel selection, message sending, real-time delivery, auth redirect
- [ ] Channel tests verify: join, send, broadcast, auth rejection
- [ ] Search tests verify: FTS keyword matching, scoping by channel
- [ ] Cache tests verify: miss fallthrough, cache population, invalidation
- [ ] Unit tests cover only: Snowflake, Permissions, RateLimiter (pure functions, including token refill behavior)
- [ ] E2E tests cover: full registration→chat flow, DM flow
- [ ] Distributed tests cover: single-writer guarantee, node failover, split-brain fencing, crash recovery reconciliation
- [ ] Replica consistency tests cover: recent-window primary routing, lag fallback
- [ ] Migration tests (manual) cover: row count validation, partition pruning verification
- [ ] Test config uses: SQL Sandbox, inline Oban, stub embeddings, reduced bcrypt rounds
- [ ] `mix test` runs all standard tests (excluding :e2e and :distributed)
- [ ] `mix test --include e2e` runs browser tests
- [ ] `mix test --include distributed` runs cluster tests
- [ ] Tests run in parallel where possible (async: true)
