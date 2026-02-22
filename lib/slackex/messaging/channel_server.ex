defmodule Slackex.Messaging.ChannelServer do
  @moduledoc """
  GenServer managing real-time state for a single channel or DM conversation.

  Buffers incoming messages in memory and flushes to the database asynchronously
  via `BatchWriter`. Maintains a bounded in-memory queue of recent messages for
  fast reads and writes through to `Cache.Local`.

  One process per active channel or DM, registered via `ChannelRegistry`.
  Hibernates after #{div(1_800_000, 60_000)} minutes of inactivity.
  """

  use GenServer

  alias Slackex.Cache.Local, as: LocalCache
  alias Slackex.Chat
  alias Slackex.Chat.Permissions
  alias Slackex.Infrastructure.RateLimiter
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Messaging.Envelope
  alias Slackex.Pipeline.BatchWriter

  require Logger

  @max_cached_messages 200
  @idle_timeout 1_800_000
  @batch_interval 2_000
  @message_rate_limit [rate: 10, per: :second]
  @max_pending_writes 1_000
  @max_flush_retries 10

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts a ChannelServer. `opts` must include `:channel_type` (`:channel` or `:dm`)."
  @spec start_link({integer(), keyword()}) :: GenServer.on_start()
  def start_link({channel_id, opts}) do
    channel_type = Keyword.fetch!(opts, :channel_type)

    GenServer.start_link(__MODULE__, {channel_id, opts},
      name: via_tuple(channel_type, channel_id)
    )
  end

  @doc "Sends a message. Returns `{:ok, message_map}` or `{:error, reason}`."
  @spec send_message(GenServer.server(), integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def send_message(server, sender_id, content) do
    GenServer.call(server, {:send_message, sender_id, content})
  end

  @doc "Returns up to `limit` recent messages from the in-memory queue (oldest first)."
  @spec get_recent_messages(GenServer.server(), pos_integer()) :: [map()]
  def get_recent_messages(server, limit \\ 50) do
    GenServer.call(server, {:get_recent_messages, limit})
  end

  @doc "Returns the via-tuple for registering or looking up a ChannelServer."
  @spec via_tuple(:channel | :dm, integer()) :: {:via, module(), {atom(), tuple()}}
  def via_tuple(channel_type, channel_id) do
    {:via, Horde.Registry, {Slackex.Messaging.ChannelRegistry, {channel_type, channel_id}}}
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({channel_id, opts}) do
    channel_type = Keyword.fetch!(opts, :channel_type)
    target = {channel_type, channel_id}

    messages =
      case LocalCache.get_messages(target) do
        {:ok, []} -> load_from_db(channel_type, channel_id)
        {:ok, cached} -> cached
      end

    queue =
      messages
      |> Enum.take(@max_cached_messages)
      |> Enum.reduce(:queue.new(), fn msg, q -> :queue.in(msg, q) end)

    Process.send_after(self(), :batch_flush, @batch_interval)

    {:ok,
     %{
       channel_id: channel_id,
       channel_type: channel_type,
       messages: queue,
       message_count: :queue.len(queue),
       pending_writes: [],
       in_flight: %{},
       rate_limiters: %{},
       metadata: %{}
     }, @idle_timeout}
  end

  @impl true
  def handle_call({:send_message, sender_id, content}, _from, state) do
    with :ok <- check_backpressure(state.pending_writes),
         :ok <- validate_content(content),
         :ok <- check_permission(state.channel_type, state.channel_id, sender_id),
         {:ok, new_limiters} <- update_rate_limiter(state.rate_limiters, sender_id) do
      id = Snowflake.generate()
      sanitized = HtmlSanitizeEx.strip_tags(content)
      ts_ms = Snowflake.extract_timestamp(id)
      inserted_at = DateTime.from_unix!(ts_ms * 1_000, :microsecond)

      message =
        %{id: id, content: sanitized, sender_id: sender_id, inserted_at: inserted_at}
        |> put_target_field(state.channel_type, state.channel_id)

      LocalCache.put_message({state.channel_type, state.channel_id}, message)
      new_queue = bounded_enqueue(state.messages, message, @max_cached_messages)
      new_pending = [message | state.pending_writes]

      envelope =
        Envelope.wrap("message.new", {state.channel_type, state.channel_id}, message)

      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        pubsub_topic(state.channel_type, state.channel_id),
        {:envelope, envelope}
      )

      new_state = %{
        state
        | messages: new_queue,
          message_count: state.message_count + 1,
          pending_writes: new_pending,
          rate_limiters: new_limiters
      }

      {:reply, {:ok, message}, new_state, @idle_timeout}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  def handle_call({:get_recent_messages, limit}, _from, state) do
    messages =
      state.messages
      |> :queue.to_list()
      |> Enum.take(-limit)

    {:reply, messages, state, @idle_timeout}
  end

  @impl true
  def handle_info(:batch_flush, state) do
    new_state =
      if state.pending_writes == [] do
        state
      else
        ref = make_ref()
        batch = state.pending_writes
        BatchWriter.async_insert_batch(batch, ref)

        %{
          state
          | pending_writes: [],
            in_flight: Map.put(state.in_flight, ref, %{messages: batch, retry_count: 0})
        }
      end

    Process.send_after(self(), :batch_flush, @batch_interval)
    {:noreply, new_state, @idle_timeout}
  end

  def handle_info({:batch_result, ref, :ok}, state) do
    {:noreply, %{state | in_flight: Map.delete(state.in_flight, ref)}, @idle_timeout}
  end

  def handle_info({:batch_result, ref, {:error, reason}}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state, @idle_timeout}

      {%{messages: messages, retry_count: count}, new_in_flight}
      when count < @max_flush_retries ->
        Logger.warning(
          "BatchWriter failed (attempt #{count + 1}/#{@max_flush_retries}): " <>
            "#{inspect(reason)}. Retrying."
        )

        new_ref = make_ref()
        BatchWriter.async_insert_batch(messages, new_ref)

        updated_in_flight =
          Map.put(new_in_flight, new_ref, %{messages: messages, retry_count: count + 1})

        {:noreply, %{state | in_flight: updated_in_flight}, @idle_timeout}

      {%{messages: messages}, new_in_flight} ->
        Logger.error(
          "BatchWriter: max retries (#{@max_flush_retries}) exceeded. " <>
            "Dropping #{length(messages)} messages for " <>
            "#{state.channel_type}:#{state.channel_id}."
        )

        :telemetry.execute(
          [:slackex, :messaging, :batch_dropped],
          %{count: length(messages)},
          %{channel_id: state.channel_id, channel_type: state.channel_type}
        )

        {:noreply, %{state | in_flight: new_in_flight}, @idle_timeout}
    end
  end

  def handle_info(:timeout, state) do
    if state.pending_writes != [] do
      case BatchWriter.insert_batch(state.pending_writes) do
        {:ok, _count} ->
          :ok

        {:error, reason} ->
          Logger.error("ChannelServer: sync flush failed on idle timeout: #{inspect(reason)}")
      end
    end

    {:noreply, %{state | pending_writes: []}, :hibernate}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_backpressure(pending_writes) do
    if length(pending_writes) >= @max_pending_writes do
      {:error, :backpressure}
    else
      :ok
    end
  end

  defp validate_content(content) do
    sanitized = HtmlSanitizeEx.strip_tags(content)

    cond do
      String.trim(sanitized) == "" -> {:error, :invalid_content}
      String.length(sanitized) > 4_000 -> {:error, :invalid_content}
      true -> :ok
    end
  end

  defp check_permission(:channel, channel_id, sender_id) do
    role = Chat.get_role(sender_id, channel_id)

    if Permissions.can?(role, :send_message) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp check_permission(:dm, dm_id, sender_id) do
    case Chat.get_dm(dm_id) do
      {:ok, dm} ->
        if sender_id == dm.user_a_id or sender_id == dm.user_b_id do
          :ok
        else
          {:error, :unauthorized}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp update_rate_limiter(rate_limiters, user_id) do
    limiter =
      Map.get_lazy(rate_limiters, user_id, fn ->
        RateLimiter.new(@message_rate_limit)
      end)

    case RateLimiter.check(limiter) do
      {:ok, updated} -> {:ok, Map.put(rate_limiters, user_id, updated)}
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp put_target_field(msg, :channel, channel_id), do: Map.put(msg, :channel_id, channel_id)
  defp put_target_field(msg, :dm, dm_id), do: Map.put(msg, :dm_conversation_id, dm_id)

  defp pubsub_topic(:channel, id), do: "channel:#{id}"
  defp pubsub_topic(:dm, id), do: "dm:#{id}"

  defp load_from_db(:channel, channel_id) do
    channel_id
    |> Chat.list_messages(limit: @max_cached_messages)
    |> Enum.map(&message_to_map/1)
  end

  defp load_from_db(:dm, dm_id) do
    dm_id
    |> Chat.list_dm_messages(limit: @max_cached_messages)
    |> Enum.map(&message_to_map/1)
  end

  defp message_to_map(message) do
    base = %{
      id: message.id,
      content: message.content,
      sender_id: message.sender_id,
      inserted_at: message.inserted_at
    }

    cond do
      not is_nil(message.channel_id) ->
        Map.put(base, :channel_id, message.channel_id)

      not is_nil(message.dm_conversation_id) ->
        Map.put(base, :dm_conversation_id, message.dm_conversation_id)

      true ->
        base
    end
  end

  defp bounded_enqueue(queue, item, max) do
    new_queue = :queue.in(item, queue)

    if :queue.len(new_queue) > max do
      {_, trimmed} = :queue.out(new_queue)
      trimmed
    else
      new_queue
    end
  end
end
