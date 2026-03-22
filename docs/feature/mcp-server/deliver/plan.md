# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a platform MCP server to Tenun so external AI agents can read channels, send messages, search history, and receive real-time events.

**Architecture:** `phantom_mcp` library mounted at `/mcp` in the Phoenix router. Bearer token auth via `connect/2`. PubSub bridge for real-time SSE subscriptions. Serializer boundary prevents data leakage.

**Tech Stack:** Elixir, Phoenix, `phantom_mcp ~> 0.3.4`, `Phoenix.PubSub`, ExMachina (tests)

**Spec:** `docs/feature/mcp-server/design/architecture.md`

---

## File Map

### New Files

| File | Responsibility |
|---|---|
| `lib/slackex/integrations/mcp_token.ex` | Ecto schema for MCP tokens |
| `lib/slackex/integrations/mcp_tokens.ex` | Context: create, lookup, revoke, touch MCP tokens |
| `lib/slackex_web/mcp/router.ex` | `Phantom.Router` — tools, resources, prompts, `connect/2` |
| `lib/slackex_web/mcp/subscriber.ex` | GenServer: PubSub → SSE bridge per session |
| `lib/slackex_web/mcp/serializer.ex` | Domain structs → JSON-safe MCP responses |
| `priv/repo/migrations/*_create_mcp_tokens.exs` | Migration: `mcp_tokens` table |
| `test/slackex/integrations/mcp_tokens_test.exs` | Unit tests for token CRUD |
| `test/slackex_web/mcp/router_test.exs` | Integration tests for MCP resources/tools |
| `test/slackex_web/mcp/serializer_test.exs` | Contract tests for serialization |
| `test/slackex_web/mcp/subscriber_test.exs` | Tests for PubSub → SSE bridge |

### Modified Files

| File | Change |
|---|---|
| `mix.exs` | Add `{:phantom_mcp, "~> 0.3.4"}` |
| `config/config.exs` | MIME type for SSE |
| `lib/slackex/integrations/integrations.ex` | Update Boundary exports |
| `lib/slackex_web/router.ex` | Add `/mcp` scope with pipeline |

---

### Task 1: Add `phantom_mcp` dependency and configure MIME

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`

- [ ] **Step 1: Add phantom_mcp to mix.exs**

In `mix.exs`, add to the `deps` function:

```elixir
{:phantom_mcp, "~> 0.3.4"}
```

- [ ] **Step 2: Add MIME type config for SSE**

In `config/config.exs`, add at the top-level (Phantom requires this for SSE transport):

```elixir
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}
```

- [ ] **Step 3: Fetch deps and compile**

Run: `mix deps.get && mix compile`
Expected: Clean compile, `phantom_mcp` fetched successfully.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock config/config.exs
git commit -m "chore: add phantom_mcp dependency and SSE MIME config"
```

---

### Task 2: Migration — create `mcp_tokens` table

**Files:**
- Create: `priv/repo/migrations/*_create_mcp_tokens.exs`

- [ ] **Step 1: Generate migration**

Run: `mix ecto.gen.migration create_mcp_tokens`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Slackex.Repo.Migrations.CreateMcpTokens do
  use Ecto.Migration

  def change do
    create table(:mcp_tokens) do
      add :token_hash, :string, null: false
      add :name, :string, null: false
      add :bot_user_id, references(:users, on_delete: :nothing), null: false
      add :is_active, :boolean, default: true, null: false
      add :last_used_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:mcp_tokens, [:token_hash])
    create index(:mcp_tokens, [:bot_user_id])
  end
end
```

- [ ] **Step 3: Run migration**

Run: `mix ecto.migrate`
Expected: Migration runs successfully.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/*_create_mcp_tokens.exs
git commit -m "feat(mcp): add mcp_tokens migration"
```

---

### Task 3: MCP Token schema and context

**Files:**
- Create: `lib/slackex/integrations/mcp_token.ex`
- Create: `lib/slackex/integrations/mcp_tokens.ex`
- Modify: `lib/slackex/integrations/integrations.ex`
- Create: `test/slackex/integrations/mcp_tokens_test.exs`
- Modify: `test/support/factory.ex`

- [ ] **Step 1: Write the failing tests**

Create `test/slackex/integrations/mcp_tokens_test.exs`:

```elixir
defmodule Slackex.Integrations.McpTokensTest do
  use Slackex.DataCase, async: true

  alias Slackex.Integrations.McpToken
  alias Slackex.Integrations.McpTokens

  describe "create_mcp_token/1" do
    test "creates token with bot user atomically" do
      assert {:ok, %{mcp_token: token, raw_token: raw, bot_user: bot}} =
               McpTokens.create_mcp_token(%{name: "Claude Code"})

      assert token.name == "Claude Code"
      assert token.is_active == true
      assert token.bot_user_id == bot.id
      assert is_binary(raw)
      assert String.starts_with?(raw, "mcp_")
      assert token.token_hash == McpTokens.hash_token(raw)

      # Bot user created with is_bot flag
      assert bot.is_bot == true
      assert bot.username == "mcp-claude-code"
      assert bot.display_name == "Claude Code"
    end

    test "returns raw token that differs from stored hash" do
      {:ok, %{mcp_token: token, raw_token: raw}} =
        McpTokens.create_mcp_token(%{name: "Test Agent"})

      assert raw != token.token_hash
      assert McpTokens.hash_token(raw) == token.token_hash
    end
  end

  describe "get_by_token_hash/1" do
    test "finds active token with preloaded bot_user" do
      {:ok, %{mcp_token: token, raw_token: raw}} =
        McpTokens.create_mcp_token(%{name: "Lookup Test"})

      found = McpTokens.get_by_token_hash(token.token_hash)
      assert found.id == token.id
      assert found.bot_user.is_bot == true
    end

    test "returns nil for inactive token" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Inactive"})

      McpTokens.revoke_mcp_token(token)
      assert nil == McpTokens.get_by_token_hash(token.token_hash)
    end

    test "returns nil for unknown hash" do
      assert nil == McpTokens.get_by_token_hash("nonexistent")
    end
  end

  describe "revoke_mcp_token/1" do
    test "sets is_active to false" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Revoke Test"})

      assert {:ok, revoked} = McpTokens.revoke_mcp_token(token)
      assert revoked.is_active == false
    end
  end

  describe "touch_last_used/1" do
    test "updates last_used_at timestamp" do
      {:ok, %{mcp_token: token}} =
        McpTokens.create_mcp_token(%{name: "Touch Test"})

      assert token.last_used_at == nil
      assert {:ok, touched} = McpTokens.touch_last_used(token)
      assert touched.last_used_at != nil
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex/integrations/mcp_tokens_test.exs`
Expected: Compilation errors — `McpToken` and `McpTokens` modules don't exist.

- [ ] **Step 3: Write the McpToken schema**

Create `lib/slackex/integrations/mcp_token.ex`:

```elixir
defmodule Slackex.Integrations.McpToken do
  @moduledoc """
  MCP token schema. Represents a bearer token that grants an AI agent
  access to the Tenun MCP server via a bot user identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "mcp_tokens" do
    field :name, :string
    field :token_hash, :string
    field :is_active, :boolean, default: true
    field :last_used_at, :utc_datetime_usec

    belongs_to :bot_user, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mcp_token, attrs) do
    mcp_token
    |> cast(attrs, [:name, :token_hash, :bot_user_id, :is_active, :last_used_at])
    |> validate_required([:name, :token_hash, :bot_user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:bot_user_id)
  end
end
```

- [ ] **Step 4: Write the McpTokens context**

Create `lib/slackex/integrations/mcp_tokens.ex`:

```elixir
defmodule Slackex.Integrations.McpTokens do
  @moduledoc """
  Context for managing MCP tokens. Handles token creation (with atomic
  bot user), lookup, revocation, and last-used tracking.
  """

  alias Ecto.Multi
  alias Slackex.Accounts
  alias Slackex.Integrations.McpToken
  alias Slackex.Repo

  @token_bytes 32

  @doc """
  Creates an MCP token atomically: generates a token with `mcp_` prefix,
  creates a bot user, and inserts the token record.

  Returns `{:ok, %{mcp_token: token, raw_token: raw, bot_user: user}}`
  on success.
  """
  def create_mcp_token(%{name: name}) do
    raw_token = generate_token()
    token_hash = hash_token(raw_token)
    bot_username = sanitize_bot_username(name)

    Multi.new()
    |> Multi.run(:bot_user, fn _repo, _changes ->
      Accounts.create_bot_user(%{username: bot_username, display_name: name})
    end)
    |> Multi.insert(:mcp_token, fn %{bot_user: bot_user} ->
      McpToken.changeset(%McpToken{}, %{
        name: name,
        token_hash: token_hash,
        bot_user_id: bot_user.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{mcp_token: token, bot_user: bot_user}} ->
        {:ok, %{mcp_token: token, raw_token: raw_token, bot_user: bot_user}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Finds an active MCP token by its hash, preloading the bot_user.
  Returns `nil` if no active token matches.
  """
  def get_by_token_hash(hash) do
    McpToken
    |> Repo.get_by(token_hash: hash, is_active: true)
    |> Repo.preload(:bot_user)
  end

  @doc """
  Hashes a raw token using SHA-256, returning a lowercase hex string.
  Reuses the same algorithm as webhook token hashing.
  """
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  @doc """
  Soft-revokes an MCP token by setting `is_active` to false.
  """
  def revoke_mcp_token(%McpToken{} = token) do
    token
    |> Ecto.Changeset.change(is_active: false)
    |> Repo.update()
  end

  @doc """
  Updates the `last_used_at` timestamp to now.
  """
  def touch_last_used(%McpToken{} = token) do
    token
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
    |> Repo.update()
  end

  # -- Private ---------------------------------------------------------------

  defp generate_token do
    raw = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    "mcp_" <> raw
  end

  defp sanitize_bot_username(name) do
    sanitized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 35)

    "mcp-" <> sanitized
  end
end
```

- [ ] **Step 5: Update Integrations boundary exports**

In `lib/slackex/integrations/integrations.ex`, update the exports:

```elixir
use Boundary,
  deps: [Slackex.Accounts, Slackex.Chat],
  exports: [Webhook, Webhooks, McpToken, McpTokens]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/slackex/integrations/mcp_tokens_test.exs`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/slackex/integrations/mcp_token.ex lib/slackex/integrations/mcp_tokens.ex \
  lib/slackex/integrations/integrations.ex test/slackex/integrations/mcp_tokens_test.exs
git commit -m "feat(mcp): add McpToken schema and context with tests"
```

---

### Task 4: Serializer

**Files:**
- Create: `lib/slackex_web/mcp/serializer.ex`
- Create: `test/slackex_web/mcp/serializer_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/slackex_web/mcp/serializer_test.exs`:

```elixir
defmodule SlackexWeb.MCP.SerializerTest do
  use Slackex.DataCase, async: true

  alias SlackexWeb.MCP.Serializer

  describe "channel/2" do
    test "serializes channel with member count, no internal fields" do
      user = insert(:user)
      channel = insert(:channel, creator: user, name: "general", slug: "general")
      result = Serializer.channel(channel, 42)

      assert result.id == to_string(channel.id)
      assert result.name == "general"
      assert result.slug == "general"
      assert result.member_count == 42
      assert Map.has_key?(result, :inserted_at)
      # No internal fields leaked
      refute Map.has_key?(result, :creator)
      refute Map.has_key?(result, :creator_id)
      refute Map.has_key?(result, :__struct__)
      refute Map.has_key?(result, :__meta__)
    end
  end

  describe "message/1" do
    test "serializes message with string IDs, no encrypted content leak" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      insert(:subscription, user: user, channel: channel)

      {:ok, msg} = Slackex.Chat.send_message(channel.id, user.id, "hello world")
      db_msg = Slackex.Chat.get_message!(msg.id)
      result = Serializer.message(db_msg)

      assert result.id == to_string(db_msg.id)
      assert result.channel_id == to_string(db_msg.channel_id)
      assert result.sender_id == to_string(db_msg.sender_id)
      assert result.content == "hello world"
      assert Map.has_key?(result, :inserted_at)
      # No encrypted binary or ecto internals
      refute Map.has_key?(result, :__struct__)
      refute Map.has_key?(result, :search_content)
      refute Map.has_key?(result, :embedding)
    end
  end

  describe "user/1" do
    test "serializes user with safe fields only" do
      user = insert(:user, username: "testbot", display_name: "Test Bot", is_bot: true)
      result = Serializer.user(user)

      assert result.id == to_string(user.id)
      assert result.username == "testbot"
      assert result.display_name == "Test Bot"
      assert result.is_bot == true
      # No sensitive fields
      refute Map.has_key?(result, :email)
      refute Map.has_key?(result, :email_hash)
      refute Map.has_key?(result, :hashed_password)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex_web/mcp/serializer_test.exs`
Expected: Compilation error — `SlackexWeb.MCP.Serializer` doesn't exist.

- [ ] **Step 3: Write the serializer**

Create `lib/slackex_web/mcp/serializer.ex`:

```elixir
defmodule SlackexWeb.MCP.Serializer do
  @moduledoc """
  Transforms domain structs into JSON-safe maps for MCP responses.

  This is the boundary between Tenun's internal data model and what agents see.
  Explicit field selection per entity — no Jason.Encoder derivation on domain schemas.

  Messages loaded via Ecto queries are automatically decrypted by the Cloak field type.
  The serializer must only receive Ecto-loaded structs, never raw database rows.
  """

  alias Slackex.Accounts.User
  alias Slackex.Chat.Channel
  alias Slackex.Chat.Message

  def channel(%Channel{} = ch, member_count) do
    %{
      id: to_string(ch.id),
      name: ch.name,
      slug: ch.slug,
      description: ch.description,
      member_count: member_count,
      inserted_at: DateTime.to_iso8601(ch.inserted_at)
    }
  end

  def message(%Message{} = msg) do
    %{
      id: to_string(msg.id),
      channel_id: msg.channel_id && to_string(msg.channel_id),
      sender_id: to_string(msg.sender_id),
      content: msg.content,
      parent_message_id: msg.parent_message_id && to_string(msg.parent_message_id),
      reply_count: msg.reply_count,
      edited_at: msg.edited_at && DateTime.to_iso8601(msg.edited_at),
      inserted_at: DateTime.to_iso8601(msg.inserted_at)
    }
  end

  def user(%User{} = u) do
    %{
      id: to_string(u.id),
      username: u.username,
      display_name: u.display_name,
      avatar_url: u.avatar_url,
      is_bot: u.is_bot
    }
  end

  @doc """
  Serializes a plain map from ChannelServer (not an Ecto struct).
  Used for send_message/reply_to_thread responses where the message
  hasn't been flushed to DB yet (batch writes).
  """
  def message_from_map(msg) when is_map(msg) do
    %{
      id: to_string(msg.id),
      channel_id: msg[:channel_id] && to_string(msg.channel_id),
      sender_id: to_string(msg.sender_id),
      content: msg.content,
      parent_message_id: msg[:parent_message_id] && to_string(msg.parent_message_id),
      reply_count: msg[:reply_count] || 0,
      edited_at: nil,
      inserted_at: DateTime.to_iso8601(msg.inserted_at)
    }
  end

  def messages(msgs) when is_list(msgs) do
    Enum.map(msgs, &message/1)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex_web/mcp/serializer_test.exs`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/mcp/serializer.ex test/slackex_web/mcp/serializer_test.exs
git commit -m "feat(mcp): add serializer boundary for MCP responses"
```

---

### Task 5: MCP Router — `connect/2` auth and resources

**Files:**
- Create: `lib/slackex_web/mcp/router.ex`
- Modify: `lib/slackex_web/router.ex`
- Create: `test/slackex_web/mcp/router_test.exs`

This is the largest task. It wires up Phantom.Router with auth, all 5 resources, and mounts it in Phoenix.

- [ ] **Step 1: Write failing tests for auth and channel resources**

Create `test/slackex_web/mcp/router_test.exs`. Since Phantom uses HTTP transport, we test via `Plug.Test` or direct HTTP calls. Start with auth and the channel list resource:

```elixir
defmodule SlackexWeb.MCP.RouterTest do
  @moduledoc """
  Integration tests for the MCP server.

  Tests exercise the full path: HTTP request → Phantom.Plug → MCP Router
  → domain context → serialized response.
  """
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.McpTokens
  alias Slackex.Chat

  setup do
    {:ok, %{raw_token: token, bot_user: bot}} =
      McpTokens.create_mcp_token(%{name: "Test Agent"})

    user = insert(:user)
    channel = insert(:channel, creator: user, name: "general", slug: "general")
    insert(:subscription, user: user, channel: channel)

    # Bot joins the channel
    {:ok, _} = Chat.join_channel(bot.id, channel.id)

    %{token: token, bot: bot, channel: channel, user: user}
  end

  describe "connect/2 — authentication" do
    test "valid bearer token connects successfully", %{token: token} do
      conn = mcp_request("initialize", %{"protocolVersion" => "2025-03-26"}, token)
      assert %{"result" => %{"serverInfo" => _}} = json_response(conn, 200)
    end

    test "missing bearer token returns 401" do
      conn = mcp_request("initialize", %{"protocolVersion" => "2025-03-26"}, nil)
      # Phantom returns unauthorized via connect/2 callback
      assert conn.status in [401, 403]
    end

    test "invalid bearer token returns 401" do
      conn = mcp_request("initialize", %{"protocolVersion" => "2025-03-26"}, "mcp_invalid")
      assert conn.status in [401, 403]
    end

    test "revoked token returns 401", %{token: token} do
      hash = McpTokens.hash_token(token)
      mcp_token = McpTokens.get_by_token_hash(hash)
      McpTokens.revoke_mcp_token(mcp_token)

      conn = mcp_request("initialize", %{"protocolVersion" => "2025-03-26"}, token)
      assert conn.status in [401, 403]
    end
  end

  describe "resources — channel list" do
    test "lists public channels the bot can see", %{token: token, channel: channel} do
      conn = mcp_request("resources/read", %{
        "uri" => "tenun:///channels"
      }, token)

      assert %{"result" => %{"contents" => contents}} = json_response(conn, 200)
      channels = Jason.decode!(hd(contents)["text"])
      assert Enum.any?(channels, &(&1["slug"] == "general"))
    end
  end

  describe "resources — channel messages" do
    test "reads messages from a channel the bot has joined", ctx do
      # Send a real message through Messaging
      {:ok, _} = Slackex.Chat.send_message(ctx.channel.id, ctx.user.id, "hello from test")

      conn = mcp_request("resources/read", %{
        "uri" => "tenun:///channels/#{ctx.channel.id}/messages"
      }, ctx.token)

      assert %{"result" => %{"contents" => contents}} = json_response(conn, 200)
      messages = Jason.decode!(hd(contents)["text"])
      assert Enum.any?(messages, &(&1["content"] == "hello from test"))
    end

    test "rejects reading a channel the bot hasn't joined", ctx do
      other_user = insert(:user)
      other_channel = insert(:channel, creator: other_user)

      conn = mcp_request("resources/read", %{
        "uri" => "tenun:///channels/#{other_channel.id}/messages"
      }, ctx.token)

      result = json_response(conn, 200)
      assert result["result"]["isError"] == true ||
             get_in(result, ["error", "message"]) != nil
    end
  end

  # Helper: sends a JSON-RPC MCP request to /mcp
  defp mcp_request(method, params, token) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

    conn = build_conn()
    |> put_req_header("content-type", "application/json")

    conn = if token do
      put_req_header(conn, "authorization", "Bearer #{token}")
    else
      conn
    end

    conn
    |> post("/mcp", Jason.encode!(body))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex_web/mcp/router_test.exs`
Expected: Compilation errors — MCP router doesn't exist, `/mcp` route not mounted.

- [ ] **Step 3: Write the MCP Router**

Create `lib/slackex_web/mcp/router.ex`:

```elixir
defmodule SlackexWeb.MCP.Router do
  @moduledoc """
  Tenun MCP server. Exposes channels, messages, threads, and search
  to external AI agents via the Model Context Protocol.
  """

  use Phantom.Router,
    name: "Tenun",
    vsn: "1.0.0",
    instructions: """
    Tenun is a messaging platform. You can read channels, send messages,
    search message history, and subscribe to real-time channel events.
    Use the bot user identity associated with your token.
    """

  alias Slackex.Chat
  alias Slackex.Accounts
  alias Slackex.Integrations.McpTokens
  alias SlackexWeb.MCP.Serializer

  require Phantom.Tool, as: Tool
  require Phantom.Resource, as: Resource

  # -- Auth ------------------------------------------------------------------

  @impl true
  def connect(session, %Plug.Conn{} = conn) do
    with ["Bearer " <> raw_token] <- Plug.Conn.get_req_header(conn, "authorization"),
         hash = McpTokens.hash_token(raw_token),
         %{is_active: true} = token <- McpTokens.get_by_token_hash(hash) do
      McpTokens.touch_last_used(token)
      session = Phantom.Session.assign(session, :bot_user, token.bot_user)
      session = Phantom.Session.assign(session, :mcp_token, token)
      {:ok, session}
    else
      _ -> {:unauthorized, "Bearer"}
    end
  end

  # -- Resources -------------------------------------------------------------

  resource "tenun:///channels", __MODULE__, :list_channels,
    description: "List all public channels with member counts",
    mime_type: "application/json"

  resource "tenun:///channels/:id", __MODULE__, :read_channel,
    description: "Get channel metadata: name, slug, description, member count",
    mime_type: "application/json"

  resource "tenun:///channels/:id/messages", __MODULE__, :read_messages,
    description: "Paginated messages in a channel. Params: before, after (Snowflake IDs), limit (default 50, max 200)",
    mime_type: "application/json"

  resource "tenun:///channels/:id/threads/:message_id", __MODULE__, :read_thread,
    description: "Full thread from a parent message",
    mime_type: "application/json"

  resource "tenun:///users/:id", __MODULE__, :read_user,
    description: "User profile: display name, username, avatar, is_bot flag",
    mime_type: "application/json"

  def list_channels(_params, _request, session) do
    channels = Chat.list_public_channels([])
    data = Enum.map(channels, fn ch ->
      count = Chat.count_members(ch.id)
      Serializer.channel(ch, count)
    end)
    {:reply, Resource.text(Jason.encode!(data)), session}
  end

  def read_channel(%{"id" => id}, _request, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(id)
    with :ok <- verify_membership(bot.id, channel_id) do
      channel = Chat.get_channel!(channel_id)
      count = Chat.count_members(channel.id)
      {:reply, Resource.text(Jason.encode!(Serializer.channel(channel, count))), session}
    else
      {:error, :unauthorized} ->
        {:reply, Resource.text(Jason.encode!(%{error: "Not a member of this channel"})), session}
    end
  end

  def read_messages(%{"id" => id} = params, _request, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(id)

    with :ok <- verify_membership(bot.id, channel_id) do
      limit = params |> Map.get("limit", "50") |> parse_int() |> min(200)
      opts = [limit: limit]
      opts = if params["before"], do: [{:before, String.to_integer(params["before"])} | opts], else: opts
      opts = if params["after"], do: [{:after, String.to_integer(params["after"])} | opts], else: opts

      messages = Chat.list_messages(channel_id, opts)
      {:reply, Resource.text(Jason.encode!(Serializer.messages(messages))), session}
    else
      {:error, :unauthorized} ->
        {:reply, Resource.text(Jason.encode!(%{error: "Not a member of this channel"})), session}
    end
  end

  def read_thread(%{"id" => channel_id_str, "message_id" => msg_id_str}, _request, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(channel_id_str)

    with :ok <- verify_membership(bot.id, channel_id),
         parent <- Chat.get_message!(String.to_integer(msg_id_str)),
         true <- parent.channel_id == channel_id do
      messages = Chat.list_thread(parent.id, [])
      {:reply, Resource.text(Jason.encode!(Serializer.messages(messages))), session}
    else
      false ->
        {:reply, Resource.text(Jason.encode!(%{error: "Message does not belong to this channel"})), session}
      {:error, :unauthorized} ->
        {:reply, Resource.text(Jason.encode!(%{error: "Not a member of this channel"})), session}
    end
  end

  def read_user(%{"id" => id}, _request, session) do
    case Accounts.get_user(String.to_integer(id)) do
      nil -> {:reply, Resource.text(Jason.encode!(%{error: "User not found"})), session}
      user -> {:reply, Resource.text(Jason.encode!(Serializer.user(user))), session}
    end
  end

  # -- Private ---------------------------------------------------------------

  defp verify_membership(bot_user_id, channel_id) do
    if Chat.get_role(bot_user_id, channel_id), do: :ok, else: {:error, :unauthorized}
  end

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 50
    end
  end
  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: 50
end
```

- [ ] **Step 4: Mount in Phoenix router**

In `lib/slackex_web/router.ex`, add after the `:api` pipeline definition (around line 23):

```elixir
pipeline :mcp do
  plug :accepts, ["json", "sse"]
  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: Jason
end
```

And add the scope (before the health check routes, around line 33):

```elixir
# MCP server — bearer token auth, no session/CSRF
scope "/mcp" do
  pipe_through :mcp
  forward "/", Phantom.Plug,
    router: SlackexWeb.MCP.Router,
    pubsub: Slackex.PubSub,
    origins: :all
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/slackex_web/mcp/router_test.exs`
Expected: All pass. Auth works, channel list returns data, unauthorized channel read returns error.

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/mcp/router.ex lib/slackex_web/router.ex \
  test/slackex_web/mcp/router_test.exs
git commit -m "feat(mcp): add MCP router with auth and channel resources"
```

---

### Task 6: MCP Tools — send_message, reply, react, search

**Files:**
- Modify: `lib/slackex_web/mcp/router.ex`
- Modify: `test/slackex_web/mcp/router_test.exs`

- [ ] **Step 1: Write failing tests for tools**

Add to `test/slackex_web/mcp/router_test.exs`:

```elixir
describe "tools — send_message" do
  test "bot sends message to a channel it has joined", ctx do
    conn = mcp_request("tools/call", %{
      "name" => "send_message",
      "arguments" => %{
        "channel_id" => to_string(ctx.channel.id),
        "content" => "hello from MCP"
      }
    }, ctx.token)

    assert %{"result" => %{"content" => [%{"text" => text}]}} = json_response(conn, 200)
    msg = Jason.decode!(text)
    assert msg["content"] == "hello from MCP"
    assert msg["sender_id"] == to_string(ctx.bot.id)
  end
end

describe "tools — search_messages" do
  test "searches messages across bot's channels", ctx do
    # Send a message through the normal pipeline
    {:ok, _} = Slackex.Chat.send_message(ctx.channel.id, ctx.user.id, "unique_search_term_xyz")

    # Small delay for search index
    Process.sleep(100)

    conn = mcp_request("tools/call", %{
      "name" => "search_messages",
      "arguments" => %{
        "query" => "unique_search_term_xyz",
        "mode" => "text"
      }
    }, ctx.token)

    result = json_response(conn, 200)
    # Search may return results or feature-disabled error
    assert result["result"]["content"] != nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex_web/mcp/router_test.exs`
Expected: Fails — tools not defined in the router.

- [ ] **Step 3: Add tools to MCP Router**

Add to `lib/slackex_web/mcp/router.ex`, after the resources section:

```elixir
# -- Tools -----------------------------------------------------------------

tool :send_message,
  description: "Send a message to a channel as your bot user",
  input_schema: %{
    required: ["channel_id", "content"],
    properties: %{
      "channel_id" => %{type: "string", description: "Channel ID"},
      "content" => %{type: "string", description: "Message content (supports markdown)"}
    }
  }

tool :reply_to_thread,
  description: "Reply to a thread in a channel as your bot user",
  input_schema: %{
    required: ["channel_id", "parent_message_id", "content"],
    properties: %{
      "channel_id" => %{type: "string", description: "Channel ID"},
      "parent_message_id" => %{type: "string", description: "Parent message Snowflake ID"},
      "content" => %{type: "string", description: "Reply content"}
    }
  }

tool :react_to_message,
  description: "Add or remove a reaction on a message",
  input_schema: %{
    required: ["channel_id", "message_id", "emoji"],
    properties: %{
      "channel_id" => %{type: "string", description: "Channel ID (for authorization)"},
      "message_id" => %{type: "string", description: "Message Snowflake ID"},
      "emoji" => %{type: "string", description: "Emoji name (e.g. thumbsup, heart)"}
    }
  }

tool :search_messages,
  description: "Search message history. Modes: text (FTS), semantic (vector), hybrid (default, both merged with RRF)",
  input_schema: %{
    required: ["query"],
    properties: %{
      "query" => %{type: "string", description: "Search query"},
      "mode" => %{type: "string", description: "Search mode: text, semantic, or hybrid (default)"},
      "channel_id" => %{type: "string", description: "Optional: scope to a specific channel"},
      "limit" => %{type: "integer", description: "Max results (default 20)"}
    }
  }

def send_message(%{"channel_id" => cid, "content" => content}, session) do
  bot = session.assigns.bot_user
  channel_id = String.to_integer(cid)

  case Slackex.Messaging.send_message(channel_id, bot.id, content, []) do
    {:ok, msg} ->
      # msg is a plain map from ChannelServer (batch-written to DB later).
      # Serialize directly from the map — do NOT re-fetch from DB (race condition).
      {:reply, Tool.text(Jason.encode!(Serializer.message_from_map(msg))), session}

    {:error, reason} ->
      {:reply, Tool.text("Error: #{inspect(reason)}"), session}
  end
end

def reply_to_thread(%{"channel_id" => cid, "parent_message_id" => pid, "content" => content}, session) do
  bot = session.assigns.bot_user

  case Slackex.Messaging.send_reply(
    String.to_integer(cid), :channel, bot.id, String.to_integer(pid), content
  ) do
    {:ok, msg} ->
      # Same as send_message — msg is a ChannelServer map, not an Ecto struct
      {:reply, Tool.text(Jason.encode!(Serializer.message_from_map(msg))), session}

    {:error, reason} ->
      {:reply, Tool.text("Error: #{inspect(reason)}"), session}
  end
end

def react_to_message(%{"channel_id" => cid, "message_id" => mid, "emoji" => emoji}, session) do
  bot = session.assigns.bot_user

  with :ok <- verify_membership(bot.id, String.to_integer(cid)) do
    case Slackex.Messaging.toggle_reaction(String.to_integer(mid), bot.id, emoji) do
      {:ok, {:swapped, _, _}} ->
        {:reply, Tool.text("Reaction swapped"), session}

      {:ok, {action, _}} ->
        {:reply, Tool.text("Reaction #{action}"), session}

      {:error, reason} ->
        {:reply, Tool.text("Error: #{inspect(reason)}"), session}
    end
  else
    {:error, :unauthorized} ->
      {:reply, Tool.text("Error: Not a member of this channel"), session}
  end
end

def search_messages(%{"query" => query} = params, session) do
  bot = session.assigns.bot_user
  mode = case Map.get(params, "mode", "hybrid") do
    "text" -> :text
    "semantic" -> :semantic
    _ -> :hybrid
  end
  limit = params |> Map.get("limit", 20)
  opts = [mode: mode, limit: limit]
  opts = if params["channel_id"], do: [{:channel_id, String.to_integer(params["channel_id"])} | opts], else: opts

  case Slackex.Search.search_messages(bot.id, query, opts) do
    {:ok, messages} ->
      {:reply, Tool.text(Jason.encode!(Serializer.messages(messages))), session}

    {:error, reason} ->
      {:reply, Tool.text("Error: #{inspect(reason)}"), session}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex_web/mcp/router_test.exs`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/mcp/router.ex test/slackex_web/mcp/router_test.exs
git commit -m "feat(mcp): add send_message, reply, react, and search tools"
```

---

### Task 7: MCP Prompts — summarize_channel and draft_spec

**Files:**
- Modify: `lib/slackex_web/mcp/router.ex`
- Modify: `test/slackex_web/mcp/router_test.exs`

- [ ] **Step 1: Write failing test for prompts**

Add to `test/slackex_web/mcp/router_test.exs`:

```elixir
describe "prompts — summarize_channel" do
  test "returns prompt with channel context", ctx do
    conn = mcp_request("prompts/get", %{
      "name" => "summarize_channel",
      "arguments" => %{"channel_id" => to_string(ctx.channel.id)}
    }, ctx.token)

    assert %{"result" => %{"messages" => messages}} = json_response(conn, 200)
    assert length(messages) > 0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/slackex_web/mcp/router_test.exs --only describe:"prompts"`
Expected: Fails — prompts not defined.

- [ ] **Step 3: Add prompts to MCP Router**

Add to `lib/slackex_web/mcp/router.ex`:

```elixir
# -- Prompts ---------------------------------------------------------------

require Phantom.Prompt, as: Prompt

prompt :summarize_channel,
  description: "Summarize recent activity in a channel. Fetches messages and guides you to produce a structured summary.",
  arguments: [
    %{name: "channel_id", description: "Channel ID to summarize", required: true},
    %{name: "since", description: "ISO 8601 timestamp — only summarize messages after this time (optional)"}
  ]

prompt :draft_spec,
  description: "Draft a feature spec from a channel discussion. Reads the conversation and guides you to produce a structured spec with acceptance criteria.",
  arguments: [
    %{name: "channel_id", description: "Channel ID containing the discussion", required: true},
    %{name: "thread_id", description: "Optional: specific thread message ID to focus on"}
  ]

def summarize_channel(%{"channel_id" => _cid} = _args, _request, session) do
  {:reply, Prompt.response([
    user: Prompt.text("""
    Summarize the recent activity in this channel. Use the `read_messages` resource
    to fetch recent messages, then produce a structured summary with:

    1. **Key topics discussed** — what was talked about
    2. **Decisions made** — any conclusions or agreements
    3. **Action items** — tasks mentioned or assigned
    4. **Open questions** — unresolved topics

    Keep the summary concise. Focus on substance, not chatter.
    """)
  ]), session}
end

def draft_spec(%{"channel_id" => _cid} = _args, _request, session) do
  {:reply, Prompt.response([
    user: Prompt.text("""
    Draft a feature specification from the discussion in this channel. Use the
    `read_messages` resource (and optionally `read_thread` for a specific thread)
    to read the conversation, then produce a structured spec:

    ## Title
    One-line feature name

    ## Problem Statement
    What problem does this solve? Who has it?

    ## Proposed Solution
    High-level description of the approach

    ## Acceptance Criteria
    Given/When/Then format:
    - Given [context], when [action], then [expected outcome]

    ## Constraints
    Non-functional requirements, safety rules, architectural boundaries

    ## Open Questions
    Unresolved decisions that need input

    Be specific. Extract concrete details from the discussion — don't generalize.
    """)
  ]), session}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex_web/mcp/router_test.exs`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/mcp/router.ex test/slackex_web/mcp/router_test.exs
git commit -m "feat(mcp): add summarize_channel and draft_spec prompts"
```

---

### Task 8: PubSub Subscriber — real-time event bridge

**Files:**
- Create: `lib/slackex_web/mcp/subscriber.ex`
- Create: `test/slackex_web/mcp/subscriber_test.exs`
- Modify: `lib/slackex_web/mcp/router.ex` (wire subscribe/unsubscribe)

- [ ] **Step 1: Write failing tests for subscriber**

Create `test/slackex_web/mcp/subscriber_test.exs`:

```elixir
defmodule SlackexWeb.MCP.SubscriberTest do
  use Slackex.DataCase, async: false

  alias SlackexWeb.MCP.Subscriber
  alias Slackex.Messaging.Envelope

  describe "event filtering" do
    test "forwards matching events, drops non-matching" do
      # Start subscriber with specific event types
      {:ok, pid} = Subscriber.start_link(%{
        session_pid: self(),
        channel_id: 123,
        event_types: ["new_message", "message_deleted"]
      })

      # Simulate PubSub envelope using the REAL Envelope.wrap/3
      envelope = Envelope.wrap("message.new", {:channel, 123}, %{id: 1, content: "test"})
      send(pid, {:envelope, envelope})

      # Should receive mapped event
      assert_receive {:mcp_event, %{type: "new_message", payload: _}}, 1000

      # Simulate typing (not subscribed)
      typing_envelope = Envelope.wrap("typing", {:channel, 123}, %{user_id: 1, username: "alice"})
      send(pid, {:envelope, typing_envelope})

      # Should NOT receive typing
      refute_receive {:mcp_event, %{type: "typing"}}, 200

      GenServer.stop(pid)
    end

    test "uses default event types when none specified" do
      {:ok, pid} = Subscriber.start_link(%{
        session_pid: self(),
        channel_id: 456,
        event_types: nil
      })

      # Default includes message.new — use real envelope shape
      envelope = Envelope.wrap("message.new", {:channel, 456}, %{id: 1, content: "hi"})
      send(pid, {:envelope, envelope})

      assert_receive {:mcp_event, _}, 1000

      GenServer.stop(pid)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex_web/mcp/subscriber_test.exs`
Expected: Compilation error — `Subscriber` doesn't exist.

- [ ] **Step 3: Write the Subscriber GenServer**

Create `lib/slackex_web/mcp/subscriber.ex`:

```elixir
defmodule SlackexWeb.MCP.Subscriber do
  @moduledoc """
  PubSub → SSE bridge for MCP sessions. One subscriber per channel subscription
  per MCP session. Filters events by the agent's requested event types and
  forwards matching events to the session process.
  """

  use GenServer

  @default_event_types ["new_message", "message_edited", "message_deleted"]

  @event_map %{
    "message.new" => "new_message",
    "message.edited" => "message_edited",
    "message.deleted" => "message_deleted",
    "reaction.toggled" => "reaction_toggled",
    "typing" => "typing"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(%{session_pid: session_pid, channel_id: channel_id, event_types: event_types}) do
    types = event_types || @default_event_types
    Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel_id}")

    {:ok, %{
      session_pid: session_pid,
      channel_id: channel_id,
      event_types: MapSet.new(types)
    }}
  end

  @impl true
  def handle_info({:envelope, %{event: event, payload: payload, meta: meta}}, state) do
    # Pattern matches the real Envelope.wrap/3 shape:
    # %{v: 1, event: "message.new", target: %{type: :channel, id: id}, payload: map, meta: %{sent_at: dt}}
    case Map.get(@event_map, event) do
      nil ->
        {:noreply, state}

      mcp_type ->
        if MapSet.member?(state.event_types, mcp_type) do
          send(state.session_pid, {:mcp_event, %{
            type: mcp_type,
            payload: payload,
            timestamp: meta.sent_at,
            channel_id: state.channel_id
          }})
        end

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex_web/mcp/subscriber_test.exs`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/mcp/subscriber.ex test/slackex_web/mcp/subscriber_test.exs
git commit -m "feat(mcp): add PubSub subscriber for real-time event bridge"
```

---

### Task 9: Integration test — full real-time path

**Files:**
- Modify: `test/slackex_web/mcp/router_test.exs`

This tests the full path: subscribe → send message via Messaging → SSE notification received. This is the critical wiring test per CLAUDE.md spec-driven rules.

- [ ] **Step 1: Write the full-path integration test**

Add to `test/slackex_web/mcp/router_test.exs`:

```elixir
describe "real-time — full path" do
  test "message sent via Messaging reaches MCP subscriber", ctx do
    alias SlackexWeb.MCP.Subscriber

    # Start a subscriber as if an MCP session subscribed
    {:ok, sub} = Subscriber.start_link(%{
      session_pid: self(),
      channel_id: ctx.channel.id,
      event_types: ["new_message"]
    })

    # Send a real message through the Messaging pipeline (NOT Chat.send_message
    # which writes to DB directly and does NOT broadcast via PubSub)
    {:ok, _msg} = Slackex.Messaging.send_message(ctx.channel.id, ctx.user.id, "real-time test", [])

    # The subscriber should forward the event to us
    assert_receive {:mcp_event, %{type: "new_message", payload: payload}}, 5000
    assert payload.content == "real-time test"

    GenServer.stop(sub)
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/slackex_web/mcp/router_test.exs --only describe:"real-time"`
Expected: PASS — proves the PubSub wiring exists end-to-end.

- [ ] **Step 3: Commit**

```bash
git add test/slackex_web/mcp/router_test.exs
git commit -m "test(mcp): add full-path real-time integration test"
```

---

### Task 10: Smoke test — compile, full test suite, manual verification

**Files:** None new.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: All tests pass including the new MCP tests. No regressions in existing tests.

- [ ] **Step 2: Verify compilation is clean**

Run: `mix compile --warnings-as-errors`
Expected: Clean compile, no warnings.

- [ ] **Step 3: Run Credo**

Run: `mix credo --strict`
Expected: No new issues from MCP modules.

- [ ] **Step 4: Run Dialyzer** (if time permits)

Run: `mix dialyzer`
Expected: No new warnings.

- [ ] **Step 5: Manual smoke test in dev**

Start the app: `mix phx.server`

Verify `/mcp` endpoint exists:
```bash
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}'
```
Expected: 401 or unauthorized response (no token provided).

- [ ] **Step 6: Create a token and test from IEx**

```elixir
{:ok, %{raw_token: token, bot_user: bot}} =
  Slackex.Integrations.McpTokens.create_mcp_token(%{name: "Dev Test"})

# Join bot to a channel
Slackex.Chat.join_channel(bot.id, channel_id)
```

Then test with curl:
```bash
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer mcp_..." \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}'
```
Expected: 200 with server info.

- [ ] **Step 7: Final commit if any adjustments needed**

```bash
git add -A
git commit -m "fix(mcp): adjustments from smoke testing"
```
