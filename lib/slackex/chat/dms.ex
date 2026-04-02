defmodule Slackex.Chat.DMs do
  @moduledoc "Manages DM conversations, DM requests, and DM messaging."

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Accounts.User

  alias Slackex.Chat.{
    DMConversation,
    DMRateLimiter,
    DMRequest,
    Message,
    Moderation,
    Subscription,
    UserTrustScore
  }

  alias Slackex.Infrastructure.Snowflake
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

  # ---------------------------------------------------------------------------
  # DM conversation operations
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

  @doc """
  Gets a DM conversation by ID. Raises if not found.
  """
  def get_dm_conversation!(id), do: Repo.get!(DMConversation, id)

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

  # ---------------------------------------------------------------------------
  # DM messaging
  # ---------------------------------------------------------------------------

  @doc """
  Sends a DM. Verifies sender is a participant. Broadcasts.
  """
  def send_dm(dm_id, sender_id, content) do
    dm = Repo.get!(DMConversation, dm_id)

    with :ok <- verify_dm_participant(dm, sender_id) do
      id = Snowflake.generate()

      Multi.new()
      |> Multi.insert(
        :message,
        Message.changeset(%Message{}, %{
          id: id,
          content: content,
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
         :ok <- Moderation.check_not_dm_restricted(sender_id),
         :ok <- check_cooldown(sender_id, recipient_id),
         :ok <- check_shared_channels_if_new(sender_id, recipient_id),
         :ok <- check_request_rate_hourly(sender_id),
         :ok <- check_request_rate_daily(sender_id),
         :ok <- check_pending_request_count(sender_id),
         :ok <- check_dm_preference(sender_id, recipient_id) do
      insert_dm_request(sender_id, recipient_id, preview_text)
      |> tap(fn
        {:ok, request} -> _ = broadcast_dm_request_new(request, recipient_id)
        _error -> :ok
      end)
    else
      {:existing_dm, dm} -> {:ok, dm}
      error -> error
    end
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
      preview = request.preview_text || ""

      if String.trim(preview) == "" do
        {:ok, nil}
      else
        id = Snowflake.generate()

        %Message{}
        |> Message.changeset(%{
          id: id,
          content: preview,
          sender_id: request.sender_id,
          dm_conversation_id: dm.id
        })
        |> Repo.insert()
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{accept: accepted_request, dm_conversation: dm} = changes} ->
        _ = broadcast_dm_request_accepted(accepted_request)
        _ = broadcast_new_dm(dm)
        {:ok, %{request: accepted_request, dm_conversation: dm, message: changes[:message]}}

      {:error, :request, :not_found, _} ->
        {:error, :not_found}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
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
        Moderation.block_user(recipient_id, request.sender_id)
      end

      {:ok, updated_request}
    end
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

  # ---------------------------------------------------------------------------
  # Private helpers — DM conversations
  # ---------------------------------------------------------------------------

  defp block_exists_between?(user_a_id, user_b_id) do
    Moderation.blocked?(user_a_id, user_b_id) or Moderation.blocked?(user_b_id, user_a_id)
  end

  defp find_or_create_dm_record(lower_id, higher_id, initiator_id, is_self_dm) do
    case Repo.get_by(DMConversation, user_a_id: lower_id, user_b_id: higher_id) do
      nil ->
        with :ok <- check_rate_limit(initiator_id, is_self_dm) do
          %DMConversation{}
          |> DMConversation.changeset(%{user_a_id: lower_id, user_b_id: higher_id})
          |> Repo.insert()
          |> maybe_broadcast_new_dm()
        end

      dm ->
        {:ok, dm}
    end
  end

  defp maybe_broadcast_new_dm({:ok, dm} = result) do
    _ = broadcast_new_dm(dm)
    result
  end

  defp maybe_broadcast_new_dm(error), do: error

  defp check_rate_limit(_initiator_id, true = _is_self_dm), do: :ok
  defp check_rate_limit(initiator_id, false = _is_self_dm), do: DMRateLimiter.check(initiator_id)

  defp broadcast_new_dm(dm) do
    _ =
      Phoenix.PubSub.broadcast(Slackex.PubSub, "user:#{dm.user_a_id}", {:dm_conversation_new, dm})

    Phoenix.PubSub.broadcast(Slackex.PubSub, "user:#{dm.user_b_id}", {:dm_conversation_new, dm})
  end

  defp verify_dm_participant(dm, sender_id) do
    if sender_id in [dm.user_a_id, dm.user_b_id], do: :ok, else: {:error, :unauthorized}
  end

  # ---------------------------------------------------------------------------
  # Private helpers — DM requests
  # ---------------------------------------------------------------------------

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
      nil -> insert_dm_conversation(lower_id, higher_id)
      dm -> {:ok, dm}
    end
  end

  defp insert_dm_conversation(lower_id, higher_id) do
    %DMConversation{}
    |> DMConversation.changeset(%{user_a_id: lower_id, user_b_id: higher_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_a_id, :user_b_id])
    |> handle_upsert_result(lower_id, higher_id)
  end

  defp handle_upsert_result({:ok, %DMConversation{id: nil}}, lower_id, higher_id) do
    # Conflict: another transaction inserted first. Re-fetch the existing record.
    case Repo.get_by(DMConversation, user_a_id: lower_id, user_b_id: higher_id) do
      nil -> {:error, :conversation_conflict}
      dm -> {:ok, dm}
    end
  end

  defp handle_upsert_result(result, _lower_id, _higher_id), do: result

  defp broadcast_dm_request_accepted(request) do
    Phoenix.PubSub.broadcast(
      Slackex.PubSub,
      "user:#{request.sender_id}",
      {:dm_request_accepted, request}
    )
  end

  # ---------------------------------------------------------------------------
  # Shared helpers (duplicated — small, not worth a shared module)
  # ---------------------------------------------------------------------------

  defp normalize_user_pair(user_a_id, user_b_id) when user_a_id < user_b_id,
    do: {user_a_id, user_b_id}

  defp normalize_user_pair(user_a_id, user_b_id),
    do: {user_b_id, user_a_id}

  defp hours_ago(hours), do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
  defp days_ago(days), do: hours_ago(days * 24)
end
