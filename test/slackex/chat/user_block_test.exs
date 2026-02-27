defmodule Slackex.Chat.UserBlockTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.UserBlock

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      blocker = insert(:user)
      blocked = insert(:user)

      changeset =
        UserBlock.changeset(%UserBlock{}, %{
          blocker_id: blocker.id,
          blocked_id: blocked.id,
          reason: "spam"
        })

      assert changeset.valid?
    end

    test "blocker_id and blocked_id are required" do
      changeset = UserBlock.changeset(%UserBlock{}, %{})

      refute changeset.valid?
      assert %{blocker_id: ["can't be blank"], blocked_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "reason is optional" do
      blocker = insert(:user)
      blocked = insert(:user)

      changeset =
        UserBlock.changeset(%UserBlock{}, %{
          blocker_id: blocker.id,
          blocked_id: blocked.id
        })

      assert changeset.valid?
    end

    test "self-blocking is rejected" do
      user = insert(:user)

      changeset =
        UserBlock.changeset(%UserBlock{}, %{
          blocker_id: user.id,
          blocked_id: user.id
        })

      refute changeset.valid?
      assert %{blocked_id: ["cannot block yourself"]} = errors_on(changeset)
    end
  end

  describe "database constraints" do
    test "inserting a valid block succeeds" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:ok, user_block} =
               %UserBlock{}
               |> UserBlock.changeset(%{
                 blocker_id: blocker.id,
                 blocked_id: blocked.id,
                 reason: "harassment"
               })
               |> Repo.insert()

      assert user_block.blocker_id == blocker.id
      assert user_block.blocked_id == blocked.id
      assert user_block.reason == "harassment"
      assert user_block.inserted_at
    end

    test "duplicate block is rejected by unique constraint" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} =
        %UserBlock{}
        |> UserBlock.changeset(%{blocker_id: blocker.id, blocked_id: blocked.id})
        |> Repo.insert()

      assert {:error, changeset} =
               %UserBlock{}
               |> UserBlock.changeset(%{blocker_id: blocker.id, blocked_id: blocked.id})
               |> Repo.insert()

      assert %{blocker_id: ["has already blocked this user"]} = errors_on(changeset)
    end
  end
end
