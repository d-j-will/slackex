defmodule Slackex.Pipeline.BatchWriter do
  @moduledoc """
  Batch insert module for writing messages to the database.

  Bypasses Ecto changesets and uses `Repo.insert_all/3` directly for
  efficiency. Message timestamps are derived from Snowflake IDs rather
  than generated at insert time.

  Async inserts are dispatched through `Slackex.WriteSupervisor` (a
  `Task.Supervisor` that must be in the application supervision tree).
  """

  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Repo

  @doc """
  Inserts a batch of message maps into the database.

  Each map must have: `id`, `content`, `sender_id`, and either
  `channel_id` or `dm_conversation_id`.

  Uses `on_conflict: :nothing` to silently skip duplicates.
  Returns `{:ok, count}` where `count` is the number of rows inserted.
  """
  @spec insert_batch([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_batch(messages) do
    entries = Enum.map(messages, &to_row/1)

    try do
      {count, _} = Repo.insert_all("messages", entries, on_conflict: :nothing)
      {:ok, count}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Dispatches an async batch insert via `Slackex.WriteSupervisor`.

  Sends `{:batch_result, caller_ref, :ok | {:error, reason}}` to the
  calling process when the batch completes.
  """
  @spec async_insert_batch([map()], reference()) :: {:ok, pid()} | {:error, term()}
  def async_insert_batch(messages, caller_ref) do
    caller = self()

    Task.Supervisor.start_child(Slackex.WriteSupervisor, fn ->
      result =
        case insert_batch(messages) do
          {:ok, _count} -> :ok
          error -> error
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
