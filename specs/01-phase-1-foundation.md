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

### 1.3 Tidewave Setup

- Add `plug Tidewave` in endpoint.ex before the `code_reloading?` block (guarded by `Code.ensure_loaded?(Tidewave)`)
- In `config/dev.exs`, enable `debug_heex_annotations: true` and `debug_attributes: true` for LiveView

### 1.4 Boundary Definitions

Each context module declares its boundary via `use Boundary, deps: [...], exports: [...]`. See `00-overview.md` for the full dependency graph. Boundary violations produce compile warnings, which become build failures with `--warnings-as-errors` in CI.

## Step 2: Database Schema & Migrations

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
| inserted_at | utc_datetime_usec | no updated_at |

Unique index on `[:context, :token]`.

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
| sender_id | references(users) | NOT NULL, on_delete: nilify_all, indexed |
| content | text | NOT NULL |
| edited_at | utc_datetime_usec | |
| inserted_at | utc_datetime_usec | no updated_at |

Also create a GIN index for full-text search: `to_tsvector('english', content)`.

### 2.6 DM Conversations Table

Create table `dm_conversations`:

| Column | Type | Constraints |
|--------|------|-------------|
| user_a_id | references(users) | NOT NULL, on_delete: delete_all |
| user_b_id | references(users) | NOT NULL, on_delete: delete_all, indexed |
| inserted_at | utc_datetime_usec | no updated_at |

Unique index on `[:user_a_id, :user_b_id]`. Invariant: `user_a_id < user_b_id` to prevent duplicate conversations. Also alter `messages` to add FK from `dm_conversation_id` to this table.

### 2.7 Read Cursors Table

Create table `read_cursors` with composite primary key `(user_id, channel_id)`:

| Column | Type | Constraints |
|--------|------|-------------|
| user_id | references(users) | PK, on_delete: delete_all |
| channel_id | references(channels) | PK, on_delete: delete_all |
| last_read_message_id | bigint | NOT NULL |
| timestamps | utc_datetime_usec | |

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
- `changeset/2` — validates content (1-4000 chars), requires id + content + sender_id
- `validate_target/1` — must have `channel_id` OR `dm_conversation_id`, not both and not neither
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
- **Node ID:** derived from `node()` name hash, supports 1024 nodes
- **Sequence:** 4096 IDs per millisecond per node
- **Clock drift:** if clock goes backwards, waits until it advances past `last_timestamp`

**Public API:**
- `start_link(opts)` — starts the GenServer, `node_id` derived from `node()` by default
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
- `refresh_api_token(refresh_token) :: {:ok, new_token} | {:error, reason}` — exchanges refresh for new access token
- `revoke_token(token) :: :ok` — revokes a token (e.g., on logout)

### Guardian Pipeline for API Routes

`SlackexWeb.Plugs.ApiAuthPipeline` — plug pipeline that verifies Bearer token, ensures authenticated, loads resource. Error handler returns JSON `%{error: type}` with 401 status.

## Step 5: Context Modules (Public APIs)

### 5.1 Accounts Context (`Slackex.Accounts`)

Boundary: `deps: [], exports: [User, UserToken, Auth]`

Public API:
- `register_user(attrs) :: {:ok, User.t()} | {:error, Changeset.t()}`
- `get_user_by_email_and_password(email, password) :: User.t() | nil`
- `get_user!(id) :: User.t()`
- `generate_user_session_token(user) :: binary()` — builds and persists a session token
- `get_user_by_session_token(token) :: User.t() | nil`
- `delete_user_session_token(token) :: :ok`

### 5.2 Chat Context (`Slackex.Chat`)

Boundary: `deps: [Slackex.Accounts, Slackex.Infrastructure], exports: [Channel, Message, Subscription, DMConversation, ReadCursor, Permissions]`

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
- `list_messages(channel_id, opts)` — paginated by Snowflake ID, supports `limit` and `before` options, preloads sender

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

## Step 7: LiveView Chat Interface

### 7.1 Router

Route structure:
- **Authenticated live_session** (`:ensure_authenticated` on_mount): `/chat` (index), `/chat/:slug` (channel view)
- **Public routes:** `/` (landing page)
- **Auth live_session** (`:redirect_if_authenticated`): `/users/register`, `/users/log-in`
- **Auth actions:** `DELETE /users/log-out`
- **Mobile API:** `POST /api/auth/login`, `POST /api/auth/refresh`

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

- [ ] `mix compile --warnings-as-errors` passes (including boundary checks)
- [ ] `mix credo --strict` passes
- [ ] `mix format --check-formatted` passes
- [ ] User can register, log in, log out via LiveView
- [ ] User can create a public channel
- [ ] User can join/leave public channels
- [ ] User can send messages in a channel they've joined
- [ ] Messages appear in real-time for all subscribed users via PubSub
- [ ] Messages are persisted to PostgreSQL with Snowflake IDs
- [ ] Guardian is configured with JWT access tokens (15min) and refresh tokens (30 days)
- [ ] Mobile client can authenticate via JWT and join channels via WebSocket
- [ ] Mobile client can send/receive messages via Phoenix Channel protocol
- [ ] Unread counts are tracked via read cursors
- [ ] DM conversations work between two users
- [ ] Tidewave MCP server is accessible in dev for AI-assisted development
- [ ] `docker-compose up` starts Postgres (with pgvector) and Redis
- [ ] `mix setup` bootstraps the entire project from scratch
- [ ] All behavioral tests pass
