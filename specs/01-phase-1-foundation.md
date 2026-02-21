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
cd slackex
```

We skip `--no-live` since we want LiveView. Dashboard will be added manually later with auth protection.

### 1.2 Configure mix.exs

```elixir
defmodule Slackex.MixProject do
  use Mix.Project

  def project do
    [
      app: :slackex,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary] ++ Mix.compilers(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/project.plt"},
        flags: [:unmatched_returns, :error_handling, :no_opaque]
      ]
    ]
  end

  def application do
    [
      mod: {Slackex.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web Framework
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},

      # Database
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},

      # Auth
      {:bcrypt_elixir, "~> 3.0"},
      {:guardian, "~> 2.3"},

      # Architecture
      {:boundary, "~> 0.10", runtime: false},

      # Assets
      {:esbuild, "~> 0.8", runtime: false, only: :dev},
      {:tailwind, "~> 0.2", runtime: false, only: :dev},

      # Utilities
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.1.1"},
      {:html_sanitize_ex, "~> 1.4"},

      # AI Dev Tooling
      {:tidewave, "~> 0.5", only: :dev},

      # Static Analysis
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Test
      {:ex_machina, "~> 2.8", only: :test},
      {:floki, "~> 0.36", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind slackex", "esbuild slackex"],
      "assets.deploy": [
        "tailwind slackex --minify",
        "esbuild slackex --minify",
        "phx.digest"
      ],
      lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"],
      "lint.fix": ["format"],
      typecheck: ["dialyzer"]
    ]
  end
end
```

### 1.3 Tidewave Setup

In `lib/slackex_web/endpoint.ex`, add the Tidewave plug **before** the `code_reloading?` block:

```elixir
# Tidewave MCP server for AI-assisted development
if Code.ensure_loaded?(Tidewave) do
  plug Tidewave
end

if code_reloading? do
  # ... existing code reloading config
end
```

In `config/dev.exs`, enable LiveView debug annotations for Tidewave:

```elixir
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true
```

### 1.4 Configure Boundary Definitions

Each context module declares its boundary. Example for `Slackex.Accounts`:

```elixir
defmodule Slackex.Accounts do
  use Boundary, deps: [], exports: [User, UserToken, Auth]

  # ... context functions
end
```

```elixir
defmodule Slackex.Chat do
  use Boundary,
    deps: [Slackex.Accounts],
    exports: [Channel, Message, Subscription, DMConversation, ReadCursor, Permissions]
end
```

```elixir
defmodule Slackex.Infrastructure do
  use Boundary, deps: [], exports: [Snowflake, RateLimiter]
end
```

```elixir
defmodule SlackexWeb do
  use Boundary,
    deps: [Slackex.Accounts, Slackex.Chat, Slackex.Infrastructure],
    exports: []
end
```

Boundary violations produce compile warnings:
```
warning: forbidden reference to SlackexWeb
  (references from Slackex.Chat to SlackexWeb are not allowed)
```

With `--warnings-as-errors` in CI, these become build failures.

## Step 2: Database Schema & Migrations

### 2.1 Users Table

```elixir
defmodule Slackex.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false, size: 50
      add :display_name, :string, size: 100
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :avatar_url, :text
      add :status, :string, default: "offline", size: 20

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:email])
  end
end
```

### 2.2 User Tokens Table

```elixir
defmodule Slackex.Repo.Migrations.CreateUserTokens do
  use Ecto.Migration

  def change do
    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false  # "session", "api_access", "api_refresh"
      add :sent_to, :string               # email for confirmation tokens

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])
  end
end
```

### 2.3 Channels Table

```elixir
defmodule Slackex.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels) do
      add :name, :string, null: false, size: 100
      add :slug, :string, null: false, size: 100
      add :description, :text
      add :creator_id, references(:users, on_delete: :nilify_all)
      add :is_private, :boolean, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channels, [:slug])
    create index(:channels, [:creator_id])
  end
end
```

### 2.4 Subscriptions Table

```elixir
defmodule Slackex.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :channel_id, references(:channels, on_delete: :delete_all), primary_key: true
      add :role, :string, default: "member", size: 20  # owner, admin, member, viewer
      add :muted, :boolean, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:subscriptions, [:channel_id])
  end
end
```

### 2.5 Messages Table

In Phase 1, messages use a simple table. Phase 3 adds time-based partitioning.

```elixir
defmodule Slackex.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :bigint, primary_key: true  # Snowflake ID, not auto-increment
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :dm_conversation_id, :bigint     # Added as FK in DM migration
      add :sender_id, references(:users, on_delete: :nilify_all), null: false
      add :content, :text, null: false
      add :edited_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:messages, [:channel_id, :id])
    create index(:messages, [:dm_conversation_id, :id])
    create index(:messages, [:sender_id])

    # Full-text search index (basic — enhanced in Phase 4)
    execute(
      "CREATE INDEX idx_messages_fts ON messages USING GIN (to_tsvector('english', content))",
      "DROP INDEX idx_messages_fts"
    )
  end
end
```

### 2.6 DM Conversations Table

```elixir
defmodule Slackex.Repo.Migrations.CreateDmConversations do
  use Ecto.Migration

  def change do
    create table(:dm_conversations) do
      add :user_a_id, references(:users, on_delete: :delete_all), null: false
      add :user_b_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Ensure user_a_id < user_b_id to prevent duplicate conversations
    create unique_index(:dm_conversations, [:user_a_id, :user_b_id])
    create index(:dm_conversations, [:user_b_id])

    # Add FK from messages to dm_conversations
    alter table(:messages) do
      modify :dm_conversation_id, references(:dm_conversations, on_delete: :delete_all),
        from: :bigint
    end
  end
end
```

### 2.7 Read Cursors Table

```elixir
defmodule Slackex.Repo.Migrations.CreateReadCursors do
  use Ecto.Migration

  def change do
    create table(:read_cursors, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :channel_id, references(:channels, on_delete: :delete_all), primary_key: true
      add :last_read_message_id, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
```

## Step 3: Ecto Schemas

### 3.1 User Schema

```elixir
defmodule Slackex.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :email, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :avatar_url, :string
    field :status, :string, default: "offline"

    has_many :subscriptions, Slackex.Chat.Subscription
    has_many :channels, through: [:subscriptions, :channel]

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :email, :password])
    |> validate_required([:username, :email, :password])
    |> validate_length(:username, min: 3, max: 50)
    |> validate_format(:username, ~r/^[a-z0-9_.-]+$/,
         message: "must be lowercase alphanumeric with dots, dashes, or underscores")
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
```

### 3.2 Channel Schema

```elixir
defmodule Slackex.Chat.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  schema "channels" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :is_private, :boolean, default: false

    belongs_to :creator, Slackex.Accounts.User
    has_many :subscriptions, Slackex.Chat.Subscription
    has_many :members, through: [:subscriptions, :user]
    has_many :messages, Slackex.Chat.Message

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :is_private, :creator_id])
    |> validate_required([:name, :creator_id])
    |> validate_length(:name, min: 2, max: 100)
    |> generate_slug()
    |> unique_constraint(:slug)
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name ->
        slug = name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s-]/, "")
        |> String.replace(~r/\s+/, "-")
        |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
```

### 3.3 Message Schema

```elixir
defmodule Slackex.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "messages" do
    field :content, :string
    field :edited_at, :utc_datetime_usec

    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :dm_conversation, Slackex.Chat.DMConversation
    belongs_to :sender, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:id, :content, :channel_id, :dm_conversation_id, :sender_id])
    |> validate_required([:id, :content, :sender_id])
    |> validate_length(:content, min: 1, max: 4000)
    |> validate_target()  # Must have channel_id OR dm_conversation_id, not both
  end

  defp validate_target(changeset) do
    channel_id = get_field(changeset, :channel_id)
    dm_id = get_field(changeset, :dm_conversation_id)

    case {channel_id, dm_id} do
      {nil, nil} -> add_error(changeset, :channel_id, "must specify channel or DM")
      {_, nil} -> changeset
      {nil, _} -> changeset
      {_, _} -> add_error(changeset, :channel_id, "cannot specify both channel and DM")
    end
  end
end
```

### 3.4 Subscription, DMConversation, ReadCursor Schemas

```elixir
defmodule Slackex.Chat.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "subscriptions" do
    belongs_to :user, Slackex.Accounts.User, primary_key: true
    belongs_to :channel, Slackex.Chat.Channel, primary_key: true

    field :role, :string, default: "member"
    field :muted, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:user_id, :channel_id, :role, :muted])
    |> validate_required([:user_id, :channel_id])
    |> validate_inclusion(:role, ["owner", "admin", "member", "viewer"])
    |> unique_constraint([:user_id, :channel_id], name: :subscriptions_pkey)
  end
end
```

```elixir
defmodule Slackex.Chat.DMConversation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dm_conversations" do
    belongs_to :user_a, Slackex.Accounts.User
    belongs_to :user_b, Slackex.Accounts.User
    has_many :messages, Slackex.Chat.Message

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(dm, attrs) do
    dm
    |> cast(attrs, [:user_a_id, :user_b_id])
    |> validate_required([:user_a_id, :user_b_id])
    |> normalize_user_order()
    |> unique_constraint([:user_a_id, :user_b_id])
  end

  # Always store smaller user_id as user_a to prevent duplicate conversations
  defp normalize_user_order(changeset) do
    a = get_field(changeset, :user_a_id)
    b = get_field(changeset, :user_b_id)

    if a && b && a > b do
      changeset
      |> put_change(:user_a_id, b)
      |> put_change(:user_b_id, a)
    else
      changeset
    end
  end
end
```

```elixir
defmodule Slackex.Chat.ReadCursor do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "read_cursors" do
    belongs_to :user, Slackex.Accounts.User, primary_key: true
    belongs_to :channel, Slackex.Chat.Channel, primary_key: true

    field :last_read_message_id, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:user_id, :channel_id, :last_read_message_id])
    |> validate_required([:user_id, :channel_id, :last_read_message_id])
  end
end
```

## Step 4: Snowflake ID Generator

```elixir
defmodule Slackex.Infrastructure.Snowflake do
  @moduledoc """
  64-bit Snowflake ID generator.

  Layout: [1 bit unused][41 bits timestamp][10 bits node_id][12 bits sequence]

  - Timestamp: milliseconds since custom epoch (2025-01-01T00:00:00Z)
  - Node ID: derived from BEAM node name hash, supports 1024 nodes
  - Sequence: 4096 IDs per millisecond per node
  """
  use GenServer

  @epoch 1_735_689_600_000  # 2025-01-01 00:00:00 UTC in ms
  @node_bits 10
  @seq_bits 12
  @max_node_id (1 <<< @node_bits) - 1
  @max_seq (1 <<< @seq_bits) - 1

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def generate do
    GenServer.call(__MODULE__, :generate)
  end

  def extract_timestamp(id) do
    (id >>> (@node_bits + @seq_bits)) + @epoch
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    node_id = Keyword.get_lazy(opts, :node_id, &derive_node_id/0)
    {:ok, %{node_id: node_id, sequence: 0, last_timestamp: 0}}
  end

  @impl true
  def handle_call(:generate, _from, state) do
    now = System.system_time(:millisecond) - @epoch

    {seq, ts} = cond do
      now == state.last_timestamp ->
        seq = state.sequence + 1
        if seq > @max_seq do
          {0, wait_next_ms(now)}
        else
          {seq, now}
        end

      now > state.last_timestamp ->
        {0, now}

      true ->
        # Clock went backwards — wait
        {0, wait_next_ms(state.last_timestamp)}
    end

    id = (ts <<< (@node_bits + @seq_bits)) |||
         (state.node_id <<< @seq_bits) |||
         seq

    {:reply, id, %{state | sequence: seq, last_timestamp: ts}}
  end

  # --- Private ---

  defp derive_node_id do
    :erlang.phash2(node(), @max_node_id + 1)
  end

  defp wait_next_ms(current_ts) do
    now = System.system_time(:millisecond) - @epoch
    if now > current_ts, do: now, else: wait_next_ms(current_ts)
  end
end
```

## Step 5: Context Modules (Public APIs)

### 5.1 Accounts Context

```elixir
defmodule Slackex.Accounts do
  use Boundary, deps: [], exports: [User, UserToken, Auth]

  alias Slackex.Repo
  alias Slackex.Accounts.{User, UserToken}

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def get_user_by_email_and_password(email, password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  def get_user!(id), do: Repo.get!(User, id)

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end
end
```

### 5.2 Chat Context

```elixir
defmodule Slackex.Chat do
  use Boundary,
    deps: [Slackex.Accounts],
    exports: [Channel, Message, Subscription, DMConversation, ReadCursor, Permissions]

  import Ecto.Query
  alias Slackex.Repo
  alias Slackex.Chat.{Channel, Message, Subscription, DMConversation, ReadCursor, Permissions}
  alias Slackex.Infrastructure.Snowflake

  # --- Channels ---

  def create_channel(user_id, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:channel, Channel.changeset(%Channel{}, Map.put(attrs, :creator_id, user_id)))
    |> Ecto.Multi.insert(:subscription, fn %{channel: channel} ->
      Subscription.changeset(%Subscription{}, %{
        user_id: user_id,
        channel_id: channel.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{channel: channel}} -> {:ok, channel}
      {:error, :channel, changeset, _} -> {:error, changeset}
    end
  end

  def list_public_channels do
    Channel
    |> where([c], c.is_private == false)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  def list_user_channels(user_id) do
    Channel
    |> join(:inner, [c], s in Subscription, on: s.channel_id == c.id and s.user_id == ^user_id)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  def get_channel!(id), do: Repo.get!(Channel, id)
  def get_channel_by_slug!(slug), do: Repo.get_by!(Channel, slug: slug)

  def join_channel(user_id, channel_id) do
    channel = get_channel!(channel_id)

    if channel.is_private do
      {:error, :unauthorized}
    else
      %Subscription{}
      |> Subscription.changeset(%{user_id: user_id, channel_id: channel_id})
      |> Repo.insert(on_conflict: :nothing)
    end
  end

  def leave_channel(user_id, channel_id) do
    Repo.delete_all(
      from(s in Subscription,
        where: s.user_id == ^user_id and s.channel_id == ^channel_id
      )
    )
    :ok
  end

  def get_role(user_id, channel_id) do
    Repo.one(
      from(s in Subscription,
        where: s.user_id == ^user_id and s.channel_id == ^channel_id,
        select: s.role
      )
    )
  end

  # --- Messages (Phase 1: direct persistence, Phase 2: via ChannelServer) ---

  def send_message(channel_id, sender_id, content) do
    with role when role in ["owner", "admin", "member"] <- get_role(sender_id, channel_id) do
      message_attrs = %{
        id: Snowflake.generate(),
        channel_id: channel_id,
        sender_id: sender_id,
        content: HtmlSanitizeEx.strip_tags(content)
      }

      %Message{}
      |> Message.changeset(message_attrs)
      |> Repo.insert()
      |> case do
        {:ok, message} ->
          message = Repo.preload(message, :sender)
          Phoenix.PubSub.broadcast(Slackex.PubSub, "channel:#{channel_id}", {:new_message, message})
          {:ok, message}

        error ->
          error
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  def list_messages(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before)

    query = from(m in Message,
      where: m.channel_id == ^channel_id,
      order_by: [asc: m.id],
      limit: ^limit,
      preload: [:sender]
    )

    query = if before_id do
      where(query, [m], m.id < ^before_id)
    else
      query
    end

    Repo.all(query)
  end

  # --- DMs ---

  def find_or_create_dm(user_a_id, user_b_id) do
    {a, b} = if user_a_id < user_b_id, do: {user_a_id, user_b_id}, else: {user_b_id, user_a_id}

    case Repo.get_by(DMConversation, user_a_id: a, user_b_id: b) do
      nil ->
        %DMConversation{}
        |> DMConversation.changeset(%{user_a_id: a, user_b_id: b})
        |> Repo.insert()

      dm ->
        {:ok, dm}
    end
  end

  def send_dm(dm_id, sender_id, content) do
    message_attrs = %{
      id: Snowflake.generate(),
      dm_conversation_id: dm_id,
      sender_id: sender_id,
      content: HtmlSanitizeEx.strip_tags(content)
    }

    %Message{}
    |> Message.changeset(message_attrs)
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        message = Repo.preload(message, :sender)
        Phoenix.PubSub.broadcast(Slackex.PubSub, "dm:#{dm_id}", {:new_message, message})
        {:ok, message}

      error ->
        error
    end
  end

  def list_dms(user_id) do
    from(dm in DMConversation,
      where: dm.user_a_id == ^user_id or dm.user_b_id == ^user_id,
      order_by: [desc: dm.inserted_at]
    )
    |> Repo.all()
  end

  # --- Read Cursors ---

  def mark_as_read(user_id, channel_id) do
    latest_message_id =
      from(m in Message,
        where: m.channel_id == ^channel_id,
        select: max(m.id)
      )
      |> Repo.one()

    if latest_message_id do
      %ReadCursor{}
      |> ReadCursor.changeset(%{
        user_id: user_id,
        channel_id: channel_id,
        last_read_message_id: latest_message_id
      })
      |> Repo.insert(
        on_conflict: {:replace, [:last_read_message_id, :updated_at]},
        conflict_target: [:user_id, :channel_id]
      )
    else
      {:ok, nil}
    end
  end

  def unread_count(user_id, channel_id) do
    cursor = Repo.get_by(ReadCursor, user_id: user_id, channel_id: channel_id)
    last_read_id = if cursor, do: cursor.last_read_message_id, else: 0

    from(m in Message,
      where: m.channel_id == ^channel_id and m.id > ^last_read_id,
      select: count(m.id)
    )
    |> Repo.one()
  end
end
```

## Step 6: Permissions Module

```elixir
defmodule Slackex.Chat.Permissions do
  @roles_hierarchy %{
    "owner" => 4,
    "admin" => 3,
    "member" => 2,
    "viewer" => 1
  }

  def can?(role, :send_message), do: role_level(role) >= 2
  def can?(role, :manage_channel), do: role_level(role) >= 3
  def can?(role, :delete_channel), do: role_level(role) >= 4
  def can?(role, :read_messages), do: role_level(role) >= 1
  def can?(_, _), do: false

  defp role_level(role), do: Map.get(@roles_hierarchy, role, 0)
end
```

## Step 7: LiveView Chat Interface

### 7.1 Router

```elixir
# lib/slackex_web/router.ex
defmodule SlackexWeb.Router do
  use SlackexWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SlackexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authenticated routes
  live_session :authenticated,
    on_mount: [{SlackexWeb.UserAuth, :ensure_authenticated}] do
    scope "/", SlackexWeb do
      pipe_through :browser

      live "/chat", ChatLive.Index, :index
      live "/chat/:slug", ChatLive.Index, :channel
    end
  end

  # Public routes
  scope "/", SlackexWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Auth routes (generated by phx.gen.auth, adapted)
  scope "/", SlackexWeb do
    pipe_through [:browser]

    live_session :auth, on_mount: [{SlackexWeb.UserAuth, :redirect_if_authenticated}] do
      live "/users/register", AuthLive.Register, :new
      live "/users/log-in", AuthLive.Login, :new
    end

    delete "/users/log-out", UserSessionController, :delete
  end

  # Mobile API
  scope "/api", SlackexWeb.API do
    pipe_through :api

    post "/auth/login", AuthController, :login
    post "/auth/refresh", AuthController, :refresh
  end
end
```

### 7.2 Main Chat LiveView

```elixir
defmodule SlackexWeb.ChatLive.Index do
  use SlackexWeb, :live_view

  alias Slackex.Chat

  @messages_per_page 50

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      # Subscribe to user-level notifications (unread counts, new DMs)
      Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{user.id}")
    end

    channels = Chat.list_user_channels(user.id)
    dms = Chat.list_dms(user.id)

    {:ok,
     socket
     |> assign(:channels, channels)
     |> assign(:dms, dms)
     |> assign(:active_channel, nil)
     |> assign(:typing_users, MapSet.new())
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    channel = Chat.get_channel_by_slug!(slug)
    {:noreply, activate_channel(socket, channel)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp activate_channel(socket, channel) do
    user = socket.assigns.current_user

    # Unsubscribe from previous channel
    if old = socket.assigns.active_channel do
      Phoenix.PubSub.unsubscribe(Slackex.PubSub, "channel:#{old.id}")
    end

    # Subscribe to new channel
    Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel.id}")

    messages = Chat.list_messages(channel.id, limit: @messages_per_page)
    Chat.mark_as_read(user.id, channel.id)

    socket
    |> assign(:active_channel, channel)
    |> assign(:typing_users, MapSet.new())
    |> stream(:messages, messages, reset: true)
  end

  # --- Events ---

  @impl true
  def handle_event("send_message", %{"content" => content}, socket) when content != "" do
    user = socket.assigns.current_user
    channel = socket.assigns.active_channel

    case Chat.send_message(channel.id, user.id, content) do
      {:ok, _message} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to send message")}
    end
  end

  def handle_event("send_message", _, socket), do: {:noreply, socket}

  def handle_event("select_channel", %{"slug" => slug}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{slug}")}
  end

  def handle_event("load_more", _params, socket) do
    channel = socket.assigns.active_channel

    if channel do
      # Load older messages (stream_insert at position 0 = prepend)
      # The JS hook tracks the oldest visible message ID
      # For now, this is a placeholder — enhanced in Phase 2
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:new_message, message}, socket) do
    socket =
      socket
      |> stream_insert(:messages, message)
      |> maybe_mark_as_read(message)

    {:noreply, socket}
  end

  def handle_info({:user_typing, user}, socket) do
    Process.send_after(self(), {:clear_typing, user.id}, 3_000)
    {:noreply, assign(socket, :typing_users, MapSet.put(socket.assigns.typing_users, user))}
  end

  def handle_info({:clear_typing, user_id}, socket) do
    typing = MapSet.reject(socket.assigns.typing_users, &(&1.id == user_id))
    {:noreply, assign(socket, :typing_users, typing)}
  end

  defp maybe_mark_as_read(socket, message) do
    # Auto-mark as read if user is viewing the channel
    if socket.assigns.active_channel &&
       socket.assigns.active_channel.id == message.channel_id do
      Chat.mark_as_read(socket.assigns.current_user.id, message.channel_id)
    end

    socket
  end
end
```

### 7.3 WebSocket for Mobile Clients

```elixir
defmodule SlackexWeb.UserSocket do
  use Phoenix.Socket

  channel "chat:*", SlackexWeb.ChatChannel
  channel "dm:*", SlackexWeb.DMChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Slackex.Accounts.Auth.verify_api_token(token) do
      {:ok, user_id} ->
        {:ok, assign(socket, :current_user_id, user_id)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"
end
```

```elixir
defmodule SlackexWeb.ChatChannel do
  use SlackexWeb, :channel

  alias Slackex.Chat

  @impl true
  def join("chat:" <> channel_id, _params, socket) do
    channel_id = String.to_integer(channel_id)
    user_id = socket.assigns.current_user_id

    case Chat.get_role(user_id, channel_id) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      _role ->
        messages = Chat.list_messages(channel_id, limit: 50)
        Chat.mark_as_read(user_id, channel_id)

        {:ok, %{messages: messages}, assign(socket, :channel_id, channel_id)}
    end
  end

  @impl true
  def handle_in("new_message", %{"content" => content}, socket) do
    case Chat.send_message(
      socket.assigns.channel_id,
      socket.assigns.current_user_id,
      content
    ) do
      {:ok, message} ->
        broadcast!(socket, "new_message", %{
          id: message.id,
          content: message.content,
          sender: %{
            id: message.sender.id,
            username: message.sender.username,
            avatar_url: message.sender.avatar_url
          },
          inserted_at: message.inserted_at
        })
        {:reply, :ok, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "send_failed"}}, socket}
    end
  end
end
```

## Step 8: Application Supervisor (Phase 1)

```elixir
defmodule Slackex.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database
      Slackex.Repo,

      # PubSub
      {Phoenix.PubSub, name: Slackex.PubSub},

      # Snowflake ID generator
      Slackex.Infrastructure.Snowflake,

      # Web endpoint (must be last)
      SlackexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Slackex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SlackexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

## Step 9: Docker Compose for Local Development

```yaml
# docker-compose.yml
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: slackex_dev
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
  redisdata:
```

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
- [ ] Mobile client can authenticate via JWT and join channels via WebSocket
- [ ] Mobile client can send/receive messages via Phoenix Channel protocol
- [ ] Unread counts are tracked via read cursors
- [ ] DM conversations work between two users
- [ ] Tidewave MCP server is accessible in dev for AI-assisted development
- [ ] `docker-compose up` starts Postgres (with pgvector) and Redis
- [ ] `mix setup` bootstraps the entire project from scratch
- [ ] All behavioral tests pass
