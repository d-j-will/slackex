defmodule Slackex.Chat.Moderation do
  @moduledoc "Manages user blocks, abuse reports, trust scores, and velocity detection."

  import Ecto.Query

  alias Slackex.Accounts.User
  alias Slackex.Chat.{AbuseReport, DMRequest, UserBlock, UserTrustScore}
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Repo

  @new_account_age_days 7
  @auto_restrict_block_threshold 5
  @report_restrict_threshold 3
  @report_admin_flag_threshold 5
  @velocity_signal_threshold 3
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
    1. Reporter account age >= 7 days
    2. Reporter not dm_restricted

  After successful creation:
    - Auto-blocks reported user (reporter blocks reported, unidirectional)
    - Upserts report_count on reported user's trust score

  Returns `{:ok, abuse_report}` on success.
  Returns `{:error, :self_report}` when reporter and reported user are the same.
  Returns `{:error, :account_too_new}` for accounts under 7 days.
  Returns `{:error, :dm_restricted}` for restricted reporters.
  Returns `{:error, changeset}` on validation failure (includes duplicate open report).
  """
  def create_abuse_report(reporter_id, reported_user_id, attrs) do
    with :ok <- check_self_report(reporter_id, reported_user_id),
         :ok <- check_reporter_account_age(reporter_id),
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
          _ = block_user(reporter_id, reported_user_id)
          upsert_report_count(reported_user_id)
          check_report_thresholds(reported_user_id)
          check_velocity(reported_user_id)
          {:ok, report}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Checks if a user is dm_restricted via user_trust_scores.
  Public because DMs module also calls this during request pre-flight.
  """
  def check_not_dm_restricted(sender_id) do
    restricted =
      Repo.exists?(
        from ts in UserTrustScore,
          where: ts.user_id == ^sender_id and ts.dm_restricted == true
      )

    if restricted, do: {:error, :dm_restricted}, else: :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
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

  defp check_self_report(user_id, user_id), do: {:error, :self_report}
  defp check_self_report(_reporter_id, _reported_user_id), do: :ok

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
      maybe_apply_dm_restriction(reported_user_id)
    end

    if distinct_count >= @report_admin_flag_threshold do
      maybe_apply_admin_flag(reported_user_id)
    end
  end

  defp count_distinct_reporters(reported_user_id) do
    reporter_timestamps =
      Repo.all(
        from ar in AbuseReport,
          where: ar.reported_user_id == ^reported_user_id,
          group_by: ar.reporter_id,
          select: {ar.reporter_id, min(ar.inserted_at)},
          order_by: [asc: min(ar.inserted_at)]
      )

    dampen_reporter_clusters(reporter_timestamps)
  end

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

  defp maybe_apply_dm_restriction(user_id) do
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
  # Velocity detection
  # ---------------------------------------------------------------------------

  defp check_velocity(user_id) do
    signal_count = count_negative_signals_24h(user_id)

    if signal_count >= @velocity_signal_threshold do
      maybe_apply_dm_restriction(user_id)
    end
  end

  defp count_negative_signals_24h(user_id) do
    cutoff = hours_ago(@velocity_window_hours)

    report_count =
      Repo.one(
        from ar in AbuseReport,
          where: ar.reported_user_id == ^user_id and ar.inserted_at >= ^cutoff,
          select: count()
      )

    block_count =
      Repo.one(
        from ub in UserBlock,
          where: ub.blocked_id == ^user_id and ub.inserted_at >= ^cutoff,
          select: count()
      )

    decline_count =
      Repo.one(
        from r in DMRequest,
          where: r.sender_id == ^user_id and r.status == "declined" and r.responded_at >= ^cutoff,
          select: count()
      )

    report_count + block_count + decline_count
  end

  defp hours_ago(hours), do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
  defp days_ago(days), do: hours_ago(days * 24)
end
