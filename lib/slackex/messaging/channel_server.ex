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

  alias Ecto.Adapters.SQL
  alias Slackex.Accounts
  alias Slackex.Cache
  alias Slackex.Chat
  alias Slackex.Chat.Permissions
  alias Slackex.Infrastructure.RateLimiter
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Messaging.Envelope
  alias Slackex.Notifications.PushWorker
  alias Slackex.Pipeline.BatchWriter
  alias Slackex.Repo

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
    # Required for terminate/2 to run on supervisor shutdown (graceful flush)
    Process.flag(:trap_exit, true)

    channel_type = Keyword.fetch!(opts, :channel_type)
    target = {channel_type, channel_id}

    {source, messages} =
      case Cache.get_messages(target) do
        {:ok, [_ | _] = cached} -> {:cache, cached}
        _ -> {:db, load_from_db(channel_type, channel_id)}
      end

    queue =
      messages
      |> Enum.take(@max_cached_messages)
      |> list_to_queue()

    table = if channel_type == :channel, do: "channels", else: "dm_conversations"

    %{rows: [[writer_epoch]]} =
      SQL.query!(
        Repo,
        "UPDATE #{table} SET writer_epoch = writer_epoch + 1 WHERE id = $1 RETURNING writer_epoch",
        [channel_id]
      )

    reconcile_cache(source, messages, channel_id,
      epoch: writer_epoch,
      type: channel_type,
      id: channel_id
    )

    _ = Phoenix.PubSub.subscribe(Slackex.PubSub, pubsub_topic(channel_type, channel_id))
    _ = Process.send_after(self(), :batch_flush, @batch_interval)

    {:ok,
     %{
       channel_id: channel_id,
       channel_type: channel_type,
       messages: queue,
       message_count: :queue.len(queue),
       pending_writes: [],
       in_flight: %{},
       rate_limiters: %{},
       metadata: %{},
       sender_cache: %{},
       writer_epoch: writer_epoch,
       stale: false
     }, @idle_timeout}
  end

  @impl true
  def handle_call({:send_message, sender_id, content}, _from, state) do
    if state.stale do
      {:reply, {:error, :not_writer}, state, @idle_timeout}
    else
      with :ok <- check_backpressure(state.pending_writes),
           :ok <- validate_content(content),
           :ok <- check_permission(state.channel_type, state.channel_id, sender_id),
           {:ok, new_limiters} <- update_rate_limiter(state.rate_limiters, sender_id) do
        id = Snowflake.generate()
        sanitized = HtmlSanitizeEx.strip_tags(content)
        ts_ms = Snowflake.extract_timestamp(id)
        inserted_at = DateTime.from_unix!(ts_ms * 1_000, :microsecond)

        {sender, new_sender_cache} = fetch_sender(state.sender_cache, sender_id)

        message =
          %{
            id: id,
            content: sanitized,
            sender_id: sender_id,
            inserted_at: inserted_at,
            sender: serialize_sender(sender),
            sender_username: sender.username
          }
          |> put_target_field(state.channel_type, state.channel_id)

        _ = Cache.put_message({state.channel_type, state.channel_id}, message)
        new_queue = bounded_enqueue(state.messages, message, @max_cached_messages)
        new_pending = [message | state.pending_writes]

        envelope =
          Envelope.wrap("message.new", {state.channel_type, state.channel_id}, message)

        _ =
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
            rate_limiters: new_limiters,
            sender_cache: new_sender_cache
        }

        {:reply, {:ok, message}, new_state, @idle_timeout}
      else
        {:error, reason} ->
          {:reply, {:error, reason}, state, @idle_timeout}
      end
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
        _ = BatchWriter.async_insert_batch(batch, ref, epoch_opts(state))

        %{
          state
          | pending_writes: [],
            in_flight: Map.put(state.in_flight, ref, %{messages: batch, retry_count: 0})
        }
      end

    _ = Process.send_after(self(), :batch_flush, @batch_interval)
    {:noreply, new_state, @idle_timeout}
  end

  def handle_info({:batch_result, ref, :ok}, state) do
    {entry, new_in_flight} = Map.pop(state.in_flight, ref)

    if entry do
      Enum.each(entry.messages, fn msg ->
        enqueue_push_notification(state.channel_type, state.channel_id, msg)
      end)
    end

    {:noreply, %{state | in_flight: new_in_flight}, @idle_timeout}
  end

  def handle_info({:batch_result, ref, {:error, :target_deleted}}, state) do
    Logger.warning(
      "ChannelServer #{state.channel_type}:#{state.channel_id} target deleted — shutting down"
    )

    :telemetry.execute(
      [:slackex, :channel_server, :target_deleted_shutdown],
      %{pending_count: length(state.pending_writes), in_flight_count: map_size(state.in_flight)},
      %{
        channel_id: state.channel_id,
        channel_type: state.channel_type,
        writer_epoch: state.writer_epoch
      }
    )

    {:stop, :normal,
     %{state | pending_writes: [], in_flight: Map.delete(state.in_flight, ref), stale: true}}
  end

  def handle_info({:batch_result, _ref, {:error, :epoch_stale}}, state) do
    Logger.warning(
      "ChannelServer #{state.channel_type}:#{state.channel_id} epoch stale — shutting down"
    )

    :telemetry.execute(
      [:slackex, :channel_server, :epoch_stale_shutdown],
      %{pending_count: length(state.pending_writes), in_flight_count: map_size(state.in_flight)},
      %{
        channel_id: state.channel_id,
        channel_type: state.channel_type,
        writer_epoch: state.writer_epoch
      }
    )

    {:stop, :normal, %{state | pending_writes: [], in_flight: %{}, stale: true}}
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
        _ = BatchWriter.async_insert_batch(messages, new_ref, epoch_opts(state))

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

  def handle_info({:envelope, %{event: "message.edited", payload: payload}}, state) do
    updated_queue =
      update_queued_message(state.messages, payload.id, %{
        content: payload.content,
        edited_at: payload.edited_at
      })

    {:noreply, %{state | messages: updated_queue}, @idle_timeout}
  end

  def handle_info({:envelope, %{event: "message.deleted", payload: payload}}, state) do
    updated_queue =
      update_queued_message(state.messages, payload.id, %{
        content: nil,
        deleted_at: payload.deleted_at
      })

    {:noreply, %{state | messages: updated_queue}, @idle_timeout}
  end

  def handle_info({:envelope, _}, state) do
    # Ignore other envelope events (e.g. message.new which is handled inline)
    {:noreply, state, @idle_timeout}
  end

  def handle_info(:timeout, state) do
    if state.pending_writes != [] do
      case BatchWriter.insert_batch(state.pending_writes, epoch_opts(state)) do
        {:ok, _count} ->
          :ok

        {:error, reason} ->
          Logger.error("ChannelServer: sync flush failed on idle timeout: #{inspect(reason)}")
      end
    end

    {:noreply, %{state | pending_writes: [], sender_cache: %{}, rate_limiters: %{}}, :hibernate}
  end

  @impl true
  def terminate(_reason, state) do
    if state.pending_writes != [] and not state.stale do
      try do
        case BatchWriter.insert_batch(state.pending_writes, epoch_opts(state)) do
          {:ok, count} ->
            Logger.info(
              "ChannelServer #{state.channel_type}:#{state.channel_id} flushed #{count} messages on shutdown"
            )

          {:error, :epoch_stale} ->
            Logger.warning(
              "ChannelServer #{state.channel_type}:#{state.channel_id} flush rejected: epoch stale"
            )

          {:error, reason} ->
            Logger.error(
              "ChannelServer #{state.channel_type}:#{state.channel_id} flush failed: #{inspect(reason)}"
            )
        end
      rescue
        e ->
          Logger.error(
            "ChannelServer #{state.channel_type}:#{state.channel_id} flush crashed: #{Exception.message(e)}"
          )
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp update_queued_message(queue, message_id, updates) do
    queue
    |> :queue.to_list()
    |> Enum.map(fn msg ->
      if msg.id == message_id, do: Map.merge(msg, updates), else: msg
    end)
    |> list_to_queue()
  end

  defp list_to_queue(list) do
    Enum.reduce(list, :queue.new(), fn item, q -> :queue.in(item, q) end)
  end

  defp epoch_opts(state) do
    [epoch: state.writer_epoch, type: state.channel_type, id: state.channel_id]
  end

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

  defp enqueue_push_notification(:channel, channel_id, message) do
    args = %{
      "type" => "new_message",
      "channel_id" => channel_id,
      "sender_id" => message.sender_id,
      "content" => message.content,
      "sender_username" => message.sender_username
    }

    args
    |> PushWorker.new(schedule_in: 5)
    |> Oban.insert()
  rescue
    e -> Logger.warning("Failed to enqueue push notification: #{inspect(e)}")
  end

  defp enqueue_push_notification(:dm, _dm_id, message) do
    # For DMs we need the recipient — skip if no dm_conversation_id
    case Map.get(message, :dm_conversation_id) do
      nil ->
        :ok

      _dm_id ->
        # Recipient is determined by PushWorker from the DM record
        args = %{
          "type" => "new_dm",
          "dm_conversation_id" => message.dm_conversation_id,
          "sender_id" => message.sender_id,
          "content" => message.content,
          "sender_username" => message.sender_username
        }

        args
        |> PushWorker.new()
        |> Oban.insert()
    end
  rescue
    e -> Logger.warning("Failed to enqueue DM push notification: #{inspect(e)}")
  end

  defp load_from_db(:channel, channel_id) do
    channel_id
    |> Chat.list_messages(limit: @max_cached_messages)
    |> Enum.map(&message_to_map/1)
    |> Enum.reverse()
  end

  defp load_from_db(:dm, dm_id) do
    dm_id
    |> Chat.list_dm_messages(limit: @max_cached_messages)
    |> Enum.map(&message_to_map/1)
    |> Enum.reverse()
  end

  defp message_to_map(message) do
    base = %{
      id: message.id,
      content: message.content,
      sender_id: message.sender_id,
      inserted_at: message.inserted_at,
      sender: serialize_sender(message.sender)
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

  defp serialize_sender(%{id: id, username: username} = user) do
    %{
      id: id,
      username: username,
      display_name: Map.get(user, :display_name),
      avatar_url: Map.get(user, :avatar_url)
    }
  end

  defp serialize_sender(_), do: nil

  defp fetch_sender(sender_cache, sender_id) do
    case Map.get(sender_cache, sender_id) do
      nil ->
        sender = Accounts.get_user!(sender_id)
        new_cache = Map.put(sender_cache, sender_id, sender)
        {sender, new_cache}

      cached_sender ->
        {cached_sender, sender_cache}
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

  defp reconcile_cache(:db, _messages, _channel_id, _opts), do: :ok

  defp reconcile_cache(:cache, [], _channel_id, _opts), do: :ok

  defp reconcile_cache(:cache, messages, channel_id, opts) do
    cache_ids = Enum.map(messages, & &1.id)

    %{rows: db_rows} =
      SQL.query!(Repo, "SELECT id FROM messages WHERE id = ANY($1::bigint[])", [cache_ids])

    db_ids = MapSet.new(db_rows, fn [id] -> id end)
    missing = Enum.filter(messages, fn msg -> not MapSet.member?(db_ids, msg.id) end)

    if missing == [] do
      :ok
    else
      case BatchWriter.insert_batch(missing, opts) do
        {:ok, _count} ->
          Logger.info(
            "ChannelServer crash_recovery: recovered #{length(missing)} messages for channel #{channel_id}"
          )

          :telemetry.execute(
            [:slackex, :channel_server, :crash_recovery],
            %{recovered_count: length(missing)},
            %{channel_id: channel_id}
          )

        {:error, :epoch_stale} ->
          Logger.warning(
            "ChannelServer crash_recovery: epoch stale during recovery for channel #{channel_id} — skipping"
          )

        {:error, reason} ->
          Logger.error(
            "ChannelServer crash_recovery: insert failed for channel #{channel_id}: #{inspect(reason)}"
          )
      end
    end
  end
end
