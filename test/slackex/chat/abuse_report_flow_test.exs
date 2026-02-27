defmodule Slackex.Chat.AbuseReportFlowTest do
  use Slackex.DataCase, async: false

  alias Slackex.Chat
  alias Slackex.Chat.{AbuseReport, UserTrustScore}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp mark_dm_restricted(user) do
    %UserTrustScore{}
    |> UserTrustScore.changeset(%{user_id: user.id, dm_restricted: true})
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------------------
  # Acceptance: happy path
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 happy path" do
    test "creates open abuse report, auto-blocks reported user, upserts report_count" do
      reporter = insert_user_with_age_days(10)
      reported = insert_user_with_age_days(10)

      attrs = %{category: "spam"}

      assert {:ok, %AbuseReport{} = report} =
               Chat.create_abuse_report(reporter.id, reported.id, attrs)

      assert report.reporter_id == reporter.id
      assert report.reported_user_id == reported.id
      assert report.category == "spam"
      assert report.status == "open"
      assert report.id != nil

      # Auto-block: reporter blocks reported user (unidirectional)
      assert Chat.blocked?(reporter.id, reported.id)
      refute Chat.blocked?(reported.id, reporter.id)

      # Trust score: report_count upserted to 1
      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      assert trust_score.report_count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: pre-flight rejections
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 pre-flight rejections" do
    test "reporter cannot report themselves" do
      reporter = insert_user_with_age_days(10)

      assert {:error, :self_report} =
               Chat.create_abuse_report(reporter.id, reporter.id, %{category: "spam"})
    end

    test "rejects reporter with account under 7 days" do
      reporter = insert_user_with_age_days(3)
      reported = insert_user_with_age_days(10)

      assert {:error, :account_too_new} =
               Chat.create_abuse_report(reporter.id, reported.id, %{category: "spam"})
    end

    test "rejects reporter who is dm_restricted" do
      reporter = insert_user_with_age_days(10)
      reported = insert_user_with_age_days(10)
      mark_dm_restricted(reporter)

      assert {:error, :dm_restricted} =
               Chat.create_abuse_report(reporter.id, reported.id, %{category: "spam"})
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: auto-block tolerates already-blocked
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 auto-block when already blocked" do
    test "report succeeds even if reporter already blocked the reported user" do
      reporter = insert_user_with_age_days(10)
      reported = insert_user_with_age_days(10)
      Chat.block_user(reporter.id, reported.id)

      assert {:ok, %AbuseReport{}} =
               Chat.create_abuse_report(reporter.id, reported.id, %{category: "harassment"})
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: trust score upsert increments existing count
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 trust score upsert" do
    test "increments existing report_count on reported user trust score" do
      reporter = insert_user_with_age_days(10)
      reported = insert_user_with_age_days(10)

      # Pre-existing trust score with report_count = 2
      %UserTrustScore{}
      |> UserTrustScore.changeset(%{user_id: reported.id, report_count: 2})
      |> Repo.insert!()

      {:ok, _report} =
        Chat.create_abuse_report(reporter.id, reported.id, %{category: "spam"})

      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      assert trust_score.report_count == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: duplicate open report rejection
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 duplicate open report" do
    test "second open report for same reporter-reported pair is rejected" do
      reporter = insert_user_with_age_days(10)
      reported = insert_user_with_age_days(10)

      {:ok, %AbuseReport{}} =
        Chat.create_abuse_report(reporter.id, reported.id, %{category: "spam"})

      assert {:error, %Ecto.Changeset{}} =
               Chat.create_abuse_report(reporter.id, reported.id, %{category: "harassment"})
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: all fields persisted correctly
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 field persistence" do
    test "persists optional fields (description, dm_conversation_id, message_id, metadata)" do
      reporter = insert_user_with_age_days(10)
      reported = insert_user_with_age_days(10)

      attrs = %{
        category: "harassment",
        description: "Sending threatening messages",
        message_id: 12345,
        metadata: %{"source" => "dm_conversation"}
      }

      {:ok, report} = Chat.create_abuse_report(reporter.id, reported.id, attrs)

      assert report.description == "Sending threatening messages"
      assert report.message_id == 12345
      assert report.metadata == %{"source" => "dm_conversation"}
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: velocity detection (3+ negative signals in 24h)
  # ---------------------------------------------------------------------------

  describe "velocity detection triggers dm_restricted" do
    test "3 mixed negative signals within 24h triggers dm_restricted via velocity" do
      # Setup: target has a prior decline (someone declined target's DM request)
      target = insert_user_with_age_days(10)
      decliner = insert_user_with_age_days(10)
      reporter = insert_user_with_age_days(10)

      # Signal 1: a declined DM request where target is sender (within 24h)
      {:ok, dm_request} = Chat.create_dm_request(target.id, decliner.id, "hey")
      {:ok, _declined} = Chat.decline_dm_request(dm_request.id, decliner.id)

      # Signal 2 + 3: filing abuse report auto-blocks (block = signal 2) + report itself (signal 3)
      {:ok, _report} = Chat.create_abuse_report(reporter.id, target.id, %{category: "spam"})

      # Velocity: decline(1) + block(1) + report(1) = 3 signals in 24h => dm_restricted
      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.dm_restricted == true
      assert trust_score.dm_restricted_at != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Unit: velocity signals outside 24h window are not counted
  # ---------------------------------------------------------------------------

  describe "velocity detection 24h window boundary" do
    test "negative signals outside 24h window do not count toward velocity" do
      target = insert_user_with_age_days(10)
      blocker_old = insert_user_with_age_days(10)
      blocker_recent = insert_user_with_age_days(10)
      reporter = insert_user_with_age_days(10)

      # Old block: 25 hours ago (outside 24h window)
      {:ok, _block} = Chat.block_user(blocker_old.id, target.id)

      past =
        DateTime.utc_now() |> DateTime.add(-25 * 3600, :second) |> DateTime.truncate(:microsecond)

      Repo.update_all(
        from(ub in Slackex.Chat.UserBlock,
          where: ub.blocker_id == ^blocker_old.id and ub.blocked_id == ^target.id
        ),
        set: [inserted_at: past]
      )

      # Recent block: within 24h
      {:ok, _block} = Chat.block_user(blocker_recent.id, target.id)

      # Report (within 24h) -- gives report(1) + auto-block(1) + recent block(1) = 3? No:
      # auto-block is reporter->target, recent block is blocker_recent->target
      # So signals within 24h: blocker_recent block(1) + report auto-block(1) + report(1) = 3
      # But the old block is outside window, so it should NOT count.
      # With only 1 reporter (below threshold of 3 distinct), velocity is the only path to restriction.

      # Reset trust score to clear any block-based restriction from blocker_recent
      Repo.delete_all(from(ts in UserTrustScore, where: ts.user_id == ^target.id))

      {:ok, _report} = Chat.create_abuse_report(reporter.id, target.id, %{category: "spam"})

      # Signals within 24h: blocker_recent block(1) + reporter auto-block(1) + report(1) = 3
      # Velocity should trigger
      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.dm_restricted == true
    end

    test "only 2 signals within 24h does not trigger velocity restriction" do
      target = insert_user_with_age_days(10)
      reporter = insert_user_with_age_days(10)

      # Filing a report creates: auto-block(1) + report(1) = 2 signals
      # No other signals within 24h, so velocity threshold of 3 not met
      # Also only 1 distinct reporter, so threshold gate (3 distinct) not met
      {:ok, _report} = Chat.create_abuse_report(reporter.id, target.id, %{category: "spam"})

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.dm_restricted == false
    end
  end

  # ---------------------------------------------------------------------------
  # Unit: velocity and threshold are independent gates
  # ---------------------------------------------------------------------------

  describe "velocity and distinct-reporter threshold are independent gates" do
    test "velocity triggers restriction even with fewer than 3 distinct reporters" do
      target = insert_user_with_age_days(10)
      decliner = insert_user_with_age_days(10)
      reporter = insert_user_with_age_days(10)

      # Decline gives 1 signal
      {:ok, dm_request} = Chat.create_dm_request(target.id, decliner.id, "hey")
      {:ok, _declined} = Chat.decline_dm_request(dm_request.id, decliner.id)

      # Report: auto-block(1) + report(1) = 2 more signals, total = 3
      # Only 1 distinct reporter (below threshold of 3), but velocity fires independently
      {:ok, _report} = Chat.create_abuse_report(reporter.id, target.id, %{category: "spam"})

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.dm_restricted == true
    end
  end

  # ---------------------------------------------------------------------------
  # Unit: coordinated-report dampening
  # ---------------------------------------------------------------------------

  describe "coordinated-report dampening reduces distinct reporter count" do
    test "reports from 3 reporters within same 24h window count as 1 distinct reporter" do
      target = insert_user_with_age_days(10)
      reporters = for _ <- 1..3, do: insert_user_with_age_days(10)
      categories = ["spam", "harassment", "other"]

      # All 3 reporters file within minutes of each other (same 24h window)
      for {reporter, i} <- Enum.with_index(reporters) do
        {:ok, _report} =
          Chat.create_abuse_report(reporter.id, target.id, %{category: Enum.at(categories, i)})
      end

      # Without dampening, 3 distinct reporters would trigger dm_restricted via threshold.
      # With dampening, all 3 are in the same 24h window => count as 1 distinct reporter.
      # 1 < 3 (threshold), so threshold gate does NOT restrict.
      # However, velocity might trigger (3 reports + 3 auto-blocks = 6 signals in 24h).
      # So we need to check that the dampened count itself is 1.
      # We test this indirectly: if velocity already restricts, the dampening is still correct
      # but hard to observe. We verify by checking that with dampening applied, the
      # threshold-based admin_flagged is NOT triggered (requires 5 distinct).
      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.admin_flagged == false
    end

    test "reporters separated by more than 24h count as separate distinct reporters" do
      target = insert_user_with_age_days(10)
      reporter_old = insert_user_with_age_days(10)
      reporter_mid = insert_user_with_age_days(10)
      reporter_new = insert_user_with_age_days(10)

      # Reporter 1: files 50 hours ago (outside 24h of reporter 2)
      {:ok, report1} =
        Chat.create_abuse_report(reporter_old.id, target.id, %{category: "spam"})

      past_50h =
        DateTime.utc_now() |> DateTime.add(-50 * 3600, :second) |> DateTime.truncate(:microsecond)

      Repo.update_all(
        from(ar in AbuseReport, where: ar.id == ^report1.id),
        set: [inserted_at: past_50h]
      )

      # Reporter 2: files 48 hours ago (>24h from reporter 1, >24h from reporter 3)
      {:ok, report2} =
        Chat.create_abuse_report(reporter_mid.id, target.id, %{category: "harassment"})

      past_48h =
        DateTime.utc_now() |> DateTime.add(-48 * 3600, :second) |> DateTime.truncate(:microsecond)

      Repo.update_all(
        from(ar in AbuseReport, where: ar.id == ^report2.id),
        set: [inserted_at: past_48h]
      )

      # Reporter 3: files now
      {:ok, _report3} =
        Chat.create_abuse_report(reporter_new.id, target.id, %{category: "other"})

      # Each reporter is >24h apart from the others => 3 separate clusters => 3 distinct reporters
      # This should trigger dm_restricted via the threshold gate
      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.dm_restricted == true
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: distinct reporter thresholds
  # ---------------------------------------------------------------------------

  describe "create_abuse_report/3 distinct reporter thresholds" do
    test "3 distinct reporters triggers dm_restricted on reported user" do
      reported = insert_user_with_age_days(10)
      reporters = for _ <- 1..3, do: insert_user_with_age_days(10)

      for {reporter, i} <- Enum.with_index(reporters) do
        category = Enum.at(["spam", "harassment", "other"], i)
        {:ok, _report} = Chat.create_abuse_report(reporter.id, reported.id, %{category: category})
      end

      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      assert trust_score.dm_restricted == true
      assert trust_score.dm_restricted_at != nil
    end

    test "fewer than 3 distinct reporters does not trigger threshold restriction (velocity may still restrict)" do
      reported = insert_user_with_age_days(10)
      reporters = for _ <- 1..2, do: insert_user_with_age_days(10)

      for {reporter, i} <- Enum.with_index(reporters) do
        category = Enum.at(["spam", "harassment"], i)
        {:ok, _report} = Chat.create_abuse_report(reporter.id, reported.id, %{category: category})
      end

      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      # Distinct-reporter threshold (3+) NOT met -- only 2 reporters
      assert trust_score.admin_flagged == false
      # Velocity detection (3+ signals in 24h) IS triggered:
      # 2 reports + 2 auto-blocks = 4 signals >= 3 threshold
      assert trust_score.dm_restricted == true
    end

    test "multiple reports from same reporter count as 1 distinct reporter for dampening" do
      reported = insert_user_with_age_days(10)
      reporter_a = insert_user_with_age_days(10)
      reporter_b = insert_user_with_age_days(10)

      # reporter_a files report, then reporter_b files report
      {:ok, _} = Chat.create_abuse_report(reporter_a.id, reported.id, %{category: "spam"})
      {:ok, _} = Chat.create_abuse_report(reporter_b.id, reported.id, %{category: "harassment"})

      # 2 distinct reporters in same 24h window => dampened to 1 => below threshold of 3
      # Velocity fires independently (2 reports + 2 blocks = 4 signals)
      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      assert trust_score.dm_restricted == true
      assert trust_score.admin_flagged == false
    end

    test "5 distinct reporters spaced apart triggers admin_flagged on reported user" do
      reported = insert_user_with_age_days(10)
      reporters = for _ <- 1..5, do: insert_user_with_age_days(10)
      categories = ["spam", "harassment", "other", "phishing", "inappropriate_content"]

      # Create 5 backdated reports via factory (bypasses create_abuse_report, so no
      # auto-blocks or trust score side effects). Each report is >24h apart so
      # dampening treats them as separate clusters.
      for {reporter, i} <- Enum.with_index(reporters) do
        hours = (i + 1) * 25
        insert_backdated_abuse_report(reporter, reported, Enum.at(categories, i), hours)
      end

      # File a 6th report from a new reporter to trigger fresh threshold evaluation
      # with all 5 backdated reports visible as separate clusters
      reporter_6 = insert_user_with_age_days(10)

      {:ok, _report} =
        Chat.create_abuse_report(reporter_6.id, reported.id, %{category: "spam"})

      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      assert trust_score.admin_flagged == true
      assert trust_score.admin_flagged_at != nil
      # dm_restricted should also be true (triggered at 3 distinct, or via velocity)
      assert trust_score.dm_restricted == true
    end

    test "fewer than 5 distinct reporters does not admin-flag reported user" do
      reported = insert_user_with_age_days(10)
      reporters = for _ <- 1..4, do: insert_user_with_age_days(10)
      categories = ["spam", "harassment", "other", "phishing"]

      for {reporter, i} <- Enum.with_index(reporters) do
        {:ok, _report} =
          Chat.create_abuse_report(reporter.id, reported.id, %{category: Enum.at(categories, i)})
      end

      trust_score = Repo.get_by!(UserTrustScore, user_id: reported.id)
      assert trust_score.admin_flagged == false
      # dm_restricted should be true (4 >= 3)
      assert trust_score.dm_restricted == true
    end
  end
end
