defmodule Slackex.Chat.InvitesTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
  alias Slackex.Chat.Invites

  import Slackex.TestFactory

  setup do
    owner = insert(:user)
    member = insert(:user)

    {:ok, channel} =
      Chat.create_channel(owner.id, %{
        name: "test-invites-#{System.unique_integer([:positive])}"
      })

    Chat.join_channel(member.id, channel.id)

    %{owner: owner, member: member, channel: channel}
  end

  describe "create_invite_link/3" do
    test "admin+ can create an invite link", %{channel: channel, owner: owner} do
      assert {:ok, invite} = Invites.create_invite_link(channel.id, owner.id)
      assert invite.channel_id == channel.id
      assert invite.created_by_id == owner.id
      assert String.length(invite.code) == 22
      assert invite.expires_at != nil
    end

    test "regular member cannot create invite", %{channel: channel, member: member} do
      assert {:error, :unauthorized} = Invites.create_invite_link(channel.id, member.id)
    end

    test "respects max_uses option", %{channel: channel, owner: owner} do
      assert {:ok, invite} = Invites.create_invite_link(channel.id, owner.id, max_uses: 5)
      assert invite.max_uses == 5
    end
  end

  describe "redeem_invite/2" do
    test "redeems a valid invite and joins the channel", %{channel: channel, owner: owner} do
      {:ok, invite} = Invites.create_invite_link(channel.id, owner.id)
      new_user = insert(:user)

      assert {:ok, _invite} = Invites.redeem_invite(invite.code, new_user.id)
      assert Chat.get_role(new_user.id, channel.id) == "member"
    end

    test "returns error for invalid code" do
      new_user = insert(:user)
      assert {:error, :not_found} = Invites.redeem_invite("invalid-code", new_user.id)
    end

    test "returns error when already a member", %{channel: channel, owner: owner, member: member} do
      {:ok, invite} = Invites.create_invite_link(channel.id, owner.id)
      assert {:error, :already_member} = Invites.redeem_invite(invite.code, member.id)
    end

    test "returns error when max uses reached", %{channel: channel, owner: owner} do
      {:ok, invite} = Invites.create_invite_link(channel.id, owner.id, max_uses: 1)

      user1 = insert(:user)
      assert {:ok, _} = Invites.redeem_invite(invite.code, user1.id)

      user2 = insert(:user)
      assert {:error, :max_uses_reached} = Invites.redeem_invite(invite.code, user2.id)
    end

    test "returns error when expired", %{channel: channel, owner: owner} do
      {:ok, invite} = Invites.create_invite_link(channel.id, owner.id, expires_in_hours: 0)

      # Wait a moment for expiry
      Process.sleep(10)
      new_user = insert(:user)
      assert {:error, :expired} = Invites.redeem_invite(invite.code, new_user.id)
    end
  end

  describe "list_invite_links/1" do
    test "returns invite links for a channel", %{channel: channel, owner: owner} do
      {:ok, _invite} = Invites.create_invite_link(channel.id, owner.id)
      links = Invites.list_invite_links(channel.id)

      assert length(links) == 1
      assert hd(links).created_by.id == owner.id
    end

    test "returns empty list when no invites", %{channel: channel} do
      assert Invites.list_invite_links(channel.id) == []
    end
  end

  describe "revoke_invite_link/2" do
    test "admin+ can revoke an invite", %{channel: channel, owner: owner} do
      {:ok, invite} = Invites.create_invite_link(channel.id, owner.id)
      assert {:ok, _} = Invites.revoke_invite_link(invite.id, owner.id)
      assert Invites.list_invite_links(channel.id) == []
    end

    test "regular member cannot revoke", %{channel: channel, owner: owner, member: member} do
      {:ok, invite} = Invites.create_invite_link(channel.id, owner.id)
      assert {:error, :unauthorized} = Invites.revoke_invite_link(invite.id, member.id)
    end
  end
end
