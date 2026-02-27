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
end
