defmodule Slackex.Chat do
  @moduledoc """
  The Chat context. Manages channels, messages, DM conversations, and read cursors.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Chat.{Channel, DMConversation, Message, Permissions, ReadCursor, Subscription}
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.ReadRepo
  alias Slackex.Repo

  # ---------------------------------------------------------------------------
  # Channel operations
  # ---------------------------------------------------------------------------

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
    from(c in Channel, where: not c.is_private, order_by: c.name)
    |> maybe_exclude_member(Keyword.get(opts, :exclude_member))
    |> ReadRepo.read_repo().all()
    |> Enum.map(&with_member_count/1)
  end

  defp maybe_exclude_member(query, nil), do: query

  defp maybe_exclude_member(query, user_id) do
    from(c in query,
      left_join: s in Subscription,
      on: s.channel_id == c.id and s.user_id == ^user_id,
      where: is_nil(s.user_id)
    )
  end

  defp with_member_count(channel) do
    Map.put(channel, :member_count, count_members(channel.id))
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

  # ---------------------------------------------------------------------------
  # Message operations
  # ---------------------------------------------------------------------------

  @doc """
  Sends a message to a channel. Checks sender has write permission,
  sanitizes HTML, generates Snowflake ID, broadcasts via PubSub.
  """
  def send_message(channel_id, sender_id, content) do
    role = get_role(sender_id, channel_id)

    if Permissions.can?(role, :send_message) do
      id = Snowflake.generate()
      sanitized = HtmlSanitizeEx.strip_tags(content)

      %Message{}
      |> Message.changeset(%{
        id: id,
        content: sanitized,
        sender_id: sender_id,
        channel_id: channel_id
      })
      |> Repo.insert()
      |> case do
        {:ok, message} ->
          {:ok, Repo.preload(message, :sender)}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Lists messages for a channel, paginated by Snowflake ID.

  Options:
    - `:limit` — max messages to return (default 50)
    - `:before` — Snowflake ID upper bound (exclusive), results in desc order
    - `:after` — Snowflake ID lower bound (exclusive), results in asc order
  """
  def list_messages(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before)
    after_id = Keyword.get(opts, :after)
    repo = ReadRepo.repo_for_age(before_id || after_id || :recent)

    base =
      from m in Message,
        where: m.channel_id == ^channel_id,
        limit: ^limit,
        preload: [:sender]

    query =
      cond do
        after_id ->
          base
          |> where([m], m.id > ^after_id)
          |> order_by([m], asc: m.id)

        before_id ->
          base
          |> where([m], m.id < ^before_id)
          |> order_by([m], desc: m.id)

        true ->
          order_by(base, [m], desc: m.id)
      end

    repo.all(query)
  end

  @doc """
  Lists messages for a DM conversation, paginated by Snowflake ID descending.
  Supports :limit and :before options.
  """
  def list_dm_messages(dm_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before)
    repo = ReadRepo.repo_for_age(before_id || :recent)

    query =
      from m in Message,
        where: m.dm_conversation_id == ^dm_id,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: [:sender]

    query =
      if before_id do
        where(query, [m], m.id < ^before_id)
      else
        query
      end

    repo.all(query)
  end

  # ---------------------------------------------------------------------------
  # DM operations
  # ---------------------------------------------------------------------------

  @doc """
  Gets a DM conversation by ID. Returns `{:ok, dm}` or `{:error, :not_found}`.
  """
  def get_dm(id) do
    case Repo.get(DMConversation, id) do
      nil -> {:error, :not_found}
      dm -> {:ok, dm}
    end
  end

  @doc """
  Finds or creates a DM conversation between two users. Normalizes user order.
  """
  def find_or_create_dm(user_a_id, user_b_id) do
    {a, b} = if user_a_id < user_b_id, do: {user_a_id, user_b_id}, else: {user_b_id, user_a_id}

    case Repo.get_by(DMConversation, user_a_id: a, user_b_id: b) do
      nil ->
        %DMConversation{}
        |> DMConversation.changeset(%{user_a_id: a, user_b_id: b})
        |> Repo.insert()

      dm ->
        {:ok, dm}
    end
  end

  @doc """
  Sends a DM. Verifies sender is a participant. Sanitizes content. Broadcasts.
  """
  def send_dm(dm_id, sender_id, content) do
    dm = Repo.get!(DMConversation, dm_id)

    if sender_id == dm.user_a_id or sender_id == dm.user_b_id do
      id = Snowflake.generate()
      sanitized = HtmlSanitizeEx.strip_tags(content)

      %Message{}
      |> Message.changeset(%{
        id: id,
        content: sanitized,
        sender_id: sender_id,
        dm_conversation_id: dm_id
      })
      |> Repo.insert()
      |> case do
        {:ok, message} ->
          {:ok, Repo.preload(message, :sender)}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Lists all DM conversations for a user.
  """
  def list_dms(user_id) do
    Repo.all(
      from d in DMConversation,
        where: d.user_a_id == ^user_id or d.user_b_id == ^user_id,
        order_by: [desc: d.inserted_at]
    )
  end

  @doc """
  Lists DM conversations for a user with the other participant preloaded.
  Returns a list of maps with :id, :other_user, and :inserted_at.
  Results are ordered by most recent activity first.
  """
  def list_user_dm_conversations(user_id) do
    from(d in DMConversation,
      where: d.user_a_id == ^user_id or d.user_b_id == ^user_id,
      order_by: [desc: d.inserted_at],
      preload: [:user_a, :user_b]
    )
    |> Repo.all()
    |> Enum.map(fn dm ->
      other_user = if dm.user_a_id == user_id, do: dm.user_b, else: dm.user_a
      %{id: dm.id, other_user: other_user, inserted_at: dm.inserted_at}
    end)
  end

  @doc """
  Gets a DM conversation by ID. Raises if not found.
  """
  def get_dm_conversation!(id), do: Repo.get!(DMConversation, id)

  # ---------------------------------------------------------------------------
  # Read cursor operations
  # ---------------------------------------------------------------------------

  @doc """
  Upserts the read cursor for a user/channel to the latest message ID.
  """
  def mark_as_read(user_id, channel_id) do
    latest_id =
      Repo.one(
        from m in Message,
          where: m.channel_id == ^channel_id,
          select: max(m.id)
      ) || 0

    %ReadCursor{}
    |> ReadCursor.changeset(%{
      user_id: user_id,
      channel_id: channel_id,
      last_read_message_id: latest_id
    })
    |> Repo.insert(
      on_conflict: {:replace, [:last_read_message_id, :updated_at]},
      conflict_target: [:user_id, :channel_id]
    )

    :ok
  end

  @doc """
  Counts unread messages for a user in a channel (messages after their cursor).
  """
  def unread_count(user_id, channel_id) do
    cursor =
      Repo.one(
        from r in ReadCursor,
          where: r.user_id == ^user_id and r.channel_id == ^channel_id,
          select: r.last_read_message_id
      ) || 0

    Repo.one(
      from m in Message,
        where: m.channel_id == ^channel_id and m.id > ^cursor,
        select: count(m.id)
    ) || 0
  end
end
