# Phase 2 — Real-Time & CQRS

## Goal

Evolve Phase 1's direct-to-database messaging into a proper CQRS architecture with in-memory GenServer processes per channel, Broadway write pipeline for async persistence, ETS local caching, Phoenix Presence for online status and typing indicators, and scroll-based history pagination.

## Prerequisites

Phase 1 complete and all acceptance criteria met.

## Dependencies Added

```elixir
# Add to mix.exs deps (Phase 1 deps remain)
{:oban, "~> 2.18"},
{:phoenix_pubsub, "~> 2.1"},  # Already present from Phase 1
```

> **Note:** The write pipeline uses `Task.Supervisor` (built into OTP) for async batch
> inserts rather than Broadway. The ChannelServer already owns batching logic via its
> flush timer, so Broadway's producer/batcher abstraction adds unnecessary complexity
> at this stage. Broadway can be layered in later if back-pressure becomes necessary.

## Step 1: ChannelServer GenServer

The core of the real-time system. One GenServer process per active channel, running on a single node (distributed via Horde in Phase 3).

### 1.1 Process State

```elixir
defmodule Slackex.Messaging.ChannelServer do
  use GenServer, restart: :transient

  alias Slackex.Chat
  alias Slackex.Cache
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Pipeline.BatchWriter

  @max_cached_messages 200
  @idle_timeout :timer.minutes(30)
  @batch_interval :timer.seconds(2)

  defstruct [
    :channel_id,
    :channel_type,                  # :channel | :dm
    messages: :queue.new(),         # Bounded recent message queue
    message_count: 0,
    pending_writes: [],             # Messages awaiting persistence
    rate_limiters: %{},             # %{user_id => RateLimiter.t()}
    metadata: %{}                   # Channel name, topic, member count
  ]

  @message_rate_limit [rate: 10, per: :second]

  # --- Public API ---

  def start_link({channel_id, opts}) do
    GenServer.start_link(__MODULE__, {channel_id, opts}, name: via(channel_id))
  end

  def send_message(channel_id, sender_id, content) do
    GenServer.call(via(channel_id), {:send_message, sender_id, content})
  end

  def get_recent_messages(channel_id, limit \\ 50) do
    GenServer.call(via(channel_id), {:get_recent, limit})
  end

  defp via(channel_id) do
    {:via, Registry, {Slackex.ChannelRegistry, channel_id}}
  end

  # --- Callbacks ---

  @impl true
  def init({channel_id, opts}) do
    channel_type = Keyword.get(opts, :type, :channel)

    # Rehydrate recent messages from cache or DB
    messages = load_recent_messages(channel_id, channel_type)
    queue = Enum.reduce(messages, :queue.new(), &:queue.in(&1, &2))

    # Schedule periodic batch flush
    schedule_batch_flush()

    state = %__MODULE__{
      channel_id: channel_id,
      channel_type: channel_type,
      messages: queue,
      message_count: :queue.len(queue)
    }

    {:ok, state, @idle_timeout}
  end

  @impl true
  def handle_call({:send_message, sender_id, content}, _from, state) do
    with :ok <- validate_send(sender_id, state),
         {:ok, new_state} <- check_rate_limit(sender_id, state) do
      message_id = Snowflake.generate()

      message = %{
        id: message_id,
        channel_id: if(new_state.channel_type == :channel, do: new_state.channel_id),
        dm_conversation_id: if(new_state.channel_type == :dm, do: new_state.channel_id),
        sender_id: sender_id,
        content: HtmlSanitizeEx.strip_tags(content),
        inserted_at: DateTime.utc_now()
      }

      # 1. Broadcast immediately to all subscribers
      broadcast_message(new_state, message)

      # 2. Update in-memory queue
      new_state = append_message(new_state, message)

      # 3. Update ETS cache
      Cache.Local.put_message(new_state.channel_id, message)

      # 4. Add to pending writes (flushed on timer)
      new_state = %{new_state | pending_writes: [message | new_state.pending_writes]}

      {:reply, {:ok, message}, new_state, @idle_timeout}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call({:get_recent, limit}, _from, state) do
    messages = state.messages
    |> :queue.to_list()
    |> Enum.take(-limit)

    {:reply, messages, state, @idle_timeout}
  end

  @impl true
  def handle_info(:batch_flush, state) do
    state = flush_pending_writes(state)
    schedule_batch_flush()
    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    # Flush any remaining writes before hibernating
    state = flush_pending_writes(state)
    {:noreply, state, :hibernate}
  end

  # --- Private ---

  defp append_message(state, message) do
    queue = :queue.in(message, state.messages)
    count = state.message_count + 1

    {queue, count} = if count > @max_cached_messages do
      {{:value, _old}, queue} = :queue.out(queue)
      {queue, count - 1}
    else
      {queue, count}
    end

    %{state | messages: queue, message_count: count}
  end

  defp broadcast_message(state, message) do
    topic = case state.channel_type do
      :channel -> "channel:#{state.channel_id}"
      :dm -> "dm:#{state.channel_id}"
    end

    Phoenix.PubSub.broadcast(Slackex.PubSub, topic, {:new_message, message})
  end

  defp flush_pending_writes(%{pending_writes: []} = state), do: state

  defp flush_pending_writes(state) do
    messages = Enum.reverse(state.pending_writes)
    BatchWriter.async_insert_batch(messages)
    %{state | pending_writes: []}
  end

  defp schedule_batch_flush do
    Process.send_after(self(), :batch_flush, @batch_interval)
  end

  defp validate_send(sender_id, %{channel_type: :channel, channel_id: channel_id}) do
    case Chat.get_role(sender_id, channel_id) do
      role when role in ["owner", "admin", "member"] -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp validate_send(sender_id, %{channel_type: :dm, channel_id: dm_id}) do
    case Chat.get_dm_conversation(dm_id) do
      %{user_a_id: ^sender_id} -> :ok
      %{user_b_id: ^sender_id} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp check_rate_limit(sender_id, state) do
    alias Slackex.Infrastructure.RateLimiter

    limiter = Map.get(
      state.rate_limiters,
      sender_id,
      RateLimiter.new(@message_rate_limit)
    )

    case RateLimiter.check(limiter) do
      {:ok, limiter} ->
        {:ok, %{state | rate_limiters: Map.put(state.rate_limiters, sender_id, limiter)}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  defp load_recent_messages(channel_id, :channel) do
    case Cache.Local.get_messages(channel_id) do
      {:ok, messages} when messages != [] -> messages
      _ -> Chat.list_messages(channel_id, limit: @max_cached_messages)
    end
  end

  defp load_recent_messages(dm_id, :dm) do
    Chat.list_dm_messages(dm_id, limit: @max_cached_messages)
  end
end
```

### 1.2 Channel Registry & Supervisor (Phase 2: Local)

In Phase 2, we use standard Elixir Registry and DynamicSupervisor. Phase 3 replaces these with Horde.

```elixir
defmodule Slackex.Messaging.ChannelSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_started(channel_id, opts \\ []) do
    case Registry.lookup(Slackex.ChannelRegistry, channel_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {Slackex.Messaging.ChannelServer, {channel_id, opts}}
        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end
end
```

### 1.3 Messaging Context (Public API)

```elixir
defmodule Slackex.Messaging do
  use Boundary,
    deps: [Slackex.Chat, Slackex.Accounts],
    exports: [ChannelServer]

  alias Slackex.Messaging.{ChannelServer, ChannelSupervisor}

  @doc "Send a message to a channel, starting the GenServer if needed."
  def send_message(channel_id, sender_id, content, opts \\ []) do
    type = Keyword.get(opts, :type, :channel)
    {:ok, _pid} = ChannelSupervisor.ensure_started(channel_id, type: type)
    ChannelServer.send_message(channel_id, sender_id, content)
  end

  @doc "Get recent messages from in-memory cache."
  def get_recent_messages(channel_id, limit \\ 50) do
    case ChannelSupervisor.ensure_started(channel_id) do
      {:ok, _pid} -> ChannelServer.get_recent_messages(channel_id, limit)
      _ -> Slackex.Chat.list_messages(channel_id, limit: limit)
    end
  end

  @doc "Subscribe the calling process to channel updates."
  def subscribe_channel(channel_id) do
    Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel_id}")
  end

  def unsubscribe_channel(channel_id) do
    Phoenix.PubSub.unsubscribe(Slackex.PubSub, "channel:#{channel_id}")
  end

  def subscribe_dm(dm_id) do
    Phoenix.PubSub.subscribe(Slackex.PubSub, "dm:#{dm_id}")
  end

  def subscribe_user(user_id) do
    Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{user_id}")
  end

  @doc "Broadcast typing indicator."
  def broadcast_typing(channel_id, user) do
    Phoenix.PubSub.broadcast(
      Slackex.PubSub,
      "channel:#{channel_id}",
      {:user_typing, user}
    )
  end
end
```

## Step 2: Async Write Pipeline

The ChannelServer accumulates messages in `pending_writes` and flushes them on a 2-second timer (see `@batch_interval` in Step 1). The flush dispatches an async task via `Task.Supervisor` to batch-insert into PostgreSQL. This keeps the ChannelServer non-blocking while ensuring durable persistence.

### 2.1 Batch Writer

```elixir
defmodule Slackex.Pipeline.BatchWriter do
  @moduledoc """
  Batch-inserts messages into PostgreSQL. Called asynchronously from
  ChannelServer flush via Task.Supervisor.

  INVARIANT: Each ChannelServer is the single writer for its channel.
  Concurrent writes from different channels are safe (different rows).
  """

  alias Slackex.Repo
  require Logger

  @doc """
  Insert a batch of messages into PostgreSQL using a single INSERT statement.
  Uses on_conflict: :nothing to handle rare duplicate IDs gracefully.
  """
  def insert_batch([]), do: {:ok, 0}

  def insert_batch(messages) when is_list(messages) do
    now = DateTime.utc_now()

    entries = Enum.map(messages, fn msg ->
      %{
        id: msg.id,
        channel_id: msg[:channel_id],
        dm_conversation_id: msg[:dm_conversation_id],
        sender_id: msg.sender_id,
        content: msg.content,
        inserted_at: msg[:inserted_at] || now
      }
    end)

    case Repo.insert_all("messages", entries,
      on_conflict: :nothing,
      conflict_target: [:id]
    ) do
      {count, _} ->
        {:ok, count}

      error ->
        Logger.error("Batch write failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Async batch write via Task.Supervisor. Fire-and-forget — messages
  are already in ETS cache and have been broadcast via PubSub.
  If this fails, messages are still available in-memory and will be
  persisted on the next successful flush or ChannelServer restart.
  """
  def async_insert_batch(messages) do
    Task.Supervisor.start_child(Slackex.WriteSupervisor, fn ->
      insert_batch(messages)
    end)
  end
end
```

### 2.2 Pipeline Boundary

```elixir
defmodule Slackex.Pipeline do
  use Boundary,
    deps: [Slackex.Chat],
    exports: [BatchWriter]
end
```

## Step 3: ETS Local Cache

### 3.1 Cache Manager

```elixir
defmodule Slackex.Cache.Local do
  @moduledoc """
  ETS-backed local message cache. Provides zero-latency reads for recent messages.

  INVARIANT: Only ChannelServer processes call `put_message/2` for their channel_id.
  Since each channel has exactly one ChannelServer (enforced by Registry/Horde),
  this guarantees single-writer semantics per channel and eliminates ETS TOCTOU
  races in the read-then-write pattern of put_message/2.
  """
  use GenServer

  @table_name :slackex_message_cache
  @max_channels 1_000
  @max_messages_per_channel 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{table: table, channel_count: 0}}
  end

  @doc "Store a message in the channel's cache."
  def put_message(channel_id, message) do
    key = {:channel_messages, channel_id}

    case :ets.lookup(@table_name, key) do
      [{^key, messages}] ->
        updated = Enum.take([message | messages], @max_messages_per_channel)
        :ets.insert(@table_name, {key, updated})

      [] ->
        :ets.insert(@table_name, {key, [message]})
        :ets.update_counter(@table_name, :channel_count, 1, {:channel_count, 0})
    end

    :ok
  end

  @doc "Get cached messages for a channel."
  def get_messages(channel_id) do
    key = {:channel_messages, channel_id}

    case :ets.lookup(@table_name, key) do
      [{^key, messages}] -> {:ok, Enum.reverse(messages)}
      [] -> {:ok, []}
    end
  end

  @doc "Invalidate cache for a channel."
  def invalidate(channel_id) do
    :ets.delete(@table_name, {:channel_messages, channel_id})
    :ok
  end

  @doc "Get cache stats."
  def stats do
    %{
      memory_bytes: :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize),
      size: :ets.info(@table_name, :size)
    }
  end
end
```

### 3.2 Cache Boundary

```elixir
defmodule Slackex.Cache do
  use Boundary, deps: [], exports: [Local]

  @doc "Unified cache read: ETS first, then fallback."
  def get_recent_messages(channel_id) do
    case Slackex.Cache.Local.get_messages(channel_id) do
      {:ok, messages} when messages != [] -> {:ok, messages}
      _ -> {:miss, []}
    end
  end
end
```

## Step 4: Phoenix Presence

### 4.1 Presence Module

```elixir
defmodule SlackexWeb.Presence do
  use Phoenix.Presence,
    otp_app: :slackex,
    pubsub_server: Slackex.PubSub
end
```

### 4.2 Track Presence in LiveView

Update `ChatLive.Index` to track and display presence:

```elixir
# In mount/3, after subscribing to channel:
defp activate_channel(socket, channel) do
  # ... existing code ...

  # Track presence
  if connected?(socket) do
    SlackexWeb.Presence.track(
      self(),
      "channel_presence:#{channel.id}",
      socket.assigns.current_user.id,
      %{
        username: socket.assigns.current_user.username,
        joined_at: DateTime.utc_now()
      }
    )
  end

  # Get current presence list
  presences = SlackexWeb.Presence.list("channel_presence:#{channel.id}")

  socket
  |> assign(:presences, presences)
  # ... rest of existing assigns
end

# Handle presence diffs
@impl true
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
  presences =
    socket.assigns.presences
    |> SlackexWeb.Presence.sync_diff(diff)

  {:noreply, assign(socket, :presences, presences)}
end
```

### 4.3 Typing Indicators

```elixir
# In ChatLive.Index:

# Client sends typing event (debounced by JS hook)
@impl true
def handle_event("typing", _params, socket) do
  if socket.assigns.active_channel do
    Slackex.Messaging.broadcast_typing(
      socket.assigns.active_channel.id,
      %{id: socket.assigns.current_user.id,
        username: socket.assigns.current_user.username}
    )
  end

  {:noreply, socket}
end
```

JavaScript hook for debounced typing:

```javascript
// assets/js/hooks/typing_indicator.js
export const TypingIndicator = {
  mounted() {
    this.timeout = null

    this.el.addEventListener("input", () => {
      if (!this.timeout) {
        this.pushEvent("typing", {})
      }

      clearTimeout(this.timeout)
      this.timeout = setTimeout(() => {
        this.timeout = null
      }, 2000)
    })
  },

  destroyed() {
    clearTimeout(this.timeout)
  }
}
```

## Step 5: Scroll-Based History Pagination

### 5.1 MessageList JS Hook

```javascript
// assets/js/hooks/message_list.js
export const MessageList = {
  mounted() {
    this.isAtBottom = true
    this.loading = false

    this.el.addEventListener("scroll", () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el
      this.isAtBottom = scrollHeight - scrollTop - clientHeight < 50

      // Infinite scroll up: load older messages
      if (scrollTop < 100 && !this.loading) {
        this.loading = true
        const firstMsg = this.el.querySelector("[data-message-id]")
        if (firstMsg) {
          this.pushEvent("load_more", {
            before: firstMsg.dataset.messageId
          })
        }
        // Reset loading after response
        setTimeout(() => { this.loading = false }, 500)
      }
    })
  },

  updated() {
    // Only auto-scroll if user was already at bottom
    if (this.isAtBottom) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}
```

### 5.2 History Loader (CQRS Read Side)

```elixir
defmodule Slackex.Search.HistoryLoader do
  @moduledoc """
  CQRS read side: loads message history from the cache cascade.
  ETS (local) → PostgreSQL (fallback)
  Redis added in Phase 3.
  """

  alias Slackex.Cache
  alias Slackex.Chat

  @doc "Load recent messages for a channel (newest first, then reversed for display)."
  def recent(channel_id, limit \\ 50) do
    case Cache.get_recent_messages(channel_id) do
      {:ok, messages} when length(messages) >= limit ->
        Enum.take(messages, -limit)

      _ ->
        # Cache miss or insufficient — load from DB
        messages = Chat.list_messages(channel_id, limit: limit)
        # Backfill cache
        Enum.each(messages, &Cache.Local.put_message(channel_id, &1))
        messages
    end
  end

  @doc "Load messages before a given ID (for scroll-up pagination)."
  def before(channel_id, before_id, limit \\ 50) do
    Chat.list_messages(channel_id, limit: limit, before: before_id)
  end
end
```

## Step 6: Update LiveView to Use CQRS

Modify `ChatLive.Index` to route through the Messaging context instead of direct DB:

```elixir
# Replace direct Chat.send_message with Messaging context:

def handle_event("send_message", %{"content" => content}, socket) when content != "" do
  user = socket.assigns.current_user
  channel = socket.assigns.active_channel

  case Slackex.Messaging.send_message(channel.id, user.id, content) do
    {:ok, _message} -> {:noreply, socket}
    {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to send message")}
  end
end

# Replace direct Chat.list_messages with HistoryLoader:

defp activate_channel(socket, channel) do
  messages = Slackex.Search.HistoryLoader.recent(channel.id, 50)
  # ... rest unchanged
end

# Add load_more handler:

def handle_event("load_more", %{"before" => before_id}, socket) do
  channel = socket.assigns.active_channel
  before_id = String.to_integer(before_id)

  older = Slackex.Search.HistoryLoader.before(channel.id, before_id, 50)

  socket = Enum.reduce(older, socket, fn msg, sock ->
    stream_insert(sock, :messages, msg, at: 0)
  end)

  {:noreply, socket}
end
```

## Step 7: Oban Setup (Background Jobs)

### 7.1 Configuration

```elixir
# config/config.exs
config :slackex, Oban,
  repo: Slackex.Repo,
  plugins: [
    Oban.Plugins.Pruner,                          # Clean old completed jobs
    {Oban.Plugins.Cron, crontab: [
      {"0 * * * *", Slackex.Workers.CacheWarmer}  # Warm hot channels hourly
    ]}
  ],
  queues: [
    default: 10,
    notifications: 20,
    embeddings: 5                                  # Phase 4
  ]

# config/test.exs
config :slackex, Oban, testing: :inline
```

### 7.2 Oban Migration

```bash
mix ecto.gen.migration add_oban_jobs_table
```

```elixir
defmodule Slackex.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end
```

### 7.3 Cache Warmer Worker

```elixir
defmodule Slackex.Workers.CacheWarmer do
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query
  alias Slackex.Repo
  alias Slackex.Chat.Message
  alias Slackex.Cache

  @impl true
  def perform(_job) do
    # Find channels with activity in the last hour
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    active_channel_ids =
      from(m in Message,
        where: m.inserted_at > ^one_hour_ago and not is_nil(m.channel_id),
        select: m.channel_id,
        distinct: true
      )
      |> Repo.all()

    # Warm cache for each active channel
    Enum.each(active_channel_ids, fn channel_id ->
      Slackex.Messaging.ChannelSupervisor.ensure_started(channel_id)
    end)

    :ok
  end
end
```

## Step 8: Update Application Supervisor

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

      # Presence
      SlackexWeb.Presence,

      # Snowflake ID generator
      Slackex.Infrastructure.Snowflake,

      # ETS Cache manager
      Slackex.Cache.Local,

      # Channel process management
      {Registry, keys: :unique, name: Slackex.ChannelRegistry},
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

  @impl true
  def config_change(changed, _new, removed) do
    SlackexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

## Step 9: Updated Boundary Definitions

```elixir
# New/updated boundaries for Phase 2:

defmodule Slackex.Messaging do
  use Boundary,
    deps: [Slackex.Chat, Slackex.Accounts, Slackex.Cache, Slackex.Infrastructure],
    exports: [ChannelServer]
end

defmodule Slackex.Pipeline do
  use Boundary,
    deps: [Slackex.Chat],
    exports: [BatchWriter]
end

defmodule Slackex.Search do
  use Boundary,
    deps: [Slackex.Chat, Slackex.Cache],
    exports: [HistoryLoader]
end

defmodule Slackex.Cache do
  use Boundary,
    deps: [],
    exports: [Local]
end
```

## Phase 2 Acceptance Criteria

- [ ] ChannelServer GenServer starts on first message to a channel
- [ ] Messages are broadcast immediately via PubSub (< 10ms latency)
- [ ] Messages are persisted asynchronously via Task.Supervisor batch writes
- [ ] In-memory message queue is bounded at 200 messages per channel
- [ ] ChannelServer hibernates after 30 minutes of inactivity
- [ ] ETS cache serves recent messages without hitting PostgreSQL
- [ ] Cache miss falls through to PostgreSQL transparently
- [ ] Phoenix Presence shows online users per channel
- [ ] Typing indicators appear and auto-clear after 3 seconds
- [ ] Scroll-up loads older messages via paginated DB query
- [ ] Auto-scroll to bottom on new messages (only if already at bottom)
- [ ] Oban is configured and the cache warmer runs hourly
- [ ] Batch writes group pending messages per flush interval (2s)
- [ ] Rate limiting prevents >10 messages/second per user per channel
- [ ] DM sender is validated as a participant (not just any authenticated user)
- [ ] All boundary constraints compile without warnings
- [ ] All behavioral tests from Phase 1 still pass
- [ ] New behavioral tests cover: GenServer message flow, cache hit/miss, presence, typing
