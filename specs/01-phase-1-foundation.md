# Phase 1 — Foundation

## Goal

A working single-node application with user authentication, channel management, basic messaging through LiveView, and mobile WebSocket connectivity. This phase establishes the project skeleton, boundary architecture, development tooling (Tidewave, Docker, CI), and the database schema foundation.

## Prerequisites

- Elixir 1.17+ / OTP 27+
- PostgreSQL 16+ with pgvector extension
- Redis 7+
- Node.js 20+ (for asset pipeline)

## Step 1: Project Generation & Configuration

### 1.1 Generate Phoenix Project

```bash
mix phx.new slackex --no-dashboard
```

We skip `--no-live` since we want LiveView. Dashboard will be added manually later with auth protection.

### 1.2 mix.exs Configuration

- Add all Phase 1 deps from the dependency table in `00-overview.md`
- Add `compilers: [:boundary] ++ Mix.compilers()` to project config
- Configure Dialyzer PLT settings: `plt_add_apps: [:mix, :ex_unit]`, flags: `[:unmatched_returns, :error_handling, :no_opaque]`
- Add mix aliases: `setup`, `ecto.setup`, `ecto.reset`, `test`, `assets.setup`, `assets.build`, `assets.deploy`, `lint`, `lint.fix`, `typecheck`

### 1.3 Quality Tooling & Git Hooks (before any domain code)

**This step must be completed before writing any domain code (schemas, contexts, etc.).** All subsequent development happens under the quality gates.

1. Configure `.formatter.exs`, `.credo.exs`, Dialyzer settings (see `05-ci-cd-devops.md`)
2. Write `docker-compose.yml`, `bin/setup`, `bin/server` scripts
3. Write pre-commit and pre-push hook scripts to `priv/git_hooks/`
4. Run `bin/setup` — this installs hooks to `.git/hooks/`, builds PLT, starts services
5. Verify `mix lint`, `mix typecheck`, and `mix test` all run and pass on the bare project

From this point forward, every commit and push is guarded by the hooks. No code reaches the repository without passing formatting, linting, compilation (with `--warnings-as-errors`), type checking, and tests.

### 1.4 Tidewave Setup

- Add `plug Tidewave` in endpoint.ex before the `code_reloading?` block (guarded by `Code.ensure_loaded?(Tidewave)`)
- In `config/dev.exs`, enable `debug_heex_annotations: true` and `debug_attributes: true` for LiveView

### 1.5 Boundary Definitions

Each context module declares its boundary via `use Boundary, deps: [...], exports: [...]`. See `00-overview.md` for the full dependency graph. Boundary violations produce compile warnings, which become build failures with `--warnings-as-errors` in CI.

## Step 2: Database Schema & Migrations

> **Prerequisite migration:** Enable the `citext` extension before creating tables:
> `CREATE EXTENSION IF NOT EXISTS citext;` (required for `users.email` column type).

### 2.1 Users Table

Create table `users` with columns:

| Column | Type | Constraints |
|--------|------|-------------|
| username | string(50) | NOT NULL, unique index |
| display_name | string(100) | |
| email | citext | NOT NULL, unique index |
| hashed_password | string | NOT NULL |
| avatar_url | text | |
| status | string(20) | default: "offline" |
| timestamps | utc_datetime_usec | |

### 2.2 User Tokens Table

Create table `user_tokens` — stores session and API tokens:

| Column | Type | Constraints |
|--------|------|-------------|
| user_id | references(users) | NOT NULL, on_delete: delete_all, indexed |
| token | binary | NOT NULL |
| context | string | NOT NULL — "session", "api_access", "api_refresh" |
| sent_to | string | email for confirmation tokens |
| revoked_at | utc_datetime_usec | nullable — set when token is revoked/rotated (soft-revocation for refresh grace window) |
| inserted_at | utc_datetime_usec | no updated_at |

Unique index on `[:context, :token]`. Add index on `[:context, :revoked_at]` for refresh-token replay checks and cleanup queries.

### 2.3 Channels Table

Create table `channels`:

| Column | Type | Constraints |
|--------|------|-------------|
| name | string(100) | NOT NULL |
| slug | string(100) | NOT NULL, unique index |
| description | text | |
| creator_id | references(users) | on_delete: nilify_all, indexed |
| is_private | boolean | default: false |
| timestamps | utc_datetime_usec | |

### 2.4 Subscriptions Table

Create table `subscriptions` with composite primary key `(user_id, channel_id)`:

| Column | Type | Constraints |
|--------|------|-------------|
| user_id | references(users) | PK, on_delete: delete_all |
| channel_id | references(channels) | PK, on_delete: delete_all, indexed |
| role | string(20) | default: "member" — owner/admin/member/viewer |
| muted | boolean | default: false |
| inserted_at | utc_datetime_usec | no updated_at |

### 2.5 Messages Table

Create table `messages` with Snowflake primary key (not auto-increment). Phase 3 converts this to a time-partitioned table.

| Column | Type | Constraints |
|--------|------|-------------|
| id | bigint | PK, autogenerate: false (Snowflake ID) |
| channel_id | references(channels) | on_delete: delete_all, indexed with id |
| dm_conversation_id | bigint | FK added in DM migration, indexed with id |
| sender_id | references(users) | on_delete: nilify_all, indexed |
| content | text | NOT NULL |
| edited_at | utc_datetime_usec | |
| inserted_at | utc_datetime_usec | no updated_at |

Also create a GIN index for full-text search: `to_tsvector('english', content)`.

Add a database CHECK constraint to enforce the message target invariant at the DB level (not just in changesets, since `BatchWriter` uses `insert_all` which bypasses Ecto changesets):
```sql
ALTER TABLE messages ADD CONSTRAINT messages_target_check
  CHECK (
    (channel_id IS NOT NULL AND dm_conversation_id IS NULL) OR
    (channel_id IS NULL AND dm_conversation_id IS NOT NULL)
  );
```

> **Note on `sender_id`:** This column is intentionally nullable (no NOT NULL constraint) to support
> `on_delete: nilify_all`. When a user account is deleted, their messages are preserved with
> `sender_id` set to NULL. The UI should display these as "[deleted user]".

### 2.6 DM Conversations Table

Create table `dm_conversations`:

| Column | Type | Constraints |
|--------|------|-------------|
| user_a_id | references(users) | NOT NULL, on_delete: delete_all |
| user_b_id | references(users) | NOT NULL, on_delete: delete_all, indexed |
| inserted_at | utc_datetime_usec | no updated_at |

Unique index on `[:user_a_id, :user_b_id]`. Invariant: `user_a_id < user_b_id` to prevent duplicate conversations — enforced at both the changeset level (`normalize_user_order/1`) and the database level:
```sql
ALTER TABLE dm_conversations ADD CONSTRAINT dm_conversations_user_order_check
  CHECK (user_a_id < user_b_id);
```
This DB CHECK constraint prevents bypass paths (raw SQL, `insert_all`, data imports) from creating duplicate logical DM conversations with swapped user IDs.

Also alter `messages` to add FK from `dm_conversation_id` to this table.

### 2.7 Read Cursors Table

Create table `read_cursors` with composite primary key `(user_id, channel_id)`:

| Column | Type | Constraints |
|--------|------|-------------|
| user_id | references(users) | PK, on_delete: delete_all |
| channel_id | references(channels) | PK, on_delete: delete_all |
| last_read_message_id | bigint | NOT NULL |
| timestamps | utc_datetime_usec | |

**DM cursor scope:** This table only tracks channel read cursors. DM read cursors are stored in Redis only (`cursor:{user_id}:dm:{id}` with 24h TTL, see Phase 3 Section 3.1). This is an intentional durability tradeoff — DM unread state is lower priority than channel unread state, and adding a DB-backed DM cursor table can be deferred to a future iteration if needed. If Redis is unavailable or the TTL expires, DM conversations simply show as unread (safe default).

## Step 3: Ecto Schemas

### 3.1 User Schema (`Slackex.Accounts.User`)

Fields match users table. Key behaviors:
- Virtual `:password` field (redacted), hashed into `:hashed_password` on changeset
- `registration_changeset/2` — validates username (3-50 chars, lowercase alphanumeric with `.-_`), email format, password (8-72 chars), unique constraints, then hashes password
- `valid_password?/2` — timing-safe password verification using `Bcrypt.verify_pass/2`; returns `false` with `Bcrypt.no_user_verify()` when user is nil
- Associations: `has_many :subscriptions`, `has_many :channels, through: [:subscriptions, :channel]`

### 3.2 Channel Schema (`Slackex.Chat.Channel`)

Fields match channels table. Key behaviors:
- `changeset/2` — validates name (2-100 chars), auto-generates URL-safe slug from name (lowercase, replace non-alphanumeric with hyphens)
- Associations: `belongs_to :creator (User)`, `has_many :subscriptions`, `has_many :members through: [:subscriptions, :user]`, `has_many :messages`

### 3.3 Message Schema (`Slackex.Chat.Message`)

Uses `@primary_key {:id, :integer, autogenerate: false}` for Snowflake IDs. Key behaviors:
- `changeset/2` — validates content (1-4000 chars), requires id + content + sender_id. The `inserted_at` field is **derived from the Snowflake ID** via `Snowflake.extract_timestamp/1` (not generated by Ecto timestamps). This ensures `inserted_at` is deterministic and immutable for a given message ID, which is critical for partition stability in Phase 3.
- `validate_target/1` — must have `channel_id` OR `dm_conversation_id`, not both and not neither. Also enforced by a DB CHECK constraint (see migration).
- Associations: `belongs_to :channel`, `belongs_to :dm_conversation`, `belongs_to :sender (User)`

### 3.4 Subscription Schema (`Slackex.Chat.Subscription`)

Composite PK (`@primary_key false`). Validates role inclusion in `["owner", "admin", "member", "viewer"]`.

### 3.5 DMConversation Schema (`Slackex.Chat.DMConversation`)

Key behavior: `normalize_user_order/1` in changeset swaps user_a/user_b so `user_a_id < user_b_id`, preventing duplicate conversations.

### 3.6 ReadCursor Schema (`Slackex.Chat.ReadCursor`)

Composite PK (`@primary_key false`). Tracks `last_read_message_id` per user per channel.

## Step 4: Snowflake ID Generator

`Slackex.Infrastructure.Snowflake` — GenServer that generates 64-bit Snowflake IDs.

**Bit layout:**
```
[1 bit unused][41 bits timestamp][10 bits node_id][12 bits sequence]
```

- **Epoch:** 2025-01-01T00:00:00Z (ms)
- **Node ID:** 10-bit identifier (0-1023), assigned deterministically — not derived from node-name hash (which is collision-prone at 10 bits). In production (K8s), use the StatefulSet pod ordinal via `SNOWFLAKE_NODE_ID` env var. In dev, derive from the port number via `rem(port - 4000, 1024)` — this maps port 4000→0, 4001→1, 4002→2 (the typical local multi-node range). `rem/2` wraps values into the valid 10-bit range (0-1023) via modular arithmetic, not clamping. On startup, the Snowflake GenServer verifies uniqueness by attempting a PostgreSQL advisory lock on `node_id` — if the lock fails, another node holds the same ID and startup is aborted with a clear error.
- **Sequence:** 4096 IDs per millisecond per node
- **Clock drift:** if clock goes backwards, waits until it advances past `last_timestamp`

**Public API:**
- `start_link(opts)` — starts the GenServer, `node_id` from `SNOWFLAKE_NODE_ID` env var (required in prod) or derived from port number in dev. Acquires a PostgreSQL advisory lock on the node_id to prevent collisions.
- `generate() :: integer()` — returns a unique, monotonically increasing 64-bit ID
- `extract_timestamp(id) :: integer()` — extracts the creation timestamp (ms since Unix epoch) from an ID

## Step 4.5: Rate Limiter

`Slackex.Infrastructure.RateLimiter` — pure functional token bucket. No GenServer — the caller owns the state.

**State:** `%RateLimiter{rate, per_ms, tokens, last_refill}`

**Public API:**
- `new(rate: integer, per: :second | :minute | :hour) :: t()` — creates a new limiter
- `check(t()) :: {:ok, t()} | {:error, :rate_limited}` — consumes a token, refilling based on elapsed time

## Step 4.6: Guardian & Auth Module

### Guardian Configuration

`Slackex.Accounts.Guardian` — implements `Guardian` behaviour. `subject_for_token/2` returns user ID as string. `resource_from_claims/1` loads user by ID from claims `"sub"` field.

Config: `issuer: "slackex"`, secret key from `GUARDIAN_SECRET_KEY` env var in production.

### Auth Module (`Slackex.Accounts.Auth`)

Public API:
- `generate_api_token(user) :: String.t()` — JWT access token, TTL 15 minutes
- `generate_refresh_token(user) :: String.t()` — JWT refresh token with `"typ" => "refresh"`, TTL 30 days
- `verify_api_token(token) :: {:ok, user_id} | {:error, reason}` — decodes and verifies JWT
- `refresh_api_token(refresh_token) :: {:ok, %{access_token, refresh_token}} | {:error, reason}` — exchanges refresh token for a new access token **and a new refresh token** (rotation). The old refresh token's JTI is revoked immediately. If a revoked refresh token is ever presented, all tokens for that user are revoked (token family invalidation — indicates potential token theft). **Grace window for client retries:** To prevent accidental global logout from legitimate client retries/races after rotation, the old refresh token's JTI is not hard-deleted but instead marked with a `revoked_at` timestamp. Presentations of a revoked JTI within a **10-second grace window** from `revoked_at` return the same new token pair (idempotent response, no family invalidation). Only presentations **after** the grace window trigger family invalidation. This absorbs retry storms from mobile clients on flaky networks without weakening the replay-detection guarantee.
- `revoke_token(token) :: :ok` — revokes a token (e.g., on logout)

**Token revocation strategy:**
- Each JWT includes a unique `"jti"` (JWT ID) claim, generated as a random UUID at token creation time
- `generate_api_token/1` and `generate_refresh_token/1` persist the JTI to the `user_tokens` table (context: `"api_access"` / `"api_refresh"`). The JTI is stored in the existing `token` column as a hashed binary (`:crypto.hash(:sha256, jti_string)`) — this matches the `phx.gen.auth` pattern of hashing tokens before DB storage. The unique index on `[:context, :token]` ensures efficient lookup.
- `verify_api_token/1` decodes the JWT, extracts the JTI, and confirms it exists in `user_tokens`. If the JTI row has been deleted, the token is considered revoked and verification fails with `{:error, :token_revoked}`
- `revoke_token/1` sets `revoked_at` for refresh tokens (soft revoke), preserving replay-detection metadata. For access/session tokens, hard delete is allowed.
- `refresh_api_token/1` idempotency storage: the newly issued token pair from the first successful rotation is cached for 10 seconds in Redis (`refresh_replay:{old_refresh_jti_hash}`) so a retried request can return the same pair. The DB remains the source of truth for revocation (`revoked_at`), while Redis provides short-lived replay response caching.
- On user password change or explicit "revoke all sessions", delete all `user_tokens` rows for that user — this invalidates all outstanding JWTs
- Access tokens (15min TTL) are short-lived, so the revocation check adds minimal overhead. Refresh tokens (30 days) must always be checked against the DB

### Guardian Pipeline for API Routes

`SlackexWeb.Plugs.ApiAuthPipeline` — plug pipeline that verifies Bearer token, ensures authenticated, loads resource. Error handler returns JSON `%{error: type}` with 401 status.

## Step 5: Context Modules (Public APIs)

### 5.1 Accounts Context (`Slackex.Accounts`)

Boundary: `deps: [Slackex.Repo], exports: [User, UserToken, Auth]`

Public API:
- `register_user(attrs) :: {:ok, User.t()} | {:error, Changeset.t()}`
- `get_user_by_email_and_password(email, password) :: User.t() | nil`
- `get_user!(id) :: User.t()`
- `generate_user_session_token(user) :: binary()` — builds and persists a session token
- `get_user_by_session_token(token) :: User.t() | nil`
- `delete_user_session_token(token) :: :ok`

### 5.2 Chat Context (`Slackex.Chat`)

Boundary: `deps: [Slackex.Accounts, Slackex.Infrastructure, Slackex.Repo], exports: [Channel, Message, Subscription, DMConversation, ReadCursor, Permissions]`

**Channel operations:**
- `create_channel(user_id, attrs) :: {:ok, Channel.t()} | {:error, Changeset.t()}` — uses `Ecto.Multi` to insert channel + owner subscription atomically
- `list_public_channels() :: [Channel.t()]`
- `list_user_channels(user_id) :: [Channel.t()]`
- `get_channel!(id)`, `get_channel_by_slug!(slug)`
- `join_channel(user_id, channel_id) :: {:ok, Subscription.t()} | {:error, :unauthorized}` — rejects private channels, uses `on_conflict: :nothing` for idempotency
- `leave_channel(user_id, channel_id) :: :ok`
- `get_role(user_id, channel_id) :: String.t() | nil`

**Message operations (Phase 1 — direct persistence, replaced by ChannelServer in Phase 2):**
- `send_message(channel_id, sender_id, content)` — checks role (owner/admin/member), generates Snowflake ID, sanitizes HTML via `HtmlSanitizeEx.strip_tags/1`, inserts to DB, preloads sender, broadcasts via PubSub to `"channel:#{channel_id}"`
- `list_messages(channel_id, opts)` — paginated by Snowflake ID, supports `limit` and `before` options, preloads sender. **Partition-aware (Phase 3+):** When a `before` cursor is provided, derives `inserted_at` bounds from the Snowflake timestamp to enable partition pruning (see HistoryLoader).

**DM operations:**
- `find_or_create_dm(user_a_id, user_b_id)` — normalizes user order, finds existing or creates new
- `send_dm(dm_id, sender_id, content)` — similar to `send_message`, broadcasts to `"dm:#{dm_id}"`
- `list_dms(user_id) :: [DMConversation.t()]`

**Read cursor operations:**
- `mark_as_read(user_id, channel_id)` — upserts read cursor to latest message ID using `on_conflict: {:replace, [...]}`
- `unread_count(user_id, channel_id) :: integer()` — counts messages after last read cursor

## Step 6: Permissions Module

`Slackex.Chat.Permissions` — role-based authorization using a hierarchy map:

| Role | Level | send_message | read_messages | manage_channel | delete_channel |
|------|-------|:---:|:---:|:---:|:---:|
| owner | 4 | yes | yes | yes | yes |
| admin | 3 | yes | yes | yes | no |
| member | 2 | yes | yes | no | no |
| viewer | 1 | no | yes | no | no |
| nil | 0 | no | no | no | no |

> **Note on public channel read access:** The `nil` role (non-member) having no `read_messages`
> permission applies to **direct message access** (loading channel history, joining channels).
> For **search**, any authenticated user can find results from public channels they haven't
> joined — this is intentional and consistent with Slack's behavior where public channel content
> is discoverable. Private channels are only searchable by their members. The permissions table
> governs direct channel interactions; search authorization is a separate policy layer documented
> in Phase 4 (`Search.MessageSearch`).

## Step 7: LiveView Chat Interface

### 7.1 Router

Route structure:
- **Authenticated live_session** (`:ensure_authenticated` on_mount): `/chat` (index), `/chat/:slug` (channel view)
- **Public routes:** `/` (landing page)
- **Auth live_session** (`:redirect_if_authenticated`): `/users/register`, `/users/log-in`
- **Auth actions:** `DELETE /users/log-out`
- **Mobile/API routes:** `POST /api/auth/login`, `POST /api/auth/refresh`, `GET /api/bootstrap`

Security: Phoenix's `:put_secure_browser_headers` provides default headers. For production, add explicit CSP in endpoint.ex and CORS for mobile API if needed.

### 7.2 Main Chat LiveView (`SlackexWeb.ChatLive.Index`)

**Responsibilities:**
- On mount: load user's channels and DMs, subscribe to `"user:#{user.id}"` for notifications
- On `handle_params(%{"slug" => slug})`: activate channel — unsubscribe from previous, subscribe to new, load messages, mark as read
- Stream-based message list (`:messages` stream)

**Events handled:**
- `"send_message"` — calls `Chat.send_message/3`, flash on error
- `"select_channel"` — `push_patch` to `/chat/:slug`
- `"load_more"` — placeholder for scroll-up pagination (enhanced in Phase 2)

**PubSub handlers:**
- `{:new_message, message}` — stream insert + auto-mark-as-read if viewing that channel
- `{:user_typing, user}` — add to typing set, auto-clear after 3 seconds

### 7.3 WebSocket for Mobile Clients

**UserSocket (`SlackexWeb.UserSocket`):**
- Channels: `"chat:*"` → ChatChannel, `"dm:*"` → DMChannel
- `connect/3` — verifies JWT via `Auth.verify_api_token/1`, assigns `current_user_id`
- `id/1` — returns `"user_socket:#{user_id}"`

**ChatChannel (`SlackexWeb.ChatChannel`):**
- `join("chat:" <> channel_id)` — checks user role, returns recent messages, marks as read
- `handle_in("new_message", %{"content" => content})` — sends message via `Chat.send_message/3`, broadcasts `"new_message"` event with message payload (id, content, sender info, timestamp)

### 7.4 Frontend Portability Baseline (LiveView-first)

To keep a future SPA migration (e.g., SolidJS/Vite/Bun) low-risk without changing the current LiveView-first plan:

- **Adapter boundary rule:** LiveView and Channel modules orchestrate only. They call context/messaging APIs and must not contain domain business rules or direct `Repo` queries.
- **Shared serialization rule:** Message/channel/user payloads are produced through shared serializer modules (e.g., `SlackexWeb.MessageJSON`) reused by both Phoenix Channels and JSON API responses, preventing divergent payload shapes.
- **Bootstrap API baseline:** Add `GET /api/bootstrap` (JWT-authenticated) returning the minimum app shell data for non-LiveView clients: current user, channels, DM list, and unread counts. LiveView remains the primary web UI; this endpoint exists for contract stability and future incremental client migration.

## Step 8: Application Supervisor (Phase 1)

Children (in start order):
1. `Slackex.Repo` — database
2. `{Phoenix.PubSub, name: Slackex.PubSub}` — distributed pub/sub
3. `Slackex.Infrastructure.Snowflake` — ID generator
4. `SlackexWeb.Endpoint` — web endpoint (must be last)

## Step 9: Docker Compose for Local Development

See `05-ci-cd-devops.md` for the full Docker Compose configuration. Phase 1 requires:
- PostgreSQL 16+ with pgvector (`pgvector/pgvector:pg16` image)
- Redis 7+ (`redis:7-alpine` image)

## Phase 1 Acceptance Criteria

### Backend Foundation (Steps 1-6) — COMPLETE

- [x] `mix compile --warnings-as-errors` passes
- [x] `mix credo --strict` passes (zero issues)
- [x] `mix format --check-formatted` passes
- [x] All 8 migrations run cleanly (citext, users, user_tokens, channels, subscriptions, messages, dm_conversations, read_cursors)
- [x] User registration with password hashing and validation
- [x] User can create a public channel (context API + atomic owner subscription)
- [x] User can join/leave public channels (idempotent, rejects private)
- [x] User can send messages in a channel they've joined (permission-checked)
- [x] Messages are persisted to PostgreSQL with Snowflake IDs
- [x] Message `inserted_at` is derived from Snowflake ID timestamp (microsecond precision)
- [x] Guardian is configured with JWT access tokens (15min) and refresh tokens (30 days)
- [x] Refresh token rotation with grace window and family invalidation
- [x] Unread counts are tracked via read cursors (upsert with `on_conflict`)
- [x] DM conversations work between two users (user ordering invariant enforced)
- [x] Snowflake ID generator with advisory lock, clock drift handling, sequence overflow
- [x] Rate limiter (pure functional token bucket)
- [x] Role-based permissions (owner/admin/member/viewer hierarchy)
- [x] PubSub broadcasting on message send (channel + DM)
- [x] `docker-compose up` starts Postgres (with pgvector) and Redis
- [x] 66 behavioral and unit tests pass

### LiveView & WebSocket (Steps 7-8) — COMPLETE

- [x] User can register, log in, log out via LiveView
- [x] User can send messages via LiveView with real-time updates
- [x] Messages appear in real-time for all subscribed users via PubSub
- [x] Mobile client can authenticate via JWT and join channels via WebSocket
- [x] Mobile client can send/receive messages via Phoenix Channel protocol
- [x] LiveView and Channel modules follow adapter boundary rule (no domain logic or direct `Repo` reads/writes outside contexts)
- [x] Shared serializers are used for Channel and API payloads (single source of truth for payload shape)
- [x] `GET /api/bootstrap` provides JWT-authenticated bootstrap payload for non-LiveView clients

### Tooling & DevEx — PARTIAL

- [x] Docker Compose with pgvector Postgres and Redis
- [x] Mix aliases for lint, typecheck, quality, ci
- [ ] Boundary compile-time checks (deferred — `boundary` dep not yet added)
- [x] Tidewave MCP server is accessible in dev for AI-assisted development
- [ ] `mix setup` bootstraps the entire project from scratch
- [x] Pre-commit git hook installed (format, compile, credo, assets.build, test)
