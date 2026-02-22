defmodule Slackex.ReadRepo.LagMonitor do
  @moduledoc """
  GenServer that monitors replication lag on the read replica.

  Every 5 seconds, queries `pg_last_xact_replay_timestamp()` on ReadRepo.
  If lag exceeds 5 seconds (or the timestamp is NULL on a real standby),
  sets a `:persistent_term` flag so `repo_for_age/1` falls back to the
  primary `Slackex.Repo`.

  In "no-replica mode" (ReadRepo and Repo point to the same database),
  monitoring is skipped entirely to avoid noise.

  Public API:
  - `lag_exceeded?/0` — returns boolean, backed by `:persistent_term`
  - `repo_for_age/1` — takes a Snowflake ID or `:recent`, returns the
    appropriate repo module
  """

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.ReadRepo

  @check_interval_ms 5_000
  @lag_threshold_seconds 5.0
  @recent_threshold_ms 30_000

  @lag_key :slackex_read_repo_lag_exceeded
  @no_replica_key :slackex_read_repo_no_replica

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if replication lag exceeds the threshold."
  @spec lag_exceeded?() :: boolean()
  def lag_exceeded? do
    :persistent_term.get(@lag_key, false)
  end

  @doc "Returns true when ReadRepo and Repo share the same database (no replica configured)."
  @spec no_replica?() :: boolean()
  def no_replica? do
    :persistent_term.get(@no_replica_key, true)
  end

  @doc """
  Returns the read-only repo module. In no-replica mode, returns `Slackex.Repo`
  to avoid unnecessary connection pool overhead and sandbox isolation issues.
  When a replica is configured, returns `Slackex.ReadRepo`.
  """
  @spec read_repo() :: module()
  def read_repo do
    if no_replica?(), do: Slackex.Repo, else: ReadRepo
  end

  @doc """
  Returns the repo to use for a given Snowflake ID or `:recent`.

  - `:recent` → always Primary (Slackex.Repo)
  - No replica configured → always Primary (Slackex.Repo)
  - Lag exceeded → Primary (Slackex.Repo)
  - Snowflake ID within 30s → Primary (recently written, may not be on replica)
  - Snowflake ID older than 30s → ReadRepo
  """
  @spec repo_for_age(:recent | integer()) :: module()
  def repo_for_age(:recent), do: Slackex.Repo

  def repo_for_age(snowflake_id) do
    if no_replica?() or lag_exceeded?() do
      Slackex.Repo
    else
      age_ms = System.os_time(:millisecond) - Snowflake.extract_timestamp(snowflake_id)

      if age_ms < @recent_threshold_ms do
        Slackex.Repo
      else
        ReadRepo
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    no_replica = same_database?()

    :persistent_term.put(@lag_key, false)
    :persistent_term.put(@no_replica_key, no_replica)

    unless no_replica do
      schedule_check()
    end

    {:ok, %{no_replica: no_replica}}
  end

  @impl true
  def handle_info(:check_lag, %{no_replica: true} = state) do
    {:noreply, state}
  end

  def handle_info(:check_lag, state) do
    perform_lag_check()
    schedule_check()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  def perform_lag_check do
    sql = "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::float"

    case EctoSQL.query(ReadRepo, sql, []) do
      {:ok, %{rows: [[nil]]}} ->
        # NULL means pg_last_xact_replay_timestamp() is NULL on a real standby
        # (no WAL has been replayed yet, or this is actually the primary — treat
        # as lag exceeded when we are in replica mode)
        :telemetry.execute([:slackex, :read_repo, :lag_null_standby], %{}, %{})
        :persistent_term.put(@lag_key, true)

      {:ok, %{rows: [[lag]]}} ->
        lag_float = lag * 1.0

        if lag_float > @lag_threshold_seconds do
          :telemetry.execute(
            [:slackex, :read_repo, :lag_fallback],
            %{lag_seconds: lag_float},
            %{}
          )

          :persistent_term.put(@lag_key, true)
        else
          :persistent_term.put(@lag_key, false)
        end

      {:error, reason} ->
        Logger.warning("ReadRepo lag check failed: #{inspect(reason)}")
        :persistent_term.put(@lag_key, true)
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_lag, @check_interval_ms)
  end

  defp same_database? do
    repo_config = Application.get_env(:slackex, Slackex.Repo, [])
    read_config = Application.get_env(:slackex, Slackex.ReadRepo, [])

    repo_url = Keyword.get(repo_config, :url)
    read_url = Keyword.get(read_config, :url)

    if repo_url && read_url do
      repo_url == read_url
    else
      Keyword.get(repo_config, :hostname) == Keyword.get(read_config, :hostname) &&
        Keyword.get(repo_config, :port, 5432) == Keyword.get(read_config, :port, 5432) &&
        Keyword.get(repo_config, :database) == Keyword.get(read_config, :database)
    end
  end
end
