defmodule Slackex.Pipeline.BatchWriter do
  @moduledoc """
  Batch insert module for writing messages to the database.

  Bypasses Ecto changesets and uses `Repo.insert_all/3` directly for
  efficiency. Message timestamps are derived from Snowflake IDs rather
  than generated at insert time.

  Async inserts are dispatched through `Slackex.WriteSupervisor` (a
  `Task.Supervisor` that must be in the application supervision tree).
  """

  alias Slackex.Chat.Message
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Repo

  require Logger

  @doc """
  Inserts a batch of message maps into the database with epoch fencing.

  `opts` must include:
    - `:epoch` — the caller's expected writer epoch (integer)
    - `:type`  — `:channel` or `:dm`
    - `:id`    — the channel or DM conversation integer ID

  The insert is wrapped in a transaction that row-locks the owning
  channel/conversation and checks `writer_epoch`. If the database epoch
  is greater than `caller_epoch`, the transaction is rolled back and
  `{:error, :epoch_stale}` is returned.

  Each message map must have: `id`, `content`, `sender_id`, and either
  `channel_id` or `dm_conversation_id`.

  Uses `on_conflict: :nothing` to silently skip duplicates.
  Returns `{:ok, count}` on success, `{:error, :epoch_stale}` if fenced,
  `{:error, reason}` for other failures.
  """
  @spec insert_batch([map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_batch(messages, opts) do
    caller_epoch = Keyword.fetch!(opts, :epoch)
    type = Keyword.fetch!(opts, :type)
    id = Keyword.fetch!(opts, :id)

    table = if type == :channel, do: "channels", else: "dm_conversations"

    Repo.transaction(fn ->
      case Repo.query!("SELECT writer_epoch FROM #{table} WHERE id = $1 FOR UPDATE", [id]) do
        %{rows: [[db_epoch]]} when db_epoch > caller_epoch ->
          Repo.rollback(:epoch_stale)

        %{rows: [[_db_epoch]]} ->
          entries = Enum.map(messages, &to_row/1)
          {count, _} = Repo.insert_all(Message, entries, on_conflict: :nothing)
          count

        %{rows: []} ->
          Repo.rollback(:target_deleted)
      end
    end)
  end

  @doc """
  Dispatches an async batch insert via `Slackex.WriteSupervisor`.

  `opts` must include `:epoch`, `:type`, and `:id` — passed through to `insert_batch/2`.

  Sends `{:batch_result, caller_ref, :ok | {:error, reason}}` to the
  calling process when the batch completes.
  """
  @spec async_insert_batch([map()], reference(), keyword()) :: {:ok, pid()} | {:error, term()}
  def async_insert_batch(messages, caller_ref, opts) do
    caller = self()

    Task.Supervisor.start_child(Slackex.WriteSupervisor, fn ->
      result =
        try do
          case insert_batch(messages, opts) do
            {:ok, _count} -> :ok
            error -> error
          end
        rescue
          e ->
            Logger.error("BatchWriter async task crashed: #{Exception.message(e)}")
            {:error, :write_failed}
        end

      send(caller, {:batch_result, caller_ref, result})
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp to_row(%{id: id} = message) do
    ts_ms = Snowflake.extract_timestamp(id)
    inserted_at = DateTime.from_unix!(ts_ms * 1000, :microsecond)

    %{
      id: id,
      content: message.content,
      sender_id: message.sender_id,
      channel_id: Map.get(message, :channel_id),
      dm_conversation_id: Map.get(message, :dm_conversation_id),
      inserted_at: inserted_at
    }
  end
end
