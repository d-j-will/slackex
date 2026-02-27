defmodule Slackex.Chat.UserTrustScoreTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.UserTrustScore

  describe "changeset/2" do
    test "valid attrs with user_id produce a valid changeset" do
      user = insert(:user)

      changeset =
        UserTrustScore.changeset(%UserTrustScore{}, %{user_id: user.id})

      assert changeset.valid?
    end

    test "user_id is required" do
      changeset = UserTrustScore.changeset(%UserTrustScore{}, %{})

      refute changeset.valid?
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "counts must be non-negative" do
      user = insert(:user)

      changeset =
        UserTrustScore.changeset(%UserTrustScore{}, %{
          user_id: user.id,
          decline_count: -1,
          block_count: -2,
          report_count: -3
        })

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "must be greater than or equal to 0" in errors.decline_count
      assert "must be greater than or equal to 0" in errors.block_count
      assert "must be greater than or equal to 0" in errors.report_count
    end

    test "defaults counts to 0 and dm_restricted to false" do
      user = insert(:user)

      changeset =
        UserTrustScore.changeset(%UserTrustScore{}, %{user_id: user.id})

      assert get_field(changeset, :decline_count) == 0
      assert get_field(changeset, :block_count) == 0
      assert get_field(changeset, :report_count) == 0
      assert get_field(changeset, :dm_restricted) == false
    end
  end

  describe "database constraints" do
    test "inserting a valid trust score succeeds with default values" do
      user = insert(:user)

      assert {:ok, trust_score} =
               %UserTrustScore{}
               |> UserTrustScore.changeset(%{user_id: user.id})
               |> Repo.insert()

      assert trust_score.user_id == user.id
      assert trust_score.decline_count == 0
      assert trust_score.block_count == 0
      assert trust_score.report_count == 0
      assert trust_score.dm_restricted == false
      assert trust_score.dm_restricted_at == nil
      assert trust_score.updated_at
    end

    test "duplicate user_id is rejected by unique constraint" do
      user = insert(:user)

      {:ok, _} =
        %UserTrustScore{}
        |> UserTrustScore.changeset(%{user_id: user.id})
        |> Repo.insert()

      assert {:error, changeset} =
               %UserTrustScore{}
               |> UserTrustScore.changeset(%{user_id: user.id})
               |> Repo.insert()

      assert %{user_id: ["already has a trust score"]} = errors_on(changeset)
    end

    test "dm_restricted_at can be set when dm_restricted is true" do
      user = insert(:user)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, trust_score} =
               %UserTrustScore{}
               |> UserTrustScore.changeset(%{
                 user_id: user.id,
                 dm_restricted: true,
                 dm_restricted_at: now
               })
               |> Repo.insert()

      assert trust_score.dm_restricted == true
      assert trust_score.dm_restricted_at == now
    end

    test "counts can be updated with new values" do
      user = insert(:user)

      {:ok, trust_score} =
        %UserTrustScore{}
        |> UserTrustScore.changeset(%{user_id: user.id})
        |> Repo.insert()

      assert {:ok, updated} =
               trust_score
               |> UserTrustScore.changeset(%{
                 decline_count: 3,
                 block_count: 1,
                 report_count: 2
               })
               |> Repo.update()

      assert updated.decline_count == 3
      assert updated.block_count == 1
      assert updated.report_count == 2
    end
  end
end
