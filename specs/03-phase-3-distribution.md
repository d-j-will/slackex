# Phase 3 — Distribution & Scale

## Goal

Transform the single-node application into a distributed BEAM cluster. Replace local Registry and DynamicSupervisor with Horde for automatic process distribution and failover. Add Redis as a cross-node cache layer. Implement push notifications for mobile. Partition the messages table by time for query performance at scale.

## Prerequisites

Phase 2 complete and all acceptance criteria met.

## Dependencies Added

```elixir
# Add to mix.exs deps
{:horde, "~> 0.9"},
{:libcluster, "~> 3.4"},
{:redix, "~> 1.5"},
{:pigeon, "~> 2.0"},         # Push notifications (FCM/APNs)
{:nimble_pool, "~> 1.1"},    # Connection pooling for Redix
```

## Step 1: libcluster — Node Discovery

### 1.1 Configuration

```elixir
# config/dev.exs — Gossip for local multi-node dev
config :libcluster,
  topologies: [
    gossip: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        multicast_ttl: 1
      ]
    ]
  ]

# config/runtime.exs — Kubernetes DNS for production
if config_env() == :prod do
  config :libcluster,
    topologies: [
      k8s_dns: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: System.get_env("K8S_SERVICE_NAME") || "slackex-headless",
          application_name: "slackex",
          polling_interval: 5_000
        ]
      ]
    ]
end

# config/test.exs — No clustering in tests (use LocalCluster for explicit tests)
config :libcluster, topologies: []
```

### 1.2 Node Listener

Monitors node connections/disconnections for logging and Horde membership sync:

```elixir
defmodule Slackex.NodeListener do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node connected: #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("Node disconnected: #{node}")
    {:noreply, state}
  end
end
```

## Step 2: Horde — Distributed Process Management

### 2.1 Replace Registry with Horde.Registry

```elixir
defmodule Slackex.Messaging.ChannelRegistry do
  @moduledoc """
  Distributed process registry using Horde.
  Guarantees at most one ChannelServer process per channel across the cluster.
  Uses delta-CRDTs for eventually consistent membership.
  """

  use Horde.Registry

  def start_link(_opts) do
    Horde.Registry.start_link(__MODULE__,
      name: __MODULE__,
      keys: :unique,
      members: :auto  # Auto-discover via libcluster
    )
  end

  def init(init_arg) do
    [members: members()]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end

  defp members do
    [Node.self() | Node.list()]
    |> Enum.map(fn node -> {__MODULE__, node} end)
  end

  @doc "Lookup a channel process across the cluster."
  def lookup(channel_id) do
    case Horde.Registry.lookup(__MODULE__, channel_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc "Via tuple for GenServer name registration."
  def via(channel_id) do
    {:via, Horde.Registry, {__MODULE__, channel_id}}
  end
end
```

### 2.2 Replace DynamicSupervisor with Horde.DynamicSupervisor

```elixir
defmodule Slackex.Messaging.ChannelSupervisor do
  @moduledoc """
  Distributed dynamic supervisor using Horde.
  Automatically redistributes processes when nodes join/leave.
  """

  use Horde.DynamicSupervisor

  def start_link(_opts) do
    Horde.DynamicSupervisor.start_link(__MODULE__,
      name: __MODULE__,
      strategy: :one_for_one,
      members: :auto,
      process_redistribution: :active  # Rebalance on node changes
    )
  end

  def init(init_arg) do
    [members: members()]
    |> Keyword.merge(init_arg)
    |> Horde.DynamicSupervisor.init()
  end

  defp members do
    [Node.self() | Node.list()]
    |> Enum.map(fn node -> {__MODULE__, node} end)
  end

  @doc """
  Ensure a ChannelServer is running for the given channel.
  If it exists on any node, returns its PID. Otherwise starts it.
  """
  def ensure_started(channel_id, opts \\ []) do
    case Slackex.Messaging.ChannelRegistry.lookup(channel_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        spec = {Slackex.Messaging.ChannelServer, {channel_id, opts}}

        case Horde.DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc "Count of active channel processes across the cluster."
  def count do
    Horde.DynamicSupervisor.count_children(__MODULE__)
  end
end
```

### 2.3 Update ChannelServer to Use Horde Registry

```elixir
# In Slackex.Messaging.ChannelServer, change:

# Old (Phase 2):
defp via(channel_id) do
  {:via, Registry, {Slackex.ChannelRegistry, channel_id}}
end

# New (Phase 3):
defp via(channel_id) do
  Slackex.Messaging.ChannelRegistry.via(channel_id)
end
```

### 2.4 Process Handoff on Node Down

When a node goes down, Horde automatically restarts affected processes on surviving nodes. The ChannelServer's `init/1` rehydrates from cache/DB. To minimize data loss during handoff:

```elixir
# In ChannelServer, add terminate callback to flush pending writes:

@impl true
def terminate(_reason, state) do
  # Best-effort SYNCHRONOUS flush before shutdown — do NOT use async here
  # because the process is about to die. Direct insert ensures writes persist.
  if state.pending_writes != [] do
    messages = Enum.reverse(state.pending_writes)
    Slackex.Pipeline.BatchWriter.insert_batch(messages)
  end

  :ok
end
```

## Step 3: Redis — Cross-Node Cache

### 3.1 Redis Connection Pool

```elixir
defmodule Slackex.Cache.Redis do
  @moduledoc """
  Redis connection pool and cache operations.
  Used for cross-node shared cache when ETS (local) misses.
  All commands are wrapped with rescue to gracefully degrade
  when Redis is unavailable — the system falls through to Postgres.
  """

  require Logger

  @pool_size 10
  @default_ttl :timer.hours(1)

  def child_spec(_opts) do
    children = for i <- 0..(@pool_size - 1) do
      Supervisor.child_spec(
        {Redix, {redis_url(), [name: :"redix_#{i}"]}},
        id: {Redix, i}
      )
    end

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    }
  end

  # --- Public API ---

  @doc "Get cached messages for a channel from Redis."
  def get_messages(channel_id) do
    key = "channel:#{channel_id}:messages"

    case command(["LRANGE", key, "0", "99"]) do
      {:ok, []} -> {:miss, []}
      {:ok, raw_messages} ->
        messages = Enum.map(raw_messages, &Jason.decode!/1)
        {:ok, messages}
      {:error, _} -> {:miss, []}
    end
  end

  @doc "Push a message to the channel's Redis list."
  def push_message(channel_id, message) do
    key = "channel:#{channel_id}:messages"
    encoded = Jason.encode!(message)

    pipeline([
      ["RPUSH", key, encoded],
      ["LTRIM", key, "-100", "-1"],     # Keep last 100 messages
      ["EXPIRE", key, div(@default_ttl, 1000)]
    ])
  end

  @doc "Cache a batch of messages (e.g., on backfill from DB)."
  def cache_messages(channel_id, messages) do
    key = "channel:#{channel_id}:messages"
    encoded = Enum.map(messages, &Jason.encode!/1)

    pipeline([
      ["DEL", key],
      ["RPUSH" | [key | encoded]],
      ["EXPIRE", key, div(@default_ttl, 1000)]
    ])
  end

  @doc "Store/retrieve read cursors (fast reconnection)."
  def set_read_cursor(user_id, channel_id, message_id) do
    key = "cursor:#{user_id}:#{channel_id}"
    command(["SET", key, to_string(message_id), "EX", "86400"])
  end

  def get_read_cursor(user_id, channel_id) do
    key = "cursor:#{user_id}:#{channel_id}"

    case command(["GET", key]) do
      {:ok, nil} -> :miss
      {:ok, id} -> {:ok, String.to_integer(id)}
      _ -> :miss
    end
  end

  @doc "Invalidate channel cache."
  def invalidate(channel_id) do
    command(["DEL", "channel:#{channel_id}:messages"])
  end

  # --- Private ---

  defp command(args) do
    Redix.command(random_connection(), args)
  rescue
    e ->
      Logger.warning("Redis command failed: #{inspect(e)}")
      {:error, :redis_unavailable}
  end

  defp pipeline(commands) do
    Redix.pipeline(random_connection(), commands)
  rescue
    e ->
      Logger.warning("Redis pipeline failed: #{inspect(e)}")
      {:error, :redis_unavailable}
  end

  defp random_connection do
    :"redix_#{Enum.random(0..(@pool_size - 1))}"
  end

  defp redis_url do
    System.get_env("REDIS_URL") || "redis://localhost:6379"
  end
end
```

### 3.2 Update Cache Boundary — Three-Tier Cascade

```elixir
defmodule Slackex.Cache do
  use Boundary, deps: [], exports: [Local, Redis]

  alias Slackex.Cache.{Local, Redis}

  @doc """
  Three-tier cache read:
  1. ETS (local node) — ~0.01ms
  2. Redis (cross-node) — ~0.5-2ms
  3. Returns :miss if both miss (caller falls through to DB)
  """
  def get_recent_messages(channel_id) do
    case Local.get_messages(channel_id) do
      {:ok, messages} when messages != [] ->
        {:ok, messages}

      _ ->
        case Redis.get_messages(channel_id) do
          {:ok, messages} when messages != [] ->
            # Backfill local ETS from Redis
            Enum.each(messages, &Local.put_message(channel_id, &1))
            {:ok, messages}

          _ ->
            {:miss, []}
        end
    end
  end

  @doc "Write-through: update both ETS and Redis."
  def put_message(channel_id, message) do
    Local.put_message(channel_id, message)
    Redis.push_message(channel_id, message)
  end

  @doc "Invalidate all cache tiers."
  def invalidate(channel_id) do
    Local.invalidate(channel_id)
    Redis.invalidate(channel_id)
  end
end
```

### 3.3 Update ChannelServer to Write Through Cache

```elixir
# In ChannelServer handle_call({:send_message, ...}):

# Replace:
Cache.Local.put_message(state.channel_id, message)

# With:
Cache.put_message(state.channel_id, message)
```

### 3.4 Update HistoryLoader for Three-Tier Reads

```elixir
defmodule Slackex.Search.HistoryLoader do
  alias Slackex.Cache
  alias Slackex.Chat

  def recent(channel_id, limit \\ 50) do
    case Cache.get_recent_messages(channel_id) do
      {:ok, messages} when length(messages) >= limit ->
        Enum.take(messages, -limit)

      _ ->
        # Cache miss — load from DB and backfill
        messages = Chat.list_messages(channel_id, limit: limit)
        Cache.Redis.cache_messages(channel_id, messages)
        Enum.each(messages, &Cache.Local.put_message(channel_id, &1))
        messages
    end
  end

  def before(channel_id, before_id, limit \\ 50) do
    # Older messages always come from DB (not worth caching)
    Chat.list_messages(channel_id, limit: limit, before: before_id)
  end
end
```

## Step 3.5: Read Replica Support

### 3.5.1 ReadRepo Module

```elixir
defmodule Slackex.ReadRepo do
  @moduledoc """
  Read-only Ecto Repo for routing queries to a PostgreSQL read replica.
  Falls back to the primary database if DATABASE_READ_URL is not configured.
  """
  use Ecto.Repo,
    otp_app: :slackex,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
```

### 3.5.2 Configuration

```elixir
# config/dev.exs — same DB in dev (no replica)
config :slackex, Slackex.ReadRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "slackex_dev",
  pool_size: 5

# config/test.exs
config :slackex, Slackex.ReadRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "slackex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online()

# config/runtime.exs (in prod block)
read_url = System.get_env("DATABASE_READ_URL") || database_url

config :slackex, Slackex.ReadRepo,
  url: read_url,
  pool_size: String.to_integer(System.get_env("READ_POOL_SIZE") || "10")
```

### 3.5.3 Query Routing

Read-only queries route to the replica. Writes and authorization checks stay on primary.

| Query | Repo | Reason |
|-------|------|--------|
| `Chat.list_messages/2` | ReadRepo | Historical read, tolerates replication lag |
| `Chat.list_user_channels/1` | ReadRepo | Channel list doesn't change often |
| `Chat.list_public_channels/0` | ReadRepo | Read-only listing |
| `Chat.unread_count/2` | ReadRepo | Read-only count |
| `Search.MessageSearch.*` | ReadRepo | All search is read-only |
| `Chat.get_role/2` | Primary | Authorization before writes |
| `Chat.send_message/3` | Primary | Write operation |
| `Chat.create_channel/2` | Primary | Write operation |
| `Chat.mark_as_read/2` | Primary | Write (upsert) |
| `Chat.join_channel/2` | Primary | Write |

Usage in context modules:

```elixir
# Read-only queries use ReadRepo:
def list_messages(channel_id, opts \\ []) do
  # ... query building ...
  |> Slackex.ReadRepo.all()
end

# Write operations stay on primary Repo:
def send_message(channel_id, sender_id, content) do
  # ... uses Repo.insert() as before
end
```

### 3.5.4 Test Support Update

```elixir
# In test/support/data_case.ex, update setup_sandbox:
def setup_sandbox(tags) do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.Repo, shared: not tags[:async])
  read_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Slackex.ReadRepo, shared: not tags[:async])

  on_exit(fn ->
    Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    Ecto.Adapters.SQL.Sandbox.stop_owner(read_pid)
  end)
end
```

## Step 4: Push Notifications (Mobile)

### 4.1 Notification Worker

```elixir
defmodule Slackex.Notifications.PushWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Slackex.Accounts
  alias Slackex.Chat

  @impl true
  def perform(%Oban.Job{args: %{
    "type" => "new_message",
    "channel_id" => channel_id,
    "sender_id" => sender_id,
    "content" => content,
    "message_id" => message_id
  }}) do
    sender = Accounts.get_user!(sender_id)
    channel = Chat.get_channel!(channel_id)

    # Get all subscribers who are NOT currently online
    offline_subscribers = get_offline_subscribers(channel_id, sender_id)

    Enum.each(offline_subscribers, fn user ->
      send_push(user, %{
        title: "##{channel.name}",
        body: "#{sender.username}: #{truncate(content, 100)}",
        data: %{
          type: "new_message",
          channel_id: channel_id,
          message_id: message_id
        }
      })
    end)

    :ok
  end

  @impl true
  def perform(%Oban.Job{args: %{
    "type" => "new_dm",
    "dm_id" => dm_id,
    "sender_id" => sender_id,
    "recipient_id" => recipient_id,
    "content" => content
  }}) do
    sender = Accounts.get_user!(sender_id)

    # Only push if recipient is offline
    unless user_online?(recipient_id) do
      recipient = Accounts.get_user!(recipient_id)

      send_push(recipient, %{
        title: sender.username,
        body: truncate(content, 100),
        data: %{type: "new_dm", dm_id: dm_id}
      })
    end

    :ok
  end

  # --- Private ---

  defp get_offline_subscribers(channel_id, exclude_sender_id) do
    channel_id
    |> Chat.list_channel_subscribers()
    |> Enum.reject(fn user ->
      user.id == exclude_sender_id or user_online?(user.id)
    end)
  end

  defp user_online?(user_id) do
    # Check Phoenix Presence across all channels
    # A user is "online" if they have any active LiveView or Channel connection
    case Slackex.Cache.Redis.command(["GET", "online:#{user_id}"]) do
      {:ok, "1"} -> true
      _ -> false
    end
  end

  defp send_push(user, notification) do
    # Dispatch to appropriate push service based on device tokens
    # This is a placeholder — actual implementation depends on Pigeon setup
    case get_device_tokens(user.id) do
      [] -> :ok
      tokens ->
        Enum.each(tokens, fn {platform, token} ->
          case platform do
            :fcm -> send_fcm(token, notification)
            :apns -> send_apns(token, notification)
          end
        end)
    end
  end

  defp send_fcm(_token, _notification), do: :ok  # Pigeon FCM integration
  defp send_apns(_token, _notification), do: :ok  # Pigeon APNs integration

  defp get_device_tokens(_user_id), do: []  # From device_tokens table

  defp truncate(string, max) do
    if String.length(string) > max do
      String.slice(string, 0, max) <> "..."
    else
      string
    end
  end
end
```

### 4.2 Enqueue Push Notifications from ChannelServer

```elixir
# In ChannelServer, after broadcasting message:

defp enqueue_push_notification(state, message) do
  case state.channel_type do
    :channel ->
      %{
        type: "new_message",
        channel_id: state.channel_id,
        sender_id: message.sender_id,
        content: message.content,
        message_id: message.id
      }
      |> Slackex.Notifications.PushWorker.new(schedule_in: 5)  # 5s delay for batching
      |> Oban.insert()

    :dm ->
      # Determine recipient from DM conversation
      %{
        type: "new_dm",
        dm_id: state.channel_id,
        sender_id: message.sender_id,
        recipient_id: get_dm_recipient(state.channel_id, message.sender_id),
        content: message.content
      }
      |> Slackex.Notifications.PushWorker.new()
      |> Oban.insert()
  end
end
```

### 4.3 Online Status Tracking via Redis

```elixir
defmodule Slackex.Notifications.OnlineTracker do
  @moduledoc """
  Tracks user online status in Redis for push notification decisions.
  Updated when LiveView/Channel connections mount/unmount.
  """

  @ttl 120  # 2 minutes — refreshed by periodic heartbeat

  def mark_online(user_id) do
    Slackex.Cache.Redis.command(["SET", "online:#{user_id}", "1", "EX", "#{@ttl}"])
  end

  def mark_offline(user_id) do
    Slackex.Cache.Redis.command(["DEL", "online:#{user_id}"])
  end

  def refresh(user_id) do
    Slackex.Cache.Redis.command(["EXPIRE", "online:#{user_id}", "#{@ttl}"])
  end

  def online?(user_id) do
    case Slackex.Cache.Redis.command(["EXISTS", "online:#{user_id}"]) do
      {:ok, 1} -> true
      _ -> false
    end
  end
end
```

## Step 4.5: Device Tokens Table

Push notifications require storing device tokens for each user's mobile devices.

### 4.5.1 Migration

```elixir
defmodule Slackex.Repo.Migrations.CreateDeviceTokens do
  use Ecto.Migration

  def change do
    create table(:device_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :platform, :string, null: false, size: 10  # "fcm" | "apns"
      add :device_name, :string, size: 100

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_tokens, [:token])
    create index(:device_tokens, [:user_id])
  end
end
```

### 4.5.2 Schema

```elixir
defmodule Slackex.Notifications.DeviceToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "device_tokens" do
    belongs_to :user, Slackex.Accounts.User
    field :token, :string
    field :platform, :string
    field :device_name, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device_token, attrs) do
    device_token
    |> cast(attrs, [:user_id, :token, :platform, :device_name])
    |> validate_required([:user_id, :token, :platform])
    |> validate_inclusion(:platform, ["fcm", "apns"])
    |> unique_constraint(:token)
  end
end
```

### 4.5.3 Update PushWorker to Use Device Tokens

```elixir
# Replace the placeholder in PushWorker:
defp get_device_tokens(user_id) do
  import Ecto.Query

  Slackex.Repo.all(
    from(dt in Slackex.Notifications.DeviceToken,
      where: dt.user_id == ^user_id,
      select: {fragment("?::text", dt.platform), dt.token}
    )
  )
  |> Enum.map(fn {platform, token} -> {String.to_existing_atom(platform), token} end)
end
```

## Step 5: Message Table Partitioning

### 5.1 Migration: Convert to Partitioned Table

```elixir
defmodule Slackex.Repo.Migrations.PartitionMessagesTable do
  use Ecto.Migration

  @doc """
  Convert the messages table to range-partitioned by inserted_at.
  This is a destructive migration — run during a maintenance window.

  Strategy:
  1. Rename existing table
  2. Create partitioned table with same schema
  3. Copy data into partitioned table
  4. Drop old table
  """

  def up do
    # Step 1: Rename existing table
    execute "ALTER TABLE messages RENAME TO messages_old"

    # Step 2: Create partitioned table
    execute """
    CREATE TABLE messages (
      id BIGINT NOT NULL,
      channel_id BIGINT,
      dm_conversation_id BIGINT,
      sender_id BIGINT NOT NULL,
      content TEXT NOT NULL,
      edited_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    # Step 3: Create partitions for current and next months
    create_monthly_partitions()

    # Step 4: Create indexes on partitioned table
    execute "CREATE INDEX idx_messages_channel ON messages (channel_id, id)"
    execute "CREATE INDEX idx_messages_dm ON messages (dm_conversation_id, id)"
    execute "CREATE INDEX idx_messages_sender ON messages (sender_id)"
    execute "CREATE INDEX idx_messages_fts ON messages USING GIN (to_tsvector('english', content))"

    # Step 5: Copy data
    execute "INSERT INTO messages SELECT * FROM messages_old"

    # Step 6: Drop old table
    execute "DROP TABLE messages_old"

    # Step 7: Add foreign keys
    # NOTE: Partitioned tables in PostgreSQL require that FK references pointing
    # TO this table match the full partition key (id, inserted_at). Tables like
    # message_embeddings that reference message_id alone should NOT use FK
    # constraints — enforce referential integrity at the application level instead.
    execute """
    ALTER TABLE messages
      ADD CONSTRAINT fk_messages_sender FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE SET NULL,
      ADD CONSTRAINT fk_messages_channel FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE,
      ADD CONSTRAINT fk_messages_dm FOREIGN KEY (dm_conversation_id) REFERENCES dm_conversations(id) ON DELETE CASCADE
    """
  end

  def down do
    # Reverse: create non-partitioned table and copy back
    execute "CREATE TABLE messages_flat AS SELECT * FROM messages"
    execute "DROP TABLE messages"
    execute "ALTER TABLE messages_flat RENAME TO messages"
  end

  defp create_monthly_partitions do
    # Create partitions for past 3 months, current month, and next 3 months
    today = Date.utc_today()

    for offset <- -3..3 do
      date = Date.add(today, offset * 30)
      year = date.year
      month = date.month

      {next_year, next_month} = if month == 12, do: {year + 1, 1}, else: {year, month + 1}

      partition_name = "messages_#{year}_#{String.pad_leading("#{month}", 2, "0")}"
      from_date = "#{year}-#{String.pad_leading("#{month}", 2, "0")}-01"
      to_date = "#{next_year}-#{String.pad_leading("#{next_month}", 2, "0")}-01"

      execute """
      CREATE TABLE IF NOT EXISTS #{partition_name}
        PARTITION OF messages
        FOR VALUES FROM ('#{from_date}') TO ('#{to_date}')
      """
    end
  end
end
```

### 5.2 Partition Maintenance Worker

```elixir
defmodule Slackex.Workers.PartitionMaintenance do
  @moduledoc """
  Creates future message partitions and optionally detaches old ones.
  Runs monthly via Oban Cron.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Slackex.Repo

  @impl true
  def perform(_job) do
    ensure_future_partitions(3)  # Always have 3 months ahead
    :ok
  end

  defp ensure_future_partitions(months_ahead) do
    today = Date.utc_today()

    for offset <- 1..months_ahead do
      date = Date.add(today, offset * 30)
      year = date.year
      month = date.month

      {next_year, next_month} = if month == 12, do: {year + 1, 1}, else: {year, month + 1}

      partition_name = "messages_#{year}_#{String.pad_leading("#{month}", 2, "0")}"
      from_date = "#{year}-#{String.pad_leading("#{month}", 2, "0")}-01"
      to_date = "#{next_year}-#{String.pad_leading("#{next_month}", 2, "0")}-01"

      Repo.query("""
        CREATE TABLE IF NOT EXISTS #{partition_name}
          PARTITION OF messages
          FOR VALUES FROM ('#{from_date}') TO ('#{to_date}')
      """)
    end
  end
end
```

Add to Oban cron config:

```elixir
# config/config.exs
{Oban.Plugins.Cron, crontab: [
  {"0 * * * *", Slackex.Workers.CacheWarmer},
  {"0 0 1 * *", Slackex.Workers.PartitionMaintenance}   # Monthly
]}
```

## Step 6: Reconnection & Catch-Up

### 6.1 Catch-Up Server

```elixir
defmodule Slackex.Notifications.CatchupServer do
  @moduledoc """
  Calculates unread messages and delivers catch-up data when a user reconnects.
  """

  alias Slackex.Chat
  alias Slackex.Cache.Redis

  @max_catchup_messages 100

  @doc """
  Build catch-up payload for a reconnecting user.
  Returns per-channel unread counts and missed messages.
  """
  def build_catchup(user_id) do
    channels = Chat.list_user_channels(user_id)

    channel_updates = Enum.map(channels, fn channel ->
      unread = Chat.unread_count(user_id, channel.id)

      recent_messages = if unread > 0 and unread <= @max_catchup_messages do
        # Fetch the actual missed messages
        cursor = get_cursor(user_id, channel.id)
        Chat.list_messages_after(channel.id, cursor, limit: unread)
      else
        []
      end

      %{
        channel_id: channel.id,
        channel_name: channel.name,
        channel_slug: channel.slug,
        unread_count: unread,
        recent_messages: recent_messages
      }
    end)

    %{
      channels: channel_updates,
      timestamp: DateTime.utc_now()
    }
  end

  defp get_cursor(user_id, channel_id) do
    case Redis.get_read_cursor(user_id, channel_id) do
      {:ok, id} -> id
      :miss ->
        case Chat.get_read_cursor(user_id, channel_id) do
          nil -> 0
          cursor -> cursor.last_read_message_id
        end
    end
  end
end
```

## Step 7: Update Application Supervisor (Phase 3)

```elixir
defmodule Slackex.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database
      Slackex.Repo,
      Slackex.ReadRepo,

      # Clustering
      {Cluster.Supervisor, [
        topologies(),
        [name: Slackex.ClusterSupervisor]
      ]},
      Slackex.NodeListener,

      # PubSub (uses pg2 — distributed across BEAM cluster)
      {Phoenix.PubSub, name: Slackex.PubSub},

      # Presence
      SlackexWeb.Presence,

      # Snowflake ID generator
      Slackex.Infrastructure.Snowflake,

      # Cache
      Slackex.Cache.Local,
      Slackex.Cache.Redis,

      # Distributed channel process management (Horde)
      Slackex.Messaging.ChannelRegistry,
      Slackex.Messaging.ChannelSupervisor,

      # Async batch write tasks
      {Task.Supervisor, name: Slackex.WriteSupervisor},

      # Background jobs
      {Oban, Application.fetch_env!(:slackex, Oban)},

      # Web endpoint (must be last)
      SlackexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Slackex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp topologies do
    Application.get_env(:libcluster, :topologies, [])
  end

  @impl true
  def config_change(changed, _new, removed) do
    SlackexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

## Step 8: Kubernetes Deployment

### 8.1 Production Dockerfile

```dockerfile
# ---- Build Stage ----
FROM hexpm/elixir:1.17.0-erlang-27.0-debian-bookworm AS build

RUN apt-get update && apt-get install -y build-essential git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Cache deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# Cache assets
COPY assets assets
COPY priv priv

# Compile app
COPY lib lib
COPY config config
RUN mix assets.deploy
RUN mix compile
RUN mix release

# ---- Runtime Stage ----
FROM debian:bookworm-slim AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales curl && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=build /app/_build/prod/rel/slackex ./

# BEAM clustering requires knowing the pod IP
# Set at runtime via K8s downward API
ENV RELEASE_DISTRIBUTION=name
# RELEASE_NODE set by entrypoint

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -f http://localhost:4000/health || exit 1

CMD ["bin/slackex", "start"]
```

### 8.2 Kubernetes Manifests

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slackex
spec:
  replicas: 3
  selector:
    matchLabels:
      app: slackex
  template:
    metadata:
      labels:
        app: slackex
    spec:
      containers:
        - name: slackex
          image: slackex:latest
          ports:
            - containerPort: 4000
              name: http
            - containerPort: 4369
              name: epmd
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: RELEASE_NODE
              value: "slackex@$(POD_IP)"
            - name: K8S_SERVICE_NAME
              value: "slackex-headless"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: slackex-secrets
                  key: database-url
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: slackex-secrets
                  key: redis-url
            - name: SECRET_KEY_BASE
              valueFrom:
                secretKeyRef:
                  name: slackex-secrets
                  key: secret-key-base
          readinessProbe:
            httpGet:
              path: /health
              port: 4000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 4000
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 2000m
              memory: 2Gi
---
# Headless service for BEAM node discovery
apiVersion: v1
kind: Service
metadata:
  name: slackex-headless
spec:
  type: ClusterIP
  clusterIP: None
  selector:
    app: slackex
  ports:
    - port: 4000
      name: http
    - port: 4369
      name: epmd
---
# Regular service for load balancing
apiVersion: v1
kind: Service
metadata:
  name: slackex
spec:
  type: ClusterIP
  selector:
    app: slackex
  ports:
    - port: 80
      targetPort: 4000
---
# Ingress with sticky sessions for WebSocket
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: slackex
  annotations:
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "SLACKEX_AFFINITY"
    nginx.ingress.kubernetes.io/session-cookie-expires: "172800"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  rules:
    - host: chat.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: slackex
                port:
                  number: 80
```

### 8.3 Health Endpoint

```elixir
# In SlackexWeb.Router:
scope "/", SlackexWeb do
  pipe_through :api
  get "/health", HealthController, :check
end

# lib/slackex_web/controllers/health_controller.ex
defmodule SlackexWeb.HealthController do
  use SlackexWeb, :controller

  def check(conn, _params) do
    checks = %{
      database: check_database(),
      redis: check_redis(),
      node: Node.self(),
      connected_nodes: Node.list(),
      channel_processes: Slackex.Messaging.ChannelSupervisor.count()
    }

    status = if checks.database == :ok and checks.redis == :ok, do: 200, else: 503
    json(conn, %{status: status_text(status), checks: checks})
  end

  defp check_database do
    case Slackex.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp check_redis do
    case Slackex.Cache.Redis.command(["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> :error
    end
  end

  defp status_text(200), do: "healthy"
  defp status_text(_), do: "unhealthy"
end
```

## Step 9: Local Multi-Node Development

### 9.1 Dev Scripts

```bash
# dev/start_cluster.sh
#!/bin/bash
# Start a 3-node local BEAM cluster for development

echo "Starting node 1 on port 4000..."
PORT=4000 iex --sname slackex1 -S mix phx.server &

echo "Starting node 2 on port 4001..."
PORT=4001 iex --sname slackex2 -S mix phx.server &

echo "Starting node 3 on port 4002..."
PORT=4002 iex --sname slackex3 -S mix phx.server &

echo "Cluster started. Nodes will auto-discover via gossip."
wait
```

```elixir
# config/dev.exs — Support dynamic port
config :slackex, SlackexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: System.get_env("PORT") || 4000],
  # ... rest of config
```

## Phase 3 Acceptance Criteria

- [ ] Horde distributes ChannelServer processes across cluster nodes
- [ ] When a node goes down, affected channels restart on surviving nodes within 5 seconds
- [ ] Channel processes flush pending writes before termination
- [ ] libcluster auto-discovers nodes (gossip in dev, K8s DNS in prod)
- [ ] Redis cache serves as cross-node shared cache
- [ ] Cache cascade: ETS → Redis → PostgreSQL works correctly
- [ ] ReadRepo is configured and routes read-only queries to replica (or primary as fallback)
- [ ] Device tokens table stores FCM/APNs tokens per user
- [ ] Push notification Oban worker dispatches to FCM/APNs using stored device tokens
- [ ] Notifications only sent to offline users (online status tracked in Redis)
- [ ] Redis commands gracefully degrade when Redis is unavailable
- [ ] Messages table is partitioned by month
- [ ] Partition maintenance worker creates future partitions
- [ ] Reconnection catch-up delivers correct unread counts and missed messages
- [ ] Health endpoint reports database, Redis, and cluster status
- [ ] Kubernetes manifests deploy a 3-pod cluster with sticky WebSocket sessions
- [ ] `docker build` produces a working production release image
- [ ] Local multi-node dev cluster works via gossip strategy
- [ ] All behavioral tests from Phases 1-2 still pass
- [ ] Distributed tests (using LocalCluster) verify Horde failover
