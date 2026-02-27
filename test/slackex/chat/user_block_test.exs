defmodule Slackex.Chat.UserBlockTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
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

  describe "Chat.block_user/2" do
    test "creates a block and returns {:ok, block}" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:ok, block} = Chat.block_user(blocker.id, blocked.id)
      assert block.blocker_id == blocker.id
      assert block.blocked_id == blocked.id
    end

    test "duplicate block returns changeset error" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:ok, _} = Chat.block_user(blocker.id, blocked.id)
      assert {:error, changeset} = Chat.block_user(blocker.id, blocked.id)
      assert %{blocker_id: ["has already blocked this user"]} = errors_on(changeset)
    end
  end

  describe "Chat.unblock_user/2" do
    test "removes an existing block and returns :ok" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Chat.block_user(blocker.id, blocked.id)
      assert :ok = Chat.unblock_user(blocker.id, blocked.id)
      refute Chat.blocked?(blocker.id, blocked.id)
    end

    test "returns {:error, :not_found} when no block exists" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:error, :not_found} = Chat.unblock_user(blocker.id, blocked.id)
    end
  end

  describe "Chat.blocked?/2" do
    test "returns true when blocker has blocked the user" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Chat.block_user(blocker.id, blocked.id)
      assert Chat.blocked?(blocker.id, blocked.id)
    end

    test "is directional - reverse direction returns false" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Chat.block_user(blocker.id, blocked.id)
      refute Chat.blocked?(blocked.id, blocker.id)
    end

    test "returns false when no block exists" do
      user_a = insert(:user)
      user_b = insert(:user)

      refute Chat.blocked?(user_a.id, user_b.id)
    end
  end

  describe "Chat.list_blocked_users/1" do
    test "returns all blocks created by the user" do
      blocker = insert(:user)
      blocked_1 = insert(:user)
      blocked_2 = insert(:user)

      {:ok, block_1} = Chat.block_user(blocker.id, blocked_1.id)
      {:ok, block_2} = Chat.block_user(blocker.id, blocked_2.id)

      blocks = Chat.list_blocked_users(blocker.id)
      block_ids = Enum.map(blocks, & &1.id) |> Enum.sort()

      assert length(blocks) == 2
      assert block_ids == Enum.sort([block_1.id, block_2.id])
    end

    test "returns empty list when user has no blocks" do
      user = insert(:user)

      assert Chat.list_blocked_users(user.id) == []
    end

    test "does not include blocks where user is the blocked party" do
      user = insert(:user)
      other = insert(:user)

      {:ok, _} = Chat.block_user(other.id, user.id)

      assert Chat.list_blocked_users(user.id) == []
    end
  end
end
