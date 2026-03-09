defmodule Slackex.Chat.Channels do
  @moduledoc "Manages channels: creation, listing, membership, and roles."

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Chat.{Channel, Message, Subscription}
  alias Slackex.ReadRepo
  alias Slackex.Repo

  @doc """
  Creates a channel and atomically subscribes the creator as owner.
  """
  def create_channel(user_id, attrs) do
    Multi.new()
    |> Multi.insert(:channel, Channel.changeset(%Channel{creator_id: user_id}, attrs))
    |> Multi.insert(:subscription, fn %{channel: channel} ->
      Subscription.changeset(%Subscription{}, %{
        user_id: user_id,
        channel_id: channel.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{channel: channel}} -> {:ok, channel}
      {:error, :channel, changeset, _} -> {:error, changeset}
      {:error, :subscription, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Returns the number of subscribers for a channel.
  """
  def count_members(channel_id) do
    from(s in Subscription, where: s.channel_id == ^channel_id, select: count())
    |> Repo.one()
  end

  @doc """
  Lists all public channels, ordered by name.

  Options:
    - `:exclude_member` — user ID whose channels should be excluded from results
  """
  def list_public_channels(opts \\ []) do
    exclude_user_id = Keyword.get(opts, :exclude_member)

    member_counts =
      from(s in Subscription,
        group_by: s.channel_id,
        select: %{channel_id: s.channel_id, count: count()}
      )

    query =
      from(c in Channel,
        where: not c.is_private,
        left_join: mc in subquery(member_counts),
        on: mc.channel_id == c.id,
        order_by: c.name,
        select: {c, coalesce(mc.count, 0)}
      )

    query
    |> maybe_exclude_member(exclude_user_id)
    |> ReadRepo.read_repo().all()
    |> Enum.map(fn {channel, member_count} ->
      Map.put(channel, :member_count, member_count)
    end)
  end

  @doc "Lists channels with message activity since the given datetime."
  def list_active_channels(opts \\ []) do
    since = Keyword.fetch!(opts, :since)

    from(c in Channel,
      where:
        c.id in subquery(
          from m in Message,
            where: m.inserted_at >= ^since,
            where: not is_nil(m.channel_id),
            select: m.channel_id,
            distinct: true
        )
    )
    |> ReadRepo.read_repo().all()
  end

  @doc """
  Lists channels that a user is subscribed to.
  """
  def list_user_channels(user_id) do
    ReadRepo.read_repo().all(
      from c in Channel,
        join: s in Subscription,
        on: s.channel_id == c.id and s.user_id == ^user_id,
        order_by: c.name
    )
  end

  @doc """
  Returns a MapSet of channel IDs the user is subscribed to.
  """
  def list_user_channel_ids(user_id) do
    from(s in Subscription, where: s.user_id == ^user_id, select: s.channel_id)
    |> ReadRepo.read_repo().all()
    |> MapSet.new()
  end

  def get_channel!(id), do: Repo.get!(Channel, id)
  def get_channel_by_slug!(slug), do: Repo.get_by!(Channel, slug: slug)

  @doc """
  Joins a public channel. Rejects private channels. Idempotent.
  """
  def join_channel(user_id, channel_id) do
    channel = get_channel!(channel_id)

    if channel.is_private do
      {:error, :unauthorized}
    else
      %Subscription{}
      |> Subscription.changeset(%{user_id: user_id, channel_id: channel_id, role: "member"})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :channel_id])
    end
  end

  @doc """
  Leaves a channel by deleting the subscription.
  """
  def leave_channel(user_id, channel_id) do
    Repo.delete_all(
      from s in Subscription,
        where: s.user_id == ^user_id and s.channel_id == ^channel_id
    )

    :ok
  end

  @doc """
  Gets the role of a user in a channel. Returns nil if not subscribed.
  """
  def get_role(user_id, channel_id) do
    Repo.one(
      from s in Subscription,
        where: s.user_id == ^user_id and s.channel_id == ^channel_id,
        select: s.role
    )
  end

  defp maybe_exclude_member(query, nil), do: query

  defp maybe_exclude_member(query, user_id) do
    from(c in query,
      left_join: s in Subscription,
      on: s.channel_id == c.id and s.user_id == ^user_id,
      where: is_nil(s.user_id)
    )
  end
end
