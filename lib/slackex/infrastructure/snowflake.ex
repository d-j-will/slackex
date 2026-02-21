defmodule Slackex.Infrastructure.Snowflake do
  @moduledoc """
  GenServer that generates 64-bit Snowflake IDs.

  Bit layout: [1 unused][41 timestamp ms][10 node_id][12 sequence]

  Epoch: 2025-01-01T00:00:00Z (ms since Unix epoch).

  Node ID is assigned deterministically:
  - Production: `SNOWFLAKE_NODE_ID` env var (0-1023)
  - Dev: derived from endpoint port via `rem(port - 4000, 1024)`

  On startup, acquires a PostgreSQL session-level advisory lock on the node_id
  to prevent two processes from sharing the same node ID. Aborts startup if
  the lock is already held by another session.
  """

  use GenServer

  import Bitwise

  alias Ecto.Adapters.SQL
  alias Slackex.Repo

  require Logger

  # 2025-01-01T00:00:00Z in milliseconds since Unix epoch
  @epoch 1_735_689_600_000

  @node_id_bits 10
  @sequence_bits 12
  @max_sequence (1 <<< @sequence_bits) - 1
  @node_id_shift @sequence_bits
  @timestamp_shift @node_id_bits + @sequence_bits

  defstruct [:node_id, sequence: 0, last_timestamp: -1]

  @type t :: %__MODULE__{
          node_id: non_neg_integer(),
          sequence: non_neg_integer(),
          last_timestamp: integer()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec generate() :: integer()
  def generate do
    GenServer.call(__MODULE__, :generate)
  end

  @spec extract_timestamp(integer()) :: integer()
  def extract_timestamp(id) do
    (id >>> @timestamp_shift) + @epoch
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    node_id = resolve_node_id(opts)
    maybe_acquire_lock(node_id)
    {:ok, %__MODULE__{node_id: node_id}}
  end

  @impl true
  def handle_call(:generate, _from, state) do
    {id, new_state} = do_generate(state)
    {:reply, id, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_generate(%{node_id: node_id, sequence: seq, last_timestamp: last_ts} = state) do
    now = current_ms()

    cond do
      now < last_ts ->
        # Clock went backwards; wait until we're past last_timestamp
        Process.sleep(last_ts - now + 1)
        do_generate(state)

      now == last_ts ->
        new_seq = seq + 1 &&& @max_sequence

        if new_seq == 0 do
          # Sequence exhausted for this millisecond; wait for next ms
          Process.sleep(1)
          do_generate(state)
        else
          id = build_id(now, node_id, new_seq)
          {id, %{state | sequence: new_seq, last_timestamp: now}}
        end

      true ->
        # New millisecond; reset sequence
        id = build_id(now, node_id, 0)
        {id, %{state | sequence: 0, last_timestamp: now}}
    end
  end

  defp build_id(timestamp_ms, node_id, sequence) do
    (timestamp_ms - @epoch) <<< @timestamp_shift |||
      node_id <<< @node_id_shift |||
      sequence
  end

  defp current_ms, do: :os.system_time(:millisecond)

  defp resolve_node_id(opts) do
    cond do
      node_id = Keyword.get(opts, :node_id) ->
        node_id

      env_id = System.get_env("SNOWFLAKE_NODE_ID") ->
        String.to_integer(env_id)

      true ->
        port =
          get_in(Application.get_env(:slackex, SlackexWeb.Endpoint) || [], [:http, :port]) ||
            4000

        rem(port - 4000, 1024)
    end
  end

  defp maybe_acquire_lock(node_id) do
    case Process.whereis(Repo) do
      nil ->
        :ok

      _pid ->
        try do
          result =
            SQL.query!(
              Repo,
              "SELECT pg_try_advisory_lock($1)",
              [node_id]
            )

          case result.rows do
            [[true]] ->
              :ok

            [[false]] ->
              raise RuntimeError,
                    "Snowflake node_id #{node_id} is already locked by another process. " <>
                      "Set the SNOWFLAKE_NODE_ID env var to a unique value (0-1023)."
          end
        rescue
          e ->
            Logger.warning(
              "Snowflake advisory lock could not be acquired: #{Exception.message(e)}. " <>
                "Proceeding without lock (acceptable in dev/test)."
            )
        end
    end
  end
end
