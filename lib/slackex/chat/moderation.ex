defmodule Slackex.Chat.Moderation do
  @moduledoc """
  Manages user blocks, abuse reports, trust scores, and velocity detection.

  `create_abuse_report/3` follows a **Gather → Decide → Act** architecture:

    * **Gather** — `gather_context/2` runs the read-only `Repo` queries needed to
      build a `Rules.ModerationContext`. The two count fields are *projected*:
      they reflect the world after this report and its auto-block would land, so
      the decision is made on the same numbers the side-effects will produce.
    * **Decide** — `Rules.evaluate_abuse_report/1` (a pure function, no DB) turns
      the context into a `Rules.ModerationAction`.
    * **Act** — `perform_report/4` runs the flagged side-effects inside a single
      `Ecto.Multi` transaction.
  """

  import Ecto.Query

  alias Slackex.Accounts.User
  alias Slackex.Chat.{AbuseReport, DMRequest, UserBlock, UserTrustScore}
  alias Slackex.Chat.Moderation.Rules
  alias Slackex.Chat.Moderation.Rules.{ModerationAction, ModerationContext}
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Repo

  @auto_restrict_block_threshold 5
  @velocity_window_hours 24
  @dampening_window_seconds 86_400

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
    1. Reporter is not reporting themselves
    2. Reporter account age >= 7 days
    3. Reporter not dm_restricted

  After successful creation:
    - Auto-blocks reported user (reporter blocks reported, unidirectional)
    - Upserts report_count on reported user's trust score
    - May restrict the reported user's DMs (distinct-reporter or velocity gate)
    - May flag the reported user for an admin (5+ distinct reporters)

  Returns `{:ok, abuse_report}` on success.
  Returns `{:error, :self_report}` when reporter and reported user are the same.
  Returns `{:error, :account_too_new}` for accounts under 7 days.
  Returns `{:error, :dm_restricted}` for restricted reporters.
  Returns `{:error, changeset}` on validation failure (includes duplicate open report).
  """
  def create_abuse_report(reporter_id, reported_user_id, attrs) do
    context = gather_context(reporter_id, reported_user_id)

    case Rules.evaluate_abuse_report(context) do
      %ModerationAction{error: nil} = action ->
        perform_report(action, reporter_id, reported_user_id, attrs)

      %ModerationAction{error: reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a user is dm_restricted via user_trust_scores.
  Public because DMs module also calls this during request pre-flight.
  """
  def check_not_dm_restricted(sender_id) do
    if dm_restricted?(sender_id), do: {:error, :dm_restricted}, else: :ok
  end

  # ---------------------------------------------------------------------------
  # Gather: build the moderation context with read-only queries
  # ---------------------------------------------------------------------------

  defp gather_context(reporter_id, reported_user_id) do
    %ModerationContext{
      reporter_is_self_reporting: reporter_id == reported_user_id,
      reporter_account_age_days: reporter_account_age_days(reporter_id),
      reporter_is_dm_restricted: dm_restricted?(reporter_id),
      reported_user_distinct_report_count:
        projected_distinct_report_count(reported_user_id, reporter_id),
      reported_user_negative_signals_24h:
        projected_negative_signals_24h(reported_user_id, reporter_id)
    }
  end

  defp reporter_account_age_days(reporter_id) do
    case Repo.one(from u in User, where: u.id == ^reporter_id, select: u.inserted_at) do
      nil -> 0
      inserted_at -> DateTime.diff(DateTime.utc_now(), inserted_at, :day)
    end
  end

  defp dm_restricted?(user_id) do
    Repo.exists?(
      from ts in UserTrustScore,
        where: ts.user_id == ^user_id and ts.dm_restricted == true
    )
  end

  # Distinct reporter clusters *after* this report would be filed. We read the
  # existing {reporter_id, first_report_at} pairs and fold in the pending report
  # before dampening, reproducing what a post-insert GROUP BY would see.
  defp projected_distinct_report_count(reported_user_id, reporter_id) do
    Repo.all(
      from ar in AbuseReport,
        where: ar.reported_user_id == ^reported_user_id,
        group_by: ar.reporter_id,
        select: {ar.reporter_id, min(ar.inserted_at)}
    )
    |> project_pending_report(reporter_id)
    |> Enum.sort_by(fn {_reporter_id, first_at} -> first_at end, DateTime)
    |> dampen_reporter_clusters()
  end

  # A brand-new reporter is added at "now"; an existing reporter keeps their
  # earlier first-report timestamp (min), so the projection matches reality.
  defp project_pending_report(existing_pairs, reporter_id) do
    if List.keymember?(existing_pairs, reporter_id, 0) do
      existing_pairs
    else
      [{reporter_id, DateTime.utc_now()} | existing_pairs]
    end
  end

  # Negative signals in the velocity window *after* this report and its
  # auto-block would land: always +1 for the report being filed, and +1 for the
  # auto-block only when the reporter has not already blocked the reported user
  # (the auto-block is idempotent, so an existing block adds no new signal).
  defp projected_negative_signals_24h(reported_user_id, reporter_id) do
    cutoff = hours_ago(@velocity_window_hours)

    existing_reports =
      Repo.one(
        from ar in AbuseReport,
          where: ar.reported_user_id == ^reported_user_id and ar.inserted_at >= ^cutoff,
          select: count()
      )

    existing_blocks =
      Repo.one(
        from ub in UserBlock,
          where: ub.blocked_id == ^reported_user_id and ub.inserted_at >= ^cutoff,
          select: count()
      )

    declines =
      Repo.one(
        from r in DMRequest,
          where:
            r.sender_id == ^reported_user_id and r.status == "declined" and
              r.responded_at >= ^cutoff,
          select: count()
      )

    pending_block = if blocked?(reporter_id, reported_user_id), do: 0, else: 1

    existing_reports + 1 + (existing_blocks + pending_block) + declines
  end

  # ---------------------------------------------------------------------------
  # Act: run the flagged side-effects in one transaction
  # ---------------------------------------------------------------------------

  defp perform_report(%ModerationAction{} = action, reporter_id, reported_user_id, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:report, report_changeset(reporter_id, reported_user_id, attrs))
    |> maybe_auto_block(action, reporter_id, reported_user_id)
    |> maybe_increment_report_count(action, reported_user_id)
    |> maybe_restrict_dms(action, reported_user_id)
    |> maybe_flag_for_admin(action, reported_user_id)
    |> Repo.transaction()
    |> case do
      {:ok, %{report: report}} -> {:ok, report}
      {:error, :report, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  defp report_changeset(reporter_id, reported_user_id, attrs) do
    report_attrs =
      Map.merge(attrs, %{
        reporter_id: reporter_id,
        reported_user_id: reported_user_id,
        status: "open"
      })

    %AbuseReport{id: Snowflake.generate()}
    |> AbuseReport.changeset(report_attrs)
  end

  defp maybe_auto_block(multi, %ModerationAction{auto_block_user: true}, reporter_id, reported_id) do
    # Reporter blocks reported user. `on_conflict: :nothing` makes this safe to
    # run inside the transaction even when the block already exists (a bare insert
    # would raise a unique violation and poison the whole transaction).
    #
    # CLAUDE.md "Ecto upsert safety" warns that `on_conflict: :nothing` returns a
    # nil-id ghost struct. That is handled here deliberately *without* the usual
    # `get_by!` re-fetch: we never use the block struct downstream, and the nil id
    # is exactly the signal we want — it tells us whether a NEW row was inserted.
    block_changeset =
      UserBlock.changeset(%UserBlock{}, %{blocker_id: reporter_id, blocked_id: reported_id})

    multi
    |> Ecto.Multi.insert(:auto_block, block_changeset,
      on_conflict: :nothing,
      conflict_target: [:blocker_id, :blocked_id]
    )
    |> Ecto.Multi.run(:auto_block_count, fn _repo, %{auto_block: block} ->
      # Bump the reported user's block_count only for a freshly inserted block
      # (non-nil id). This matches block_user/2's count semantics: it too leaves
      # block_count untouched when the block already exists (its `with` returns the
      # duplicate error before reaching upsert_block_count). Keeping the count here
      # preserves the block-based DM restriction (5+ blocks).
      if block.id, do: upsert_block_count(reported_id)
      {:ok, :ok}
    end)
  end

  defp maybe_auto_block(multi, _action, _reporter_id, _reported_id), do: multi

  defp maybe_increment_report_count(
         multi,
         %ModerationAction{increment_report_count: true},
         reported_user_id
       ) do
    changeset =
      UserTrustScore.changeset(
        %UserTrustScore{user_id: reported_user_id},
        %{user_id: reported_user_id, report_count: 1}
      )

    Ecto.Multi.insert(multi, :report_count, changeset,
      on_conflict: [inc: [report_count: 1]],
      conflict_target: :user_id
    )
  end

  defp maybe_increment_report_count(multi, _action, _reported_user_id), do: multi

  defp maybe_restrict_dms(multi, %ModerationAction{apply_dm_restriction: true}, reported_user_id) do
    Ecto.Multi.run(multi, :dm_restriction, fn _repo, _changes ->
      _ = apply_dm_restriction(reported_user_id)
      {:ok, :ok}
    end)
  end

  defp maybe_restrict_dms(multi, _action, _reported_user_id), do: multi

  defp maybe_flag_for_admin(multi, %ModerationAction{flag_for_admin: true}, reported_user_id) do
    Ecto.Multi.run(multi, :admin_flag, fn _repo, _changes ->
      _ = apply_admin_flag(reported_user_id)
      {:ok, :ok}
    end)
  end

  defp maybe_flag_for_admin(multi, _action, _reported_user_id), do: multi

  # ---------------------------------------------------------------------------
  # Trust-score mutations (shared by block, report, and DM flows)
  # ---------------------------------------------------------------------------

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

  defp apply_dm_restriction(user_id) do
    case Repo.get_by(UserTrustScore, user_id: user_id) do
      %{dm_restricted: false} = trust_score ->
        trust_score
        |> UserTrustScore.changeset(%{
          dm_restricted: true,
          dm_restricted_at: DateTime.utc_now()
        })
        |> Repo.update()

      nil ->
        %UserTrustScore{user_id: user_id}
        |> UserTrustScore.changeset(%{
          user_id: user_id,
          dm_restricted: true,
          dm_restricted_at: DateTime.utc_now()
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: :user_id)

      _already_restricted ->
        :ok
    end
  end

  defp apply_admin_flag(reported_user_id) do
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
  # Coordinated-report dampening
  # ---------------------------------------------------------------------------

  # Counts distinct reporter clusters by grouping reporters whose first report
  # falls within the same 24-hour window. This dampens coordinated reporting:
  # multiple reporters filing within a single window count as one cluster.
  #
  # Algorithm: Walk the time-sorted list of {reporter_id, first_report_at} pairs.
  # Start a new cluster (increment count) whenever a reporter's timestamp exceeds
  # the current window_start by more than 24 hours; otherwise they join the
  # existing cluster.
  #
  # Example with reporters A(t=0h), B(t=2h), C(t=30h), D(t=31h):
  #   - A starts cluster 1 (window_start = 0h)
  #   - B at 2h is within 24h of 0h -> stays in cluster 1
  #   - C at 30h exceeds 24h from 0h -> starts cluster 2 (window_start = 30h)
  #   - D at 31h is within 24h of 30h -> stays in cluster 2
  #   Result: 2 distinct reporter clusters
  defp dampen_reporter_clusters([]), do: 0

  defp dampen_reporter_clusters([{_first_reporter, first_timestamp} | rest]) do
    {count, _window_start} =
      Enum.reduce(rest, {1, first_timestamp}, fn {_reporter_id, timestamp},
                                                 {count, window_start} ->
        if DateTime.diff(timestamp, window_start, :second) > @dampening_window_seconds do
          {count + 1, timestamp}
        else
          {count, window_start}
        end
      end)

    count
  end

  defp hours_ago(hours), do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
end
