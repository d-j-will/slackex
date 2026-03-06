defmodule Slackex.Chat.Members do
  @moduledoc """
  Member management operations for channels.
  """

  import Ecto.Query

  alias Slackex.Chat.Permissions
  alias Slackex.Chat.Subscription
  alias Slackex.Repo

  @doc """
  Lists members of a channel with their user data and roles.
  Returns a list of maps with :user and :role keys.
  """
  def list_members(channel_id) do
    from(s in Subscription,
      where: s.channel_id == ^channel_id,
      join: u in assoc(s, :user),
      select: %{
        user: u,
        role: s.role,
        joined_at: s.inserted_at
      },
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Updates a member's role in a channel.
  Requires the actor to have manage_members permission.
  Cannot modify the channel owner.
  """
  def update_member_role(channel_id, actor_id, target_user_id, new_role) do
    with :ok <- authorize(actor_id, channel_id, :manage_members) do
      target_role = get_role(target_user_id, channel_id)

      cond do
        target_role == nil -> {:error, :not_a_member}
        target_role == "owner" -> {:error, :cannot_modify_owner}
        true -> do_update_role(channel_id, target_user_id, new_role)
      end
    end
  end

  @doc """
  Kicks a member from a channel.
  Requires the actor to have manage_members permission.
  Cannot kick the channel owner.
  """
  def kick_member(channel_id, actor_id, target_user_id) do
    with :ok <- authorize(actor_id, channel_id, :manage_members) do
      target_role = get_role(target_user_id, channel_id)

      cond do
        target_role == nil -> {:error, :not_a_member}
        target_role == "owner" -> {:error, :cannot_kick_owner}
        true -> do_kick(channel_id, target_user_id)
      end
    end
  end

  defp authorize(user_id, channel_id, action) do
    role = get_role(user_id, channel_id)

    if Permissions.can?(role, action), do: :ok, else: {:error, :unauthorized}
  end

  defp do_update_role(channel_id, user_id, new_role) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.channel_id == ^channel_id
    )
    |> Repo.update_all(set: [role: new_role])

    {:ok, new_role}
  end

  defp do_kick(channel_id, user_id) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.channel_id == ^channel_id
    )
    |> Repo.delete_all()

    :ok
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
