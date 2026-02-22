defmodule Slackex.Cache.Redis do
  @moduledoc """
  Redis-backed distributed message cache.

  Supervisor managing a pool of 10 Redix connections for cross-node
  cache sharing. Provides graceful degradation when Redis is unavailable —
  all commands return `:miss` or `:error` rather than raising.

  Keys are namespaced:
    - `msgs:channel:{id}` — channel message lists (LRANGE 0 199)
    - `msgs:dm:{id}`      — DM message lists
    - `cursor:{uid}:channel:{id}` — read cursors
    - `cursor:{uid}:dm:{id}`      — DM read cursors
  """

  use Supervisor

  require Logger

  @pool_size 10
  @max_messages 200
  @message_ttl 3_600
  @cursor_ttl 86_400
  @write_timeout 100

  @type target :: {:channel, term()} | {:dm, term()}

  # ---------------------------------------------------------------------------
  # Supervisor
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    redis_url = Application.get_env(:slackex, :redis_url, "redis://localhost:6379")

    children =
      Enum.map(0..(@pool_size - 1), fn i ->
        Supervisor.child_spec(
          {Redix, {redis_url, [name: conn_name(i)]}},
          id: {Redix, i}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Fetches messages for target. Returns `{:ok, messages}` or `{:miss, []}`."
  @spec get_messages(target()) :: {:ok, [map()]} | {:miss, []}
  def get_messages(target) do
    key = redis_key(target)

    case command(["LRANGE", key, "0", "#{@max_messages - 1}"]) do
      {:ok, []} ->
        {:miss, []}

      {:ok, entries} ->
        messages = Enum.map(entries, &decode_message/1)
        {:ok, messages}

      _ ->
        {:miss, []}
    end
  end

  @doc "Appends message to target list, trims to 200, refreshes TTL to 1h."
  @spec push_message(target(), map()) :: :ok
  def push_message(target, message) do
    key = redis_key(target)
    encoded = Jason.encode!(message)

    cmds = [
      ["RPUSH", key, encoded],
      ["LTRIM", key, "-#{@max_messages}", "-1"],
      ["EXPIRE", key, "#{@message_ttl}"]
    ]

    case pipeline(cmds, @write_timeout) do
      {:error, %Redix.ConnectionError{reason: :timeout}} ->
        :telemetry.execute(
          [:slackex, :cache, :redis_write_timeout],
          %{count: 1},
          %{target: target}
        )

        Logger.warning("Redis push_message timeout for #{key}")

      {:error, reason} ->
        Logger.warning("Redis push_message error for #{key}: #{inspect(reason)}")

      _ ->
        :ok
    end

    :ok
  end

  @doc "Bulk backfills target in Redis: DEL + RPUSH all messages + EXPIRE."
  @spec cache_messages(target(), [map()]) :: :ok
  def cache_messages(_target, []), do: :ok

  def cache_messages(target, messages) do
    key = redis_key(target)
    encoded = Enum.map(messages, &Jason.encode!/1)

    cmds =
      [["DEL", key]] ++
        Enum.map(encoded, fn m -> ["RPUSH", key, m] end) ++
        [["EXPIRE", key, "#{@message_ttl}"]]

    case pipeline(cmds) do
      {:error, reason} ->
        Logger.warning("Redis cache_messages error for #{key}: #{inspect(reason)}")

      _ ->
        :ok
    end

    :ok
  end

  @doc "Deletes target message list from Redis."
  @spec invalidate(target()) :: :ok
  def invalidate(target) do
    key = redis_key(target)

    case command(["DEL", key]) do
      {:error, reason} ->
        Logger.warning("Redis invalidate error for #{key}: #{inspect(reason)}")

      _ ->
        :ok
    end

    :ok
  end

  @doc "Sets read cursor for `user_id`/`target` with 24h TTL."
  @spec set_read_cursor(term(), target(), integer()) :: :ok
  def set_read_cursor(user_id, target, message_id) do
    key = cursor_key(user_id, target)

    case command(["SET", key, "#{message_id}", "EX", "#{@cursor_ttl}"]) do
      {:error, reason} ->
        Logger.warning("Redis set_read_cursor error for #{key}: #{inspect(reason)}")

      _ ->
        :ok
    end

    :ok
  end

  @doc "Gets read cursor for `user_id`/`target`. Returns `{:ok, integer}` or `:miss`."
  @spec get_read_cursor(term(), target()) :: {:ok, integer()} | :miss
  def get_read_cursor(user_id, target) do
    key = cursor_key(user_id, target)

    case command(["GET", key]) do
      {:ok, nil} -> :miss
      {:ok, val} -> {:ok, String.to_integer(val)}
      _ -> :miss
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp redis_key({:channel, id}), do: "msgs:channel:#{id}"
  defp redis_key({:dm, id}), do: "msgs:dm:#{id}"

  defp cursor_key(user_id, {:channel, id}), do: "cursor:#{user_id}:channel:#{id}"
  defp cursor_key(user_id, {:dm, id}), do: "cursor:#{user_id}:dm:#{id}"

  defp conn_name(i), do: :"redix_#{i}"

  defp random_conn, do: conn_name(:rand.uniform(@pool_size) - 1)

  defp command(cmd, timeout \\ 5_000) do
    Redix.command(random_conn(), cmd, timeout: timeout)
  rescue
    e -> {:error, e}
  end

  defp pipeline(cmds, timeout \\ 5_000) do
    Redix.pipeline(random_conn(), cmds, timeout: timeout)
  rescue
    e -> {:error, e}
  end

  @known_string_keys ~w(id content sender_id inserted_at channel_id dm_conversation_id sender)

  defp decode_message(json_string) do
    json_string
    |> Jason.decode!()
    |> atomize_map()
  end

  defp atomize_map(map) when is_map(map) do
    Map.new(map, &convert_kv/1)
  end

  defp convert_kv({k, v}) when k in @known_string_keys do
    atom_key = String.to_existing_atom(k)
    {atom_key, convert_value(atom_key, v)}
  end

  defp convert_kv(kv), do: kv

  defp convert_value(:inserted_at, v), do: parse_datetime(v)
  defp convert_value(:sender, v) when is_map(v), do: atomize_map(v)
  defp convert_value(_key, v), do: v

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> str
    end
  end

  defp parse_datetime(other), do: other
end
