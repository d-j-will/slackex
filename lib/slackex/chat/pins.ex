defmodule Slackex.Chat.Pins do
  @moduledoc """
  Pin/unpin operations for channel messages.
  """

  import Ecto.Query

  alias Slackex.Chat.Permissions
  alias Slackex.Chat.PinnedMessage

  alias Slackex.Chat.Subscription
  alias Slackex.Repo

  @doc """
  Pins a message in a channel. Requires pin_message permission (admin+).
  """
  def pin_message(channel_id, user_id, message_id) do
    with :ok <- authorize(user_id, channel_id, :pin_message) do
      do_pin(channel_id, user_id, message_id)
    end
  end

  @doc """
  Unpins a message from a channel. Requires pin_message permission (admin+).
  """
  def unpin_message(channel_id, user_id, message_id) do
    with :ok <- authorize(user_id, channel_id, :pin_message) do
      case Repo.delete_all(
             from(p in PinnedMessage,
               where: p.message_id == ^message_id and p.channel_id == ^channel_id
             )
           ) do
        {0, _} -> {:error, :not_pinned}
        {1, _} -> :ok
      end
    end
  end

  @doc """
  Lists pinned messages for a channel with message content and sender info.
  """
  def list_pinned_messages(channel_id) do
    from(p in PinnedMessage,
      where: p.channel_id == ^channel_id,
      join: m in assoc(p, :message),
      join: s in assoc(m, :sender),
      preload: [message: {m, sender: s}],
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of pinned messages for a channel.
  """
  def pin_count(channel_id) do
    from(p in PinnedMessage, where: p.channel_id == ^channel_id)
    |> Repo.aggregate(:count)
  end

  defp authorize(user_id, channel_id, action) do
    role = get_role(user_id, channel_id)

    if Permissions.can?(role, action), do: :ok, else: {:error, :unauthorized}
  end

  defp do_pin(channel_id, user_id, message_id) do
    %PinnedMessage{}
    |> PinnedMessage.changeset(%{
      message_id: message_id,
      channel_id: channel_id,
      pinned_by_id: user_id
    })
    |> Repo.insert()
    |> case do
      {:ok, pin} ->
        {:ok, pin}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :message_id),
          do: {:error, :already_pinned},
          else: {:error, :insert_failed}
    end
  end

  defp get_role(user_id, channel_id) do
    Repo.one(
      from(s in Subscription,
        where: s.user_id == ^user_id and s.channel_id == ^channel_id,
        select: s.role
      )
    )
  end
end
