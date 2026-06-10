defmodule Slackex.Chat.MembersTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
  alias Slackex.Chat.Members
  alias Slackex.Integrations.McpTokens

  import Slackex.TestFactory

  setup do
    owner = insert(:user)
    admin = insert(:user)
    member = insert(:user)

    {:ok, channel} =
      Chat.create_channel(owner.id, %{name: "test-members-#{System.unique_integer([:positive])}"})

    Chat.join_channel(admin.id, channel.id)
    Chat.join_channel(member.id, channel.id)

    # Promote admin
    Members.update_member_role(channel.id, owner.id, admin.id, "admin")

    %{owner: owner, admin: admin, member: member, channel: channel}
  end

  describe "list_members/1" do
    test "returns all members with roles", %{channel: channel} do
      members = Members.list_members(channel.id)
      assert length(members) == 3
      assert Enum.any?(members, fn m -> m.role == "owner" end)
      assert Enum.any?(members, fn m -> m.role == "admin" end)
      assert Enum.any?(members, fn m -> m.role == "member" end)
    end

    test "returns empty list for channel with no members" do
      assert Members.list_members(-1) == []
    end
  end

  describe "update_member_role/4" do
    test "admin can promote member to admin", %{channel: channel, admin: admin, member: member} do
      assert {:ok, "admin"} = Members.update_member_role(channel.id, admin.id, member.id, "admin")
    end

    test "regular member cannot update roles", %{channel: channel, member: member, admin: admin} do
      assert {:error, :unauthorized} =
               Members.update_member_role(channel.id, member.id, admin.id, "member")
    end

    test "cannot modify owner role", %{channel: channel, admin: admin, owner: owner} do
      assert {:error, :cannot_modify_owner} =
               Members.update_member_role(channel.id, admin.id, owner.id, "member")
    end

    test "returns error for non-member target", %{channel: channel, owner: owner} do
      non_member = insert(:user)

      assert {:error, :not_a_member} =
               Members.update_member_role(channel.id, owner.id, non_member.id, "admin")
    end
  end

  describe "kick_member/3" do
    test "admin can kick a member", %{channel: channel, admin: admin, member: member} do
      assert :ok = Members.kick_member(channel.id, admin.id, member.id)
      assert Chat.get_role(member.id, channel.id) == nil
    end

    test "regular member cannot kick", %{channel: channel, member: member, admin: admin} do
      assert {:error, :unauthorized} = Members.kick_member(channel.id, member.id, admin.id)
    end

    test "cannot kick owner", %{channel: channel, admin: admin, owner: owner} do
      assert {:error, :cannot_kick_owner} = Members.kick_member(channel.id, admin.id, owner.id)
    end

    test "returns error for non-member target", %{channel: channel, owner: owner} do
      non_member = insert(:user)
      assert {:error, :not_a_member} = Members.kick_member(channel.id, owner.id, non_member.id)
    end
  end

  describe "add_bot_member/3" do
    setup %{} do
      # Bot created through the production path (token mint), not a fixture.
      {:ok, %{bot_user: bot}} =
        McpTokens.create_mcp_token(%{
          name: "helper-#{System.unique_integer([:positive])}"
        })

      %{bot: bot}
    end

    test "owner subscribes a bot with role member", %{channel: channel, owner: owner, bot: bot} do
      assert {:ok, %Slackex.Chat.Subscription{role: "member"}} =
               Members.add_bot_member(channel.id, owner.id, bot.id)
    end

    test "admin may also subscribe a bot", %{channel: channel, admin: admin, bot: bot} do
      assert {:ok, %Slackex.Chat.Subscription{}} =
               Members.add_bot_member(channel.id, admin.id, bot.id)
    end

    test "plain member is unauthorized", %{channel: channel, member: member, bot: bot} do
      assert {:error, :unauthorized} = Members.add_bot_member(channel.id, member.id, bot.id)
    end

    test "private channel is rejected", %{owner: owner, bot: bot} do
      {:ok, private} =
        Chat.create_channel(owner.id, %{
          name: "secret-#{System.unique_integer([:positive])}",
          is_private: true
        })

      assert {:error, :private_channel_not_supported} =
               Members.add_bot_member(private.id, owner.id, bot.id)
    end

    test "non-bot target is rejected", %{channel: channel, owner: owner, member: member} do
      assert {:error, :not_a_bot} = Members.add_bot_member(channel.id, owner.id, member.id)
    end

    test "subscribing twice is idempotent", %{channel: channel, owner: owner, bot: bot} do
      assert {:ok, %Slackex.Chat.Subscription{}} =
               Members.add_bot_member(channel.id, owner.id, bot.id)

      assert {:ok, :already_subscribed} = Members.add_bot_member(channel.id, owner.id, bot.id)
    end
  end

  describe "remove_bot_member/3" do
    setup %{channel: channel, owner: owner} do
      {:ok, %{bot_user: bot}} =
        McpTokens.create_mcp_token(%{
          name: "helper-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Members.add_bot_member(channel.id, owner.id, bot.id)
      %{bot: bot}
    end

    test "owner removes a subscribed bot", %{channel: channel, owner: owner, bot: bot} do
      assert :ok = Members.remove_bot_member(channel.id, owner.id, bot.id)
      refute Enum.any?(Members.list_members(channel.id), &(&1.user.id == bot.id))
    end

    test "removing an unsubscribed bot reports not_a_member", %{
      channel: channel,
      owner: owner,
      bot: bot
    } do
      :ok = Members.remove_bot_member(channel.id, owner.id, bot.id)
      assert {:error, :not_a_member} = Members.remove_bot_member(channel.id, owner.id, bot.id)
    end

    test "plain member is unauthorized", %{channel: channel, member: member, bot: bot} do
      assert {:error, :unauthorized} = Members.remove_bot_member(channel.id, member.id, bot.id)
    end

    test "non-bot target is rejected even if subscribed", %{
      channel: channel,
      owner: owner,
      member: member
    } do
      assert {:error, :not_a_bot} = Members.remove_bot_member(channel.id, owner.id, member.id)
    end
  end
end
