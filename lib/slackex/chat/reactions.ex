defmodule Slackex.Chat.Reactions do
  @moduledoc "Manages message reactions (add, remove, swap, list)."

  import Ecto.Query

  alias Slackex.Chat.MessageReaction
  alias Slackex.Repo

  @doc """
  Toggles a reaction on a message. Each user may have at most one reaction
  per message. Clicking the same emoji removes it. Clicking a different
  emoji swaps the old reaction for the new one.
  Returns `{:ok, {:added, reaction}}`, `{:ok, {:removed, reaction}}`,
  or `{:ok, {:swapped, new_reaction, old_reaction}}`.
  """
  def toggle_reaction(message_id, user_id, emoji) do
    same = Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id, emoji: emoji)

    other =
      if is_nil(same), do: Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id)

    cond do
      same -> remove_reaction(same)
      other -> swap_reaction(other, message_id, user_id, emoji)
      true -> add_reaction(message_id, user_id, emoji)
    end
  end

  @doc """
  Batch-loads reactions for a list of message IDs.
  Returns `%{message_id => [%{emoji: "...", count: N, user_ids: [...]}]}`.
  """
  def list_reactions([]), do: %{}

  def list_reactions(message_ids) when is_list(message_ids) do
    from(r in MessageReaction,
      where: r.message_id in ^message_ids,
      group_by: [r.message_id, r.emoji],
      select: %{
        message_id: r.message_id,
        emoji: r.emoji,
        count: count(),
        user_ids: fragment("array_agg(?)", r.user_id)
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  defp remove_reaction(reaction) do
    case Repo.delete(reaction) do
      {:ok, deleted} -> {:ok, {:removed, deleted}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp swap_reaction(old, message_id, user_id, emoji) do
    Repo.transaction(fn ->
      Repo.delete!(old)

      %MessageReaction{}
      |> MessageReaction.changeset(%{message_id: message_id, user_id: user_id, emoji: emoji})
      |> Repo.insert!()
    end)
    |> case do
      {:ok, reaction} -> {:ok, {:swapped, reaction, old}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_reaction(message_id, user_id, emoji) do
    %MessageReaction{}
    |> MessageReaction.changeset(%{message_id: message_id, user_id: user_id, emoji: emoji})
    |> Repo.insert()
    |> case do
      {:ok, reaction} -> {:ok, {:added, reaction}}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
