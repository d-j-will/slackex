defmodule Slackex.Cache.Local do
  @moduledoc """
  ETS-backed in-memory message cache with LRU channel eviction.

  Stores recent messages per channel or DM conversation keyed by
  target tuples `{:channel, id}` or `{:dm, id}`. The GenServer owns
  the ETS table and handles LRU eviction. Reads and single-target
  writes go directly to ETS (public table); eviction logic runs in
  the GenServer process.

  - Max tracked targets: 1_000 (LRU eviction threshold)
  - Max messages per target: 200 (trimmed on write)
  """

  use GenServer

  @table :slackex_message_cache
  @max_channels 1_000
  @max_messages_per_channel 200

  @type target :: {:channel, term()} | {:dm, term()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Prepends `message` to `target`'s list, trims to max, evicts LRU if needed."
  @spec put_message(target(), map()) :: :ok
  def put_message(target, message) do
    GenServer.call(__MODULE__, {:put_message, target, message})
  end

  @doc "Returns messages in chronological order (oldest first)."
  @spec get_messages(target()) :: {:ok, [map()]}
  def get_messages(target) do
    messages =
      case :ets.lookup(@table, target) do
        [{^target, msgs, _ts}] -> Enum.reverse(msgs)
        [] -> []
      end

    {:ok, messages}
  end

  @doc "Updates a message in `target`'s list by id, replacing matched fields."
  @spec update_message(target(), integer(), map()) :: :ok
  def update_message(target, message_id, updates) do
    GenServer.call(__MODULE__, {:update_message, target, message_id, updates})
  end

  @doc "Removes a single message from `target`'s list by id."
  @spec remove_message(target(), integer()) :: :ok
  def remove_message(target, message_id) do
    GenServer.call(__MODULE__, {:remove_message, target, message_id})
  end

  @doc "Removes the cache entry for `target`."
  @spec invalidate(target()) :: :ok
  def invalidate(target) do
    :ets.delete(@table, target)
    :ok
  end

  @doc "Returns ETS table memory and entry count."
  @spec stats() :: %{memory_bytes: non_neg_integer(), size: non_neg_integer()}
  def stats do
    words = :ets.info(@table, :memory)
    size = :ets.info(@table, :size)
    %{memory_bytes: words * :erlang.system_info(:wordsize), size: size}
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_message, target, message}, _from, state) do
    now = System.monotonic_time(:millisecond)

    existing =
      case :ets.lookup(@table, target) do
        [{^target, msgs, _ts}] -> msgs
        [] -> []
      end

    updated = Enum.take([message | existing], @max_messages_per_channel)
    :ets.insert(@table, {target, updated, now})

    maybe_evict()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_message, target, message_id, updates}, _from, state) do
    transform_cached_messages(target, &apply_message_update(&1, message_id, updates))

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_message, target, message_id}, _from, state) do
    transform_cached_messages(target, fn msgs ->
      Enum.reject(msgs, fn msg -> msg.id == message_id end)
    end)

    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_message_update(msgs, message_id, updates) do
    Enum.map(msgs, fn msg ->
      if msg.id == message_id, do: Map.merge(msg, updates), else: msg
    end)
  end

  defp transform_cached_messages(target, transform_fn) do
    case :ets.lookup(@table, target) do
      [{^target, msgs, ts}] ->
        :ets.insert(@table, {target, transform_fn.(msgs), ts})

      [] ->
        :ok
    end
  end

  defp maybe_evict do
    if :ets.info(@table, :size) > @max_channels do
      evict_lru_entry()
    end

    :ok
  end

  defp evict_lru_entry do
    {lru_key, _ts} =
      :ets.foldl(
        fn {k, _msgs, ts}, {min_k, min_ts} ->
          if ts < min_ts, do: {k, ts}, else: {min_k, min_ts}
        end,
        {nil, :infinity},
        @table
      )

    unless is_nil(lru_key), do: :ets.delete(@table, lru_key)
    :ok
  end
end
