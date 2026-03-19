defmodule Slackex.Chat.Messages do
  @moduledoc "Manages messages: send, edit, delete, list, threads."

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Chat.{Message, Permissions}
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.ReadRepo
  alias Slackex.Repo

  @doc """
  Gets a message by ID. Returns the message or raises Ecto.NoResultsError.
  """
  def get_message!(id), do: Repo.get!(Message, id)

  @doc """
  Gets a message by ID. Returns `{:ok, message}` or `{:error, :not_found}`.
  """
  def get_message(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Edits a message's content. Only the original sender may edit.

  Returns `{:ok, message}` on success.
  Returns `{:error, :not_found}` when the message does not exist.
  Returns `{:error, :unauthorized}` when user_id does not match sender_id.
  Returns `{:error, :deleted}` when the message has already been soft-deleted.
  """
  def edit_message(message_id, user_id, new_content) do
    with {:ok, message} <- get_message(message_id),
         :ok <- check_not_deleted(message),
         :ok <- check_is_sender(message, user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      message
      |> Message.edit_changeset(%{content: new_content, edited_at: now})
      |> Repo.update()
    end
  end

  @doc """
  Soft-deletes a message by nullifying content and setting deleted_at.

  The message owner can always delete their own message (channel or DM).
  In channels, admins and owners can delete any message.
  In DMs, only the message sender can delete their own message.

  Returns `{:ok, message}` on success.
  Returns `{:error, :not_found}` when the message does not exist.
  Returns `{:error, :unauthorized}` when the user lacks permission to delete.
  """
  def delete_message(message_id, user_id, opts \\ []) do
    _ = opts

    with {:ok, message} <- get_message(message_id),
         :ok <- authorize_delete(message, user_id) do
      message
      |> Message.delete_changeset()
      |> Repo.update()
    end
  end

  @doc """
  Sends a message to a channel. Checks sender has write permission,
  generates Snowflake ID, broadcasts via PubSub.
  """
  def send_message(channel_id, sender_id, content) do
    with role <- Slackex.Chat.Channels.get_role(sender_id, channel_id),
         true <- Permissions.can?(role, :send_message) do
      id = Snowflake.generate()

      %Message{}
      |> Message.changeset(%{
        id: id,
        content: content,
        sender_id: sender_id,
        channel_id: channel_id
      })
      |> Repo.insert()
      |> then(fn
        {:ok, message} -> {:ok, Repo.preload(message, :sender)}
        {:error, changeset} -> {:error, changeset}
      end)
    else
      false -> {:error, :unauthorized}
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

  @doc """
  Lists messages in a window centered around `message_id`.

  Returns up to `half_page` messages before the target, the target itself,
  and up to `half_page` messages after it, all ordered by id ASC with
  `:sender` preloaded. Soft-deleted messages are excluded.

  Returns an empty list when the target message does not exist or is deleted.

  ## Parameters

    * `target` - `{:channel, channel_id}` or `{:dm, dm_conversation_id}`
    * `message_id` - the Snowflake ID to center the window on
    * `opts` - keyword list with `:limit` (total window size, default 50)

  ## Examples

      Chat.list_messages_around({:channel, 123}, target_id, limit: 51)
      Chat.list_messages_around({:dm, 456}, target_id)

  """
  def list_messages_around(target, message_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    half_page = div(limit, 2)

    scope_filter = scope_filter(target)

    target_query =
      from m in Message,
        where: ^scope_filter,
        where: m.id == ^message_id,
        where: is_nil(m.deleted_at)

    # If the target itself doesn't exist or is deleted, return early
    case Repo.one(target_query) do
      nil ->
        []

      _target_msg ->
        before_query =
          from m in Message,
            where: ^scope_filter,
            where: m.id < ^message_id,
            where: is_nil(m.deleted_at),
            order_by: [desc: m.id],
            limit: ^half_page

        after_query =
          from m in Message,
            where: ^scope_filter,
            where: m.id > ^message_id,
            where: is_nil(m.deleted_at),
            order_by: [asc: m.id],
            limit: ^half_page

        combined =
          from(b in subquery(before_query))
          |> union_all(^from(t in subquery(target_query)))
          |> union_all(^from(a in subquery(after_query)))

        from(m in subquery(combined), order_by: [asc: m.id], preload: [:sender])
        |> Repo.all()
    end
  end

  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc """
  Sends a reply to a parent message. Creates the reply message and
  atomically increments the parent's reply_count.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  def send_reply(channel_id, sender_id, parent_message_id, content) do
    parent = get_message!(parent_message_id)

    target_matches =
      (parent.channel_id != nil and parent.channel_id == channel_id) or
        (parent.dm_conversation_id != nil and parent.dm_conversation_id == channel_id)

    if target_matches do
      id = Snowflake.generate()

      attrs = %{
        id: id,
        content: content,
        sender_id: sender_id,
        channel_id: parent.channel_id,
        dm_conversation_id: parent.dm_conversation_id,
        parent_message_id: parent_message_id
      }

      Multi.new()
      |> Multi.insert(:reply, Message.changeset(%Message{}, attrs))
      |> Multi.update_all(
        :increment_reply_count,
        from(m in Message, where: m.id == ^parent_message_id),
        inc: [reply_count: 1]
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{reply: reply}} -> {:ok, Repo.preload(reply, :sender)}
        {:error, :reply, changeset, _} -> {:error, changeset}
      end
    else
      {:error, :invalid_parent}
    end
  end

  @doc """
  Lists replies to a parent message, ordered by insertion time ascending.
  Excludes soft-deleted replies.
  """
  def list_thread(parent_message_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Message,
      where: m.parent_message_id == ^parent_message_id,
      where: is_nil(m.deleted_at),
      order_by: [asc: m.id],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_not_deleted(%Message{deleted_at: nil}), do: :ok
  defp check_not_deleted(%Message{}), do: {:error, :deleted}

  defp check_is_sender(%Message{sender_id: sender_id}, user_id) when sender_id == user_id,
    do: :ok

  defp check_is_sender(%Message{}, _user_id), do: {:error, :unauthorized}

  defp authorize_delete(%Message{sender_id: user_id}, user_id), do: :ok

  defp authorize_delete(%Message{channel_id: channel_id} = _message, user_id)
       when not is_nil(channel_id) do
    role = Slackex.Chat.Channels.get_role(user_id, channel_id)

    if Permissions.can?(role, :delete_any_message) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp authorize_delete(%Message{}, _user_id), do: {:error, :unauthorized}

  defp scope_filter({:channel, channel_id}) do
    dynamic([m], m.channel_id == ^channel_id)
  end

  defp scope_filter({:dm, dm_conversation_id}) do
    dynamic([m], m.dm_conversation_id == ^dm_conversation_id)
  end
end
