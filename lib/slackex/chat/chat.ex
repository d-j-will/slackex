defmodule Slackex.Chat do
  @moduledoc """
  The Chat context. Manages channels, messages, DM conversations, and read cursors.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Accounts.User

  alias Slackex.Chat.{
    AbuseReport,
    Channel,
    DMConversation,
    DMRateLimiter,
    DMRequest,
    Message,
    Permissions,
    ReadCursor,
    Subscription,
    UserBlock,
    UserTrustScore
  }

  alias Slackex.Infrastructure.Snowflake
  alias Slackex.ReadRepo
  alias Slackex.Repo

  # ---------------------------------------------------------------------------
  # DM safety thresholds
  # ---------------------------------------------------------------------------

  @min_account_age_hours 24
  @new_account_age_days 7
  @max_requests_per_hour 5
  @max_requests_per_day 20
  @max_pending_requests 10
  @cooldown_after_first_decline_days 7
  @cooldown_after_second_decline_days 30
  @auto_block_after_declines 3
  @auto_restrict_block_threshold 5
  @report_restrict_threshold 3
  @report_admin_flag_threshold 5

  # Default message ID when no read cursor exists (counts all messages as unread)
  @no_cursor_message_id 0

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

  defp maybe_exclude_member(query, nil), do: query

  defp maybe_exclude_member(query, user_id) do
    from(c in query,
      left_join: s in Subscription,
      on: s.channel_id == c.id and s.user_id == ^user_id,
      where: is_nil(s.user_id)
    )
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

  # ---------------------------------------------------------------------------
  # Message operations
  # ---------------------------------------------------------------------------

  @doc """
  Sends a message to a channel. Checks sender has write permission,
  sanitizes HTML, generates Snowflake ID, broadcasts via PubSub.
  """
  def send_message(channel_id, sender_id, content) do
    with role <- get_role(sender_id, channel_id),
         true <- Permissions.can?(role, :send_message) do
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

  Returns `{:ok, dm}` on success.
  Returns `{:error, :blocked}` when either user has blocked the other.
  Returns `{:error, :rate_limited}` when DM creation rate limit exceeded.
  Returns `{:error, changeset}` on validation failure.
  """
  def find_or_create_dm(user_a_id, user_b_id) do
    {lower_id, higher_id} = normalize_user_pair(user_a_id, user_b_id)
    is_self_dm = user_a_id == user_b_id

    if not is_self_dm and block_exists_between?(lower_id, higher_id) do
      {:error, :blocked}
    else
      find_or_create_dm_record(lower_id, higher_id, user_a_id, is_self_dm)
    end
  end

  defp block_exists_between?(user_a_id, user_b_id) do
    blocked?(user_a_id, user_b_id) or blocked?(user_b_id, user_a_id)
  end

  defp find_or_create_dm_record(lower_id, higher_id, initiator_id, is_self_dm) do
    case Repo.get_by(DMConversation, user_a_id: lower_id, user_b_id: higher_id) do
      nil ->
        with :ok <- check_rate_limit(initiator_id, is_self_dm) do
          %DMConversation{}
          |> DMConversation.changeset(%{user_a_id: lower_id, user_b_id: higher_id})
          |> Repo.insert()
          |> tap(fn
            {:ok, dm} -> broadcast_new_dm(dm)
            _error -> :ok
          end)
        end

      dm ->
        {:ok, dm}
    end
  end

  defp check_rate_limit(_initiator_id, true = _is_self_dm), do: :ok
  defp check_rate_limit(initiator_id, false = _is_self_dm), do: DMRateLimiter.check(initiator_id)

  defp broadcast_new_dm(dm) do
    Phoenix.PubSub.broadcast(Slackex.PubSub, "user:#{dm.user_a_id}", {:dm_conversation_new, dm})
    Phoenix.PubSub.broadcast(Slackex.PubSub, "user:#{dm.user_b_id}", {:dm_conversation_new, dm})
  end

  # ---------------------------------------------------------------------------
  # DM request operations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a DM request from sender to recipient with a preview message.

  Runs an ordered pre-flight pipeline before creating the request:
    1. Account age >= 24h hard gate
    2. Existing DM conversation bypass (returns conversation directly)
    3. Bidirectional block check
    4. dm_restricted check via user_trust_scores
    5. Cooldown check (graduated after prior declines)
    6. Shared channel gate for accounts < 7 days old
    7. Hourly request rate limit (max #{@max_requests_per_hour}/hour)
    8. Daily request rate limit (max #{@max_requests_per_day}/day)
    9. Pending request count limit (max #{@max_pending_requests} pending)
   10. Recipient DM preference gate ("anyone"/"shared_channels"/"nobody")

  After successful request creation, broadcasts `{:dm_request_new, request}`
  to the recipient's user PubSub topic.

  Self-DM requests bypass all checks and create the DM directly.

  Returns `{:ok, dm_request}` on success (new request created).
  Returns `{:ok, dm_conversation}` when an existing DM conversation is found (bypass).
  Returns `{:error, :account_too_new}` for accounts under 24 hours.
  Returns `{:error, :blocked}` when a block exists in either direction.
  Returns `{:error, :dm_restricted}` when sender trust score has dm_restricted.
  Returns `{:error, :cooldown_active}` when sender is within cooldown period after prior decline(s).
  Returns `{:error, :no_shared_channels}` for accounts under 7 days with no shared channels.
  Returns `{:error, :rate_limited}` when hourly or daily request rate limit exceeded.
  Returns `{:error, :too_many_pending}` when sender has #{@max_pending_requests}+ pending requests.
  Returns `{:error, :dm_preference_rejected}` when recipient preference blocks sender.
  """
  def create_dm_request(sender_id, sender_id, _preview_text) do
    find_or_create_dm(sender_id, sender_id)
  end

  def create_dm_request(sender_id, recipient_id, preview_text) do
    with :ok <- check_account_age(sender_id),
         :new <- check_existing_conversation(sender_id, recipient_id),
         :ok <- check_not_blocked(sender_id, recipient_id),
         :ok <- check_not_dm_restricted(sender_id),
         :ok <- check_cooldown(sender_id, recipient_id),
         :ok <- check_shared_channels_if_new(sender_id, recipient_id),
         :ok <- check_request_rate_hourly(sender_id),
         :ok <- check_request_rate_daily(sender_id),
         :ok <- check_pending_request_count(sender_id),
         :ok <- check_dm_preference(sender_id, recipient_id) do
      insert_dm_request(sender_id, recipient_id, preview_text)
      |> tap(fn
        {:ok, request} -> broadcast_dm_request_new(request, recipient_id)
        _error -> :ok
      end)
    else
      {:existing_dm, dm} -> {:ok, dm}
      error -> error
    end
  end

  defp check_account_age(sender_id) do
    cutoff = hours_ago(@min_account_age_hours)

    account_meets_age_requirement =
      Repo.exists?(
        from u in User,
          where: u.id == ^sender_id and u.inserted_at <= ^cutoff
      )

    if account_meets_age_requirement, do: :ok, else: {:error, :account_too_new}
  end

  defp check_not_blocked(sender_id, recipient_id) do
    if block_exists_between?(sender_id, recipient_id),
      do: {:error, :blocked},
      else: :ok
  end

  defp check_not_dm_restricted(sender_id) do
    restricted =
      Repo.exists?(
        from ts in UserTrustScore,
          where: ts.user_id == ^sender_id and ts.dm_restricted == true
      )

    if restricted, do: {:error, :dm_restricted}, else: :ok
  end

  defp check_shared_channels_if_new(sender_id, recipient_id) do
    cutoff = days_ago(@new_account_age_days)

    account_past_new_period =
      Repo.exists?(
        from u in User,
          where: u.id == ^sender_id and u.inserted_at <= ^cutoff
      )

    if account_past_new_period do
      :ok
    else
      if shared_channel_exists?(sender_id, recipient_id),
        do: :ok,
        else: {:error, :no_shared_channels}
    end
  end

  defp shared_channel_exists?(user_a_id, user_b_id) do
    Repo.exists?(
      from s1 in Subscription,
        join: s2 in Subscription,
        on: s1.channel_id == s2.channel_id,
        where: s1.user_id == ^user_a_id and s2.user_id == ^user_b_id
    )
  end

  defp check_request_rate_hourly(sender_id) do
    DMRateLimiter.check_request_hourly(sender_id)
  end

  defp check_request_rate_daily(sender_id) do
    DMRateLimiter.check_request_daily(sender_id)
  end

  defp check_pending_request_count(sender_id) do
    pending_count =
      Repo.one(
        from r in DMRequest,
          where: r.sender_id == ^sender_id and r.status == "pending",
          select: count()
      )

    if pending_count < @max_pending_requests, do: :ok, else: {:error, :too_many_pending}
  end

  defp check_dm_preference(sender_id, recipient_id) do
    preference =
      Repo.one(
        from u in User,
          where: u.id == ^recipient_id,
          select: u.dm_preference
      ) || "anyone"

    case preference do
      "anyone" ->
        :ok

      "shared_channels" ->
        if shared_channel_exists?(sender_id, recipient_id),
          do: :ok,
          else: {:error, :dm_preference_rejected}

      "nobody" ->
        {:error, :dm_preference_rejected}
    end
  end

  defp check_existing_conversation(sender_id, recipient_id) do
    {lower_id, higher_id} = normalize_user_pair(sender_id, recipient_id)

    case Repo.get_by(DMConversation, user_a_id: lower_id, user_b_id: higher_id) do
      nil -> :new
      dm -> {:existing_dm, dm}
    end
  end

  defp broadcast_dm_request_new(request, recipient_id) do
    Phoenix.PubSub.broadcast(Slackex.PubSub, "user:#{recipient_id}", {:dm_request_new, request})
  end

  defp insert_dm_request(sender_id, recipient_id, preview_text) do
    id = Snowflake.generate()

    %DMRequest{id: id}
    |> DMRequest.changeset(%{
      sender_id: sender_id,
      recipient_id: recipient_id,
      preview_text: preview_text,
      status: "pending"
    })
    |> Repo.insert()
  end

  @doc """
  Accepts a pending DM request. Only the request's recipient may accept.

  Atomically via Ecto.Multi:
    1. Fetches and validates the request (must exist, be pending, recipient must match)
    2. Creates or finds the DM conversation between both users
    3. Updates the request: status -> "accepted", sets dm_conversation_id and responded_at
    4. Delivers the preview_text as the first message in the new conversation

  After success, broadcasts `{:dm_request_accepted, request}` on the sender's
  user PubSub topic and `{:dm_conversation_new, dm}` on both users' topics.

  Returns `{:ok, %{request: request, dm_conversation: dm, message: message}}` on success.
  Returns `{:error, :not_found}` when the request doesn't exist, isn't pending,
  or the caller is not the recipient.
  """
  def accept_dm_request(request_id, recipient_id) do
    Multi.new()
    |> Multi.run(:request, fn _repo, _changes ->
      fetch_pending_request(request_id, recipient_id)
    end)
    |> Multi.run(:dm_conversation, fn _repo, %{request: request} ->
      find_or_insert_dm_conversation(request.sender_id, request.recipient_id)
    end)
    |> Multi.run(:accept, fn _repo, %{request: request, dm_conversation: dm} ->
      request
      |> DMRequest.changeset(%{
        status: "accepted",
        dm_conversation_id: dm.id,
        responded_at: DateTime.utc_now()
      })
      |> Repo.update()
    end)
    |> Multi.run(:message, fn _repo, %{request: request, dm_conversation: dm} ->
      id = Snowflake.generate()
      sanitized = HtmlSanitizeEx.strip_tags(request.preview_text)

      %Message{}
      |> Message.changeset(%{
        id: id,
        content: sanitized,
        sender_id: request.sender_id,
        dm_conversation_id: dm.id
      })
      |> Repo.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{accept: accepted_request, dm_conversation: dm, message: message} = _changes} ->
        broadcast_dm_request_accepted(accepted_request)
        broadcast_new_dm(dm)
        {:ok, %{request: accepted_request, dm_conversation: dm, message: message}}

      {:error, :request, :not_found, _} ->
        {:error, :not_found}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  defp fetch_pending_request(request_id, recipient_id) do
    case Repo.one(
           from r in DMRequest,
             where:
               r.id == ^request_id and
                 r.recipient_id == ^recipient_id and
                 r.status == "pending"
         ) do
      nil -> {:error, :not_found}
      request -> {:ok, request}
    end
  end

  defp find_or_insert_dm_conversation(user_a_id, user_b_id) do
    {lower_id, higher_id} = normalize_user_pair(user_a_id, user_b_id)

    case Repo.get_by(DMConversation, user_a_id: lower_id, user_b_id: higher_id) do
      nil ->
        %DMConversation{}
        |> DMConversation.changeset(%{user_a_id: lower_id, user_b_id: higher_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_a_id, :user_b_id])

      dm ->
        {:ok, dm}
    end
  end

  defp broadcast_dm_request_accepted(request) do
    Phoenix.PubSub.broadcast(
      Slackex.PubSub,
      "user:#{request.sender_id}",
      {:dm_request_accepted, request}
    )
  end

  @doc """
  Declines a pending DM request. Only the request's recipient may decline.

  Graduated enforcement based on prior declines between this sender-recipient pair:
    - Strike 1 (first decline): 7-day cooldown enforced on next request attempt
    - Strike 2 (second decline): 30-day cooldown enforced on next request attempt
    - Strike 3+ (third+ decline): auto-blocks sender via Chat.block_user

  Increments decline_count on the sender's user_trust_score (upserts if missing).
  No PubSub broadcast to sender (silent enforcement).

  Returns `{:ok, updated_request}` on success.
  Returns `{:error, :not_found}` when the request doesn't exist, isn't pending,
  or the caller is not the recipient.
  """
  def decline_dm_request(request_id, recipient_id) do
    with {:ok, request} <- fetch_pending_request(request_id, recipient_id) do
      prior_decline_count = count_prior_declines(request.sender_id, request.recipient_id)

      {:ok, updated_request} =
        request
        |> DMRequest.changeset(%{
          status: "declined",
          responded_at: DateTime.utc_now()
        })
        |> Repo.update()

      upsert_decline_count(request.sender_id)

      if prior_decline_count >= @auto_block_after_declines - 1 do
        block_user(recipient_id, request.sender_id)
      end

      {:ok, updated_request}
    end
  end

  defp count_prior_declines(sender_id, recipient_id) do
    Repo.one(
      from r in DMRequest,
        where:
          r.sender_id == ^sender_id and
            r.recipient_id == ^recipient_id and
            r.status == "declined",
        select: count()
    )
  end

  defp upsert_decline_count(user_id) do
    %UserTrustScore{user_id: user_id}
    |> UserTrustScore.changeset(%{user_id: user_id, decline_count: 1})
    |> Repo.insert(
      on_conflict: [inc: [decline_count: 1]],
      conflict_target: :user_id
    )
  end

  defp check_cooldown(sender_id, recipient_id) do
    case count_prior_declines(sender_id, recipient_id) do
      0 ->
        :ok

      decline_count ->
        last_declined_at = most_recent_decline_timestamp(sender_id, recipient_id)

        cooldown_days =
          if decline_count >= 2,
            do: @cooldown_after_second_decline_days,
            else: @cooldown_after_first_decline_days

        cooldown_expiry =
          DateTime.add(last_declined_at, cooldown_days * 24 * 3600, :second)

        if DateTime.compare(cooldown_expiry, DateTime.utc_now()) == :gt,
          do: {:error, :cooldown_active},
          else: :ok
    end
  end

  defp most_recent_decline_timestamp(sender_id, recipient_id) do
    Repo.one(
      from r in DMRequest,
        where:
          r.sender_id == ^sender_id and
            r.recipient_id == ^recipient_id and
            r.status == "declined",
        order_by: [desc: r.responded_at],
        limit: 1,
        select: r.responded_at
    )
  end

  @doc """
  Lists pending DM requests for a user, ordered by most recent first.
  Preloads the sender association for display purposes.
  """
  def list_pending_requests_for_user(user_id) do
    from(r in DMRequest,
      where: r.recipient_id == ^user_id and r.status == "pending",
      order_by: [desc: r.inserted_at],
      preload: [:sender]
    )
    |> Repo.all()
  end

  @doc """
  Sends a DM. Verifies sender is a participant. Sanitizes content. Broadcasts.
  """
  def send_dm(dm_id, sender_id, content) do
    dm = Repo.get!(DMConversation, dm_id)

    with :ok <- verify_dm_participant(dm, sender_id) do
      id = Snowflake.generate()
      sanitized = HtmlSanitizeEx.strip_tags(content)

      Multi.new()
      |> Multi.insert(
        :message,
        Message.changeset(%Message{}, %{
          id: id,
          content: sanitized,
          sender_id: sender_id,
          dm_conversation_id: dm_id
        })
      )
      |> Multi.update(:dm, Ecto.Changeset.change(dm, updated_at: DateTime.utc_now()))
      |> Repo.transaction()
      |> then(fn
        {:ok, %{message: message}} -> {:ok, Repo.preload(message, :sender)}
        {:error, :message, changeset, _} -> {:error, changeset}
        {:error, :dm, changeset, _} -> {:error, changeset}
      end)
    end
  end

  defp verify_dm_participant(dm, sender_id) do
    if sender_id in [dm.user_a_id, dm.user_b_id], do: :ok, else: {:error, :unauthorized}
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
  Returns a list of maps with :id, :other_user, :inserted_at, and :updated_at.
  Results are ordered by most recent activity first.
  """
  def list_user_dm_conversations(user_id) do
    from(d in DMConversation,
      where: d.user_a_id == ^user_id or d.user_b_id == ^user_id,
      order_by: [desc: d.updated_at],
      preload: [:user_a, :user_b]
    )
    |> Repo.all()
    |> Enum.map(fn dm ->
      other_user = if dm.user_a_id == user_id, do: dm.user_b, else: dm.user_a
      %{id: dm.id, other_user: other_user, inserted_at: dm.inserted_at, updated_at: dm.updated_at}
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
    upsert_read_cursor(user_id, :channel_id, channel_id)
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
      ) || @no_cursor_message_id

    Repo.one(
      from m in Message,
        where: m.channel_id == ^channel_id and m.id > ^cursor,
        select: count(m.id)
    ) || 0
  end

  @doc """
  Upserts the read cursor for a user/DM conversation to the latest message ID.
  """
  def mark_dm_as_read(user_id, dm_conversation_id) do
    upsert_read_cursor(user_id, :dm_conversation_id, dm_conversation_id)
  end

  defp upsert_read_cursor(user_id, target_field, target_id) do
    latest_id = latest_message_id(target_field, target_id)

    attrs =
      %{user_id: user_id, last_read_message_id: latest_id}
      |> Map.put(target_field, target_id)

    %ReadCursor{}
    |> ReadCursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:last_read_message_id, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(user_id, #{target_field}) WHERE #{target_field} IS NOT NULL"}
    )

    :ok
  end

  defp latest_message_id(target_field, target_id) do
    Repo.one(
      from m in Message,
        where: field(m, ^target_field) == ^target_id,
        select: max(m.id)
    ) || @no_cursor_message_id
  end

  @doc """
  Returns unread counts for all channels and DM conversations a user participates in.

  Uses exactly 2 queries: one for channels, one for DMs.

  Returns `%{channel_counts: %{channel_id => count}, dm_counts: %{dm_id => count}}`.
  Conversations with zero unread messages are included with count 0 (not absent).
  """
  def batch_unread_counts(user_id) do
    channel_counts = batch_channel_unread_counts(user_id)
    dm_counts = batch_dm_unread_counts(user_id)

    %{channel_counts: channel_counts, dm_counts: dm_counts}
  end

  defp batch_channel_unread_counts(user_id) do
    no_cursor = @no_cursor_message_id

    Repo.all(
      from s in Subscription,
        where: s.user_id == ^user_id,
        left_join: rc in ReadCursor,
        on: rc.user_id == ^user_id and rc.channel_id == s.channel_id,
        left_join: m in Message,
        on:
          m.channel_id == s.channel_id and
            m.id > coalesce(rc.last_read_message_id, ^no_cursor),
        group_by: s.channel_id,
        select: {s.channel_id, count(m.id)}
    )
    |> Map.new()
  end

  defp batch_dm_unread_counts(user_id) do
    no_cursor = @no_cursor_message_id

    Repo.all(
      from d in DMConversation,
        where: d.user_a_id == ^user_id or d.user_b_id == ^user_id,
        left_join: rc in ReadCursor,
        on: rc.user_id == ^user_id and rc.dm_conversation_id == d.id,
        left_join: m in Message,
        on:
          m.dm_conversation_id == d.id and
            m.id > coalesce(rc.last_read_message_id, ^no_cursor),
        group_by: d.id,
        select: {d.id, count(m.id)}
    )
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # User block operations
  # ---------------------------------------------------------------------------

  @doc """
  Blocks a user. Creates a UserBlock record from blocker to blocked.
  Returns `{:ok, block}` or `{:error, changeset}` on duplicate/validation failure.
  """
  def block_user(blocker_id, blocked_id) do
    with {:ok, block} <-
           %UserBlock{}
           |> UserBlock.changeset(%{blocker_id: blocker_id, blocked_id: blocked_id})
           |> Repo.insert() do
      upsert_block_count(blocked_id)
      {:ok, block}
    end
  end

  defp upsert_block_count(user_id) do
    {:ok, trust_score} =
      %UserTrustScore{user_id: user_id}
      |> UserTrustScore.changeset(%{user_id: user_id, block_count: 1})
      |> Repo.insert(
        on_conflict: [inc: [block_count: 1]],
        conflict_target: :user_id,
        returning: true
      )

    maybe_apply_block_restriction(trust_score)
  end

  defp maybe_apply_block_restriction(%{block_count: count, dm_restricted: false} = trust_score)
       when count >= @auto_restrict_block_threshold do
    trust_score
    |> UserTrustScore.changeset(%{
      dm_restricted: true,
      dm_restricted_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp maybe_apply_block_restriction(_trust_score), do: :ok

  @doc """
  Unblocks a user. Removes the block from blocker to blocked.
  Returns `:ok` or `{:error, :not_found}`.
  """
  def unblock_user(blocker_id, blocked_id) do
    case Repo.get_by(UserBlock, blocker_id: blocker_id, blocked_id: blocked_id) do
      nil -> {:error, :not_found}
      block -> Repo.delete(block) |> then(fn {:ok, _} -> :ok end)
    end
  end

  @doc """
  Checks if blocker has blocked the given user. Directional: only checks
  blocker -> blocked direction.
  """
  def blocked?(blocker_id, blocked_id) do
    Repo.exists?(
      from ub in UserBlock,
        where: ub.blocker_id == ^blocker_id and ub.blocked_id == ^blocked_id
    )
  end

  @doc """
  Returns a list of user IDs involved in blocks with the given user (both directions).
  Includes users the given user has blocked and users who have blocked the given user.
  Used for filtering search results.
  """
  def list_blocked_user_ids(user_id) do
    # For each block row involving this user, return the *other* user's ID:
    # - If this user is the blocker, return the blocked_id (user they blocked)
    # - If this user is the blocked, return the blocker_id (user who blocked them)
    Repo.all(
      from ub in UserBlock,
        where: ub.blocker_id == ^user_id or ub.blocked_id == ^user_id,
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            ub.blocker_id,
            ^user_id,
            ub.blocked_id,
            ub.blocker_id
          )
    )
  end

  @doc """
  Lists all blocks created by the given user.
  """
  def list_blocked_users(user_id) do
    Repo.all(
      from ub in UserBlock,
        where: ub.blocker_id == ^user_id
    )
  end

  # ---------------------------------------------------------------------------
  # Abuse report operations
  # ---------------------------------------------------------------------------

  @doc """
  Creates an abuse report against a user.

  Pre-flight checks:
    1. Reporter account age >= 7 days
    2. Reporter not dm_restricted

  After successful creation:
    - Auto-blocks reported user (reporter blocks reported, unidirectional)
    - Upserts report_count on reported user's trust score

  Returns `{:ok, abuse_report}` on success.
  Returns `{:error, :account_too_new}` for accounts under 7 days.
  Returns `{:error, :dm_restricted}` for restricted reporters.
  Returns `{:error, changeset}` on validation failure (includes duplicate open report).
  """
  def create_abuse_report(reporter_id, reported_user_id, attrs) do
    with :ok <- check_reporter_account_age(reporter_id),
         :ok <- check_not_dm_restricted(reporter_id) do
      id = Snowflake.generate()

      report_attrs =
        Map.merge(attrs, %{
          reporter_id: reporter_id,
          reported_user_id: reported_user_id,
          status: "open"
        })

      case %AbuseReport{id: id} |> AbuseReport.changeset(report_attrs) |> Repo.insert() do
        {:ok, report} ->
          # Auto-block: reporter blocks reported user. Ignore errors (already blocked).
          block_user(reporter_id, reported_user_id)
          upsert_report_count(reported_user_id)
          check_report_thresholds(reported_user_id)
          {:ok, report}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp check_reporter_account_age(reporter_id) do
    cutoff = days_ago(@new_account_age_days)

    account_meets_age_requirement =
      Repo.exists?(
        from u in User,
          where: u.id == ^reporter_id and u.inserted_at <= ^cutoff
      )

    if account_meets_age_requirement, do: :ok, else: {:error, :account_too_new}
  end

  defp upsert_report_count(user_id) do
    %UserTrustScore{user_id: user_id}
    |> UserTrustScore.changeset(%{user_id: user_id, report_count: 1})
    |> Repo.insert(
      on_conflict: [inc: [report_count: 1]],
      conflict_target: :user_id
    )
  end

  defp check_report_thresholds(reported_user_id) do
    distinct_count = count_distinct_reporters(reported_user_id)

    if distinct_count >= @report_restrict_threshold do
      maybe_apply_report_restriction(reported_user_id)
    end

    if distinct_count >= @report_admin_flag_threshold do
      maybe_apply_admin_flag(reported_user_id)
    end
  end

  defp count_distinct_reporters(reported_user_id) do
    Repo.one(
      from ar in AbuseReport,
        where: ar.reported_user_id == ^reported_user_id,
        select: count(ar.reporter_id, :distinct)
    )
  end

  defp maybe_apply_report_restriction(reported_user_id) do
    case Repo.get_by(UserTrustScore, user_id: reported_user_id) do
      %{dm_restricted: false} = trust_score ->
        trust_score
        |> UserTrustScore.changeset(%{
          dm_restricted: true,
          dm_restricted_at: DateTime.utc_now()
        })
        |> Repo.update()

      _already_restricted ->
        :ok
    end
  end

  defp maybe_apply_admin_flag(reported_user_id) do
    case Repo.get_by(UserTrustScore, user_id: reported_user_id) do
      %{admin_flagged: false} = trust_score ->
        trust_score
        |> UserTrustScore.changeset(%{
          admin_flagged: true,
          admin_flagged_at: DateTime.utc_now()
        })
        |> Repo.update()

      _already_flagged ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp normalize_user_pair(user_a_id, user_b_id) when user_a_id < user_b_id,
    do: {user_a_id, user_b_id}

  defp normalize_user_pair(user_a_id, user_b_id),
    do: {user_b_id, user_a_id}

  defp hours_ago(hours), do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
  defp days_ago(days), do: hours_ago(days * 24)
end
