defmodule Slackex.Chat.AbuseReportTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.AbuseReport

  @valid_categories ~w(spam harassment inappropriate_content phishing other)
  @valid_statuses ~w(open reviewed actioned dismissed)

  defp valid_attrs(overrides \\ %{}) do
    reporter = insert(:user)
    reported = insert(:user)

    Map.merge(
      %{
        reporter_id: reporter.id,
        reported_user_id: reported.id,
        category: "spam"
      },
      overrides
    )
  end

  describe "changeset/2 validations" do
    test "valid attrs produce a valid changeset" do
      attrs = valid_attrs()
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)

      assert changeset.valid?
    end

    test "reporter_id and reported_user_id and category are required" do
      changeset = AbuseReport.changeset(%AbuseReport{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.reporter_id
      assert "can't be blank" in errors.reported_user_id
      assert "can't be blank" in errors.category
    end

    test "category validates inclusion in exactly 5 values" do
      for category <- @valid_categories do
        attrs = valid_attrs(%{category: category})
        changeset = AbuseReport.changeset(%AbuseReport{}, attrs)
        assert changeset.valid?, "expected category #{category} to be valid"
      end

      attrs = valid_attrs(%{category: "threat"})
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)
      refute changeset.valid?
      assert %{category: ["is invalid"]} = errors_on(changeset)
    end

    test "status validates inclusion in exactly 4 values" do
      for status <- @valid_statuses do
        attrs = valid_attrs(%{status: status})
        changeset = AbuseReport.changeset(%AbuseReport{}, attrs)
        assert changeset.valid?, "expected status #{status} to be valid"
      end

      attrs = valid_attrs(%{status: "closed"})
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "status defaults to open" do
      attrs = valid_attrs()
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)

      assert get_field(changeset, :status) == "open"
    end

    test "description is optional" do
      attrs = valid_attrs(%{description: "This user sent me spam"})
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :description) == "This user sent me spam"
    end

    test "dm_conversation_id is optional" do
      attrs = valid_attrs(%{dm_conversation_id: nil})
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)

      assert changeset.valid?
    end

    test "message_id is optional" do
      attrs = valid_attrs(%{message_id: nil})
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)

      assert changeset.valid?
    end

    test "metadata defaults to empty map" do
      attrs = valid_attrs()
      changeset = AbuseReport.changeset(%AbuseReport{}, attrs)

      assert get_field(changeset, :metadata) == %{}
    end
  end

  describe "database roundtrip" do
    test "inserting a valid abuse report succeeds with Snowflake ID" do
      reporter = insert(:user)
      reported = insert(:user)
      id = Slackex.Infrastructure.Snowflake.generate()

      assert {:ok, report} =
               %AbuseReport{id: id}
               |> AbuseReport.changeset(%{
                 reporter_id: reporter.id,
                 reported_user_id: reported.id,
                 category: "harassment",
                 description: "Rude messages"
               })
               |> Repo.insert()

      assert report.id == id
      assert report.reporter_id == reporter.id
      assert report.reported_user_id == reported.id
      assert report.category == "harassment"
      assert report.description == "Rude messages"
      assert report.status == "open"
      assert report.metadata == %{}
      assert report.dm_conversation_id == nil
      assert report.message_id == nil
      assert report.inserted_at
      assert report.updated_at
    end

    test "belongs_to associations are defined" do
      reporter = insert(:user)
      reported = insert(:user)
      id = Slackex.Infrastructure.Snowflake.generate()

      {:ok, report} =
        %AbuseReport{id: id}
        |> AbuseReport.changeset(%{
          reporter_id: reporter.id,
          reported_user_id: reported.id,
          category: "spam"
        })
        |> Repo.insert()

      report = Repo.preload(report, [:reporter, :reported_user])

      assert report.reporter.id == reporter.id
      assert report.reported_user.id == reported.id
    end

    test "dm_conversation association is optional" do
      reporter = insert(:user)
      reported = insert(:user)
      dm = insert(:dm_conversation)
      id = Slackex.Infrastructure.Snowflake.generate()

      {:ok, report} =
        %AbuseReport{id: id}
        |> AbuseReport.changeset(%{
          reporter_id: reporter.id,
          reported_user_id: reported.id,
          category: "phishing",
          dm_conversation_id: dm.id
        })
        |> Repo.insert()

      report = Repo.preload(report, :dm_conversation)
      assert report.dm_conversation_id == dm.id
      assert report.dm_conversation.id == dm.id
    end

    test "message_id allows user-level reports without message context" do
      reporter = insert(:user)
      reported = insert(:user)
      id = Slackex.Infrastructure.Snowflake.generate()

      assert {:ok, report} =
               %AbuseReport{id: id}
               |> AbuseReport.changeset(%{
                 reporter_id: reporter.id,
                 reported_user_id: reported.id,
                 category: "inappropriate_content",
                 message_id: 123_456_789
               })
               |> Repo.insert()

      assert report.message_id == 123_456_789
    end

    test "metadata stores JSONB data" do
      reporter = insert(:user)
      reported = insert(:user)
      id = Slackex.Infrastructure.Snowflake.generate()
      meta = %{"source" => "dm_conversation", "flagged_words" => ["bad", "words"]}

      assert {:ok, report} =
               %AbuseReport{id: id}
               |> AbuseReport.changeset(%{
                 reporter_id: reporter.id,
                 reported_user_id: reported.id,
                 category: "spam",
                 metadata: meta
               })
               |> Repo.insert()

      assert report.metadata == meta
    end

    test "unique partial index prevents duplicate open reports for same reporter-reported pair" do
      reporter = insert(:user)
      reported = insert(:user)
      id1 = Slackex.Infrastructure.Snowflake.generate()
      id2 = Slackex.Infrastructure.Snowflake.generate()

      {:ok, _} =
        %AbuseReport{id: id1}
        |> AbuseReport.changeset(%{
          reporter_id: reporter.id,
          reported_user_id: reported.id,
          category: "spam"
        })
        |> Repo.insert()

      assert {:error, changeset} =
               %AbuseReport{id: id2}
               |> AbuseReport.changeset(%{
                 reporter_id: reporter.id,
                 reported_user_id: reported.id,
                 category: "harassment"
               })
               |> Repo.insert()

      assert %{reporter_id: ["already has an open report for this user"]} =
               errors_on(changeset)
    end

    test "reviewed report allows a new open report for same pair" do
      reporter = insert(:user)
      reported = insert(:user)
      id1 = Slackex.Infrastructure.Snowflake.generate()
      id2 = Slackex.Infrastructure.Snowflake.generate()

      {:ok, first_report} =
        %AbuseReport{id: id1}
        |> AbuseReport.changeset(%{
          reporter_id: reporter.id,
          reported_user_id: reported.id,
          category: "spam"
        })
        |> Repo.insert()

      # Mark first report as reviewed
      first_report
      |> AbuseReport.changeset(%{status: "reviewed"})
      |> Repo.update!()

      # A new open report should now be allowed
      assert {:ok, _} =
               %AbuseReport{id: id2}
               |> AbuseReport.changeset(%{
                 reporter_id: reporter.id,
                 reported_user_id: reported.id,
                 category: "harassment"
               })
               |> Repo.insert()
    end
  end
end
