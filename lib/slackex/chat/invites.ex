defmodule Slackex.Chat.Invites do
  @moduledoc """
  Invite link operations for channels.
  """

  import Ecto.Query

  alias Slackex.Chat.InviteLink
  alias Slackex.Chat.Permissions
  alias Slackex.Chat.Subscription
  alias Slackex.Repo

  @default_expires_hours 168

  @doc """
  Creates an invite link for a channel. Requires manage_channel permission (admin+).
  Options: :max_uses (integer), :expires_in_hours (default 168 = 7 days).
  """
  def create_invite_link(channel_id, user_id, opts \\ []) do
    with :ok <- authorize(user_id, channel_id, :manage_channel) do
      expires_in_hours = Keyword.get(opts, :expires_in_hours, @default_expires_hours)

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(expires_in_hours * 3600, :second)
        |> DateTime.truncate(:microsecond)

      %InviteLink{}
      |> InviteLink.changeset(%{
        channel_id: channel_id,
        created_by_id: user_id,
        max_uses: Keyword.get(opts, :max_uses),
        expires_at: expires_at
      })
      |> Repo.insert()
    end
  end

  @doc """
  Redeems an invite code. Adds the user to the channel if the invite is valid.
  Uses SELECT FOR UPDATE to prevent race conditions on use_count.
  """
  def redeem_invite(code, user_id) do
    Repo.transaction(fn ->
      invite =
        from(i in InviteLink,
          where: i.code == ^code,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if is_nil(invite), do: Repo.rollback(:not_found)

      cond do
        expired?(invite) ->
          Repo.rollback(:expired)

        max_uses_reached?(invite) ->
          Repo.rollback(:max_uses_reached)

        get_role(user_id, invite.channel_id) != nil ->
          Repo.rollback(:already_member)

        true ->
          join_and_increment(invite, user_id)
      end
    end)
  end

  @doc """
  Lists invite links for a channel with creator info.
  """
  def list_invite_links(channel_id) do
    from(i in InviteLink,
      where: i.channel_id == ^channel_id,
      order_by: [desc: i.inserted_at],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc """
  Revokes (deletes) an invite link. Requires manage_channel permission.
  """
  def revoke_invite_link(invite_id, user_id) do
    invite = Repo.get!(InviteLink, invite_id)

    with :ok <- authorize(user_id, invite.channel_id, :manage_channel) do
      Repo.delete(invite)
    end
  end

  defp authorize(user_id, channel_id, action) do
    role = get_role(user_id, channel_id)

    if Permissions.can?(role, action), do: :ok, else: {:error, :unauthorized}
  end

  defp get_role(user_id, channel_id) do
    Repo.one(
      from(s in Subscription,
        where: s.user_id == ^user_id and s.channel_id == ^channel_id,
        select: s.role
      )
    )
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp max_uses_reached?(%{max_uses: nil}), do: false
  defp max_uses_reached?(%{max_uses: max, use_count: count}), do: count >= max

  defp join_and_increment(invite, user_id) do
    %Subscription{}
    |> Subscription.changeset(%{
      user_id: user_id,
      channel_id: invite.channel_id,
      role: "member"
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :channel_id])
    |> case do
      {:ok, _sub} ->
        {1, _} =
          from(i in InviteLink, where: i.id == ^invite.id)
          |> Repo.update_all(inc: [use_count: 1])

        invite

      {:error, _changeset} ->
        Repo.rollback(:join_failed)
    end
  end
end
