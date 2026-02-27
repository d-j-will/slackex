defmodule Slackex.Chat.AbuseReportEncryptionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
  alias Slackex.Chat.AbuseReport

  describe "abuse_report description and metadata encryption" do
    test "creating an abuse report stores description as encrypted binary, not plaintext" do
      reporter = insert_user_with_age_days(8)
      reported = insert(:user)

      {:ok, report} =
        Chat.create_abuse_report(reporter.id, reported.id, %{
          category: "spam",
          description: "secret description"
        })

      assert report.description == "secret description"

      # The raw database value in encrypted_description must NOT be plaintext
      raw =
        Repo.one(
          from r in "abuse_reports",
            where: r.id == ^report.id,
            select: r.encrypted_description
        )

      assert is_binary(raw)
      refute raw == "secret description"
    end

    test "creating an abuse report stores metadata as encrypted binary, not plaintext" do
      reporter = insert_user_with_age_days(8)
      reported = insert(:user)
      meta = %{"source" => "dm_conversation", "flagged_words" => ["bad", "words"]}

      {:ok, report} =
        Chat.create_abuse_report(reporter.id, reported.id, %{
          category: "harassment",
          metadata: meta
        })

      assert report.metadata == meta

      # The raw database value in encrypted_metadata must NOT be plaintext
      raw =
        Repo.one(
          from r in "abuse_reports",
            where: r.id == ^report.id,
            select: r.encrypted_metadata
        )

      assert is_binary(raw)
      # Raw value should not be the JSON-encoded plaintext
      refute raw == Jason.encode!(meta)
    end

    test "reading an abuse report returns decrypted description and metadata" do
      reporter = insert_user_with_age_days(8)
      reported = insert(:user)
      meta = %{"evidence" => "screenshot_url"}

      {:ok, report} =
        Chat.create_abuse_report(reporter.id, reported.id, %{
          category: "phishing",
          description: "phishing attempt",
          metadata: meta
        })

      # Reload from DB via Repo.get to ensure decryption on read
      loaded = Repo.get!(AbuseReport, report.id)
      assert loaded.description == "phishing attempt"
      assert loaded.metadata == meta
    end

    test "metadata defaults to empty map with encrypted type" do
      attrs = %{
        reporter_id: insert(:user).id,
        reported_user_id: insert(:user).id,
        category: "spam"
      }

      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)
      assert get_field(changeset, :metadata) == %{}
    end
  end
end
