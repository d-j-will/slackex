defmodule Slackex.Chat.PermissionsTest do
  use ExUnit.Case, async: true

  alias Slackex.Chat.Permissions

  describe "can?/2 — owner" do
    test "owners can send messages" do
      assert Permissions.can?("owner", :send_message)
    end

    test "owners can read messages" do
      assert Permissions.can?("owner", :read_messages)
    end

    test "owners can manage channels" do
      assert Permissions.can?("owner", :manage_channel)
    end

    test "owners can delete channels" do
      assert Permissions.can?("owner", :delete_channel)
    end

    test "owners can edit own messages" do
      assert Permissions.can?("owner", :edit_own_message)
    end

    test "owners can delete own messages" do
      assert Permissions.can?("owner", :delete_own_message)
    end

    test "owners can delete any message" do
      assert Permissions.can?("owner", :delete_any_message)
    end
  end

  describe "can?/2 — admin" do
    test "admins can send messages" do
      assert Permissions.can?("admin", :send_message)
    end

    test "admins can read messages" do
      assert Permissions.can?("admin", :read_messages)
    end

    test "admins can manage channels" do
      assert Permissions.can?("admin", :manage_channel)
    end

    test "admins cannot delete channels" do
      refute Permissions.can?("admin", :delete_channel)
    end

    test "admins can edit own messages" do
      assert Permissions.can?("admin", :edit_own_message)
    end

    test "admins can delete own messages" do
      assert Permissions.can?("admin", :delete_own_message)
    end

    test "admins can delete any message" do
      assert Permissions.can?("admin", :delete_any_message)
    end
  end

  describe "can?/2 — member" do
    test "members can send messages" do
      assert Permissions.can?("member", :send_message)
    end

    test "members can read messages" do
      assert Permissions.can?("member", :read_messages)
    end

    test "members cannot manage channels" do
      refute Permissions.can?("member", :manage_channel)
    end

    test "members cannot delete channels" do
      refute Permissions.can?("member", :delete_channel)
    end

    test "members can edit own messages" do
      assert Permissions.can?("member", :edit_own_message)
    end

    test "members can delete own messages" do
      assert Permissions.can?("member", :delete_own_message)
    end

    test "members cannot delete any message" do
      refute Permissions.can?("member", :delete_any_message)
    end
  end

  describe "can?/2 — viewer" do
    test "viewers cannot send messages" do
      refute Permissions.can?("viewer", :send_message)
    end

    test "viewers can read messages" do
      assert Permissions.can?("viewer", :read_messages)
    end

    test "viewers cannot manage channels" do
      refute Permissions.can?("viewer", :manage_channel)
    end

    test "viewers cannot delete channels" do
      refute Permissions.can?("viewer", :delete_channel)
    end

    test "viewers cannot edit own messages" do
      refute Permissions.can?("viewer", :edit_own_message)
    end

    test "viewers cannot delete own messages" do
      refute Permissions.can?("viewer", :delete_own_message)
    end

    test "viewers cannot delete any message" do
      refute Permissions.can?("viewer", :delete_any_message)
    end
  end

  describe "can?/2 — nil (non-member)" do
    test "nil role cannot send messages" do
      refute Permissions.can?(nil, :send_message)
    end

    test "nil role cannot read messages" do
      refute Permissions.can?(nil, :read_messages)
    end

    test "nil role cannot manage channels" do
      refute Permissions.can?(nil, :manage_channel)
    end

    test "nil role cannot delete channels" do
      refute Permissions.can?(nil, :delete_channel)
    end

    test "nil role cannot edit own messages" do
      refute Permissions.can?(nil, :edit_own_message)
    end

    test "nil role cannot delete own messages" do
      refute Permissions.can?(nil, :delete_own_message)
    end

    test "nil role cannot delete any message" do
      refute Permissions.can?(nil, :delete_any_message)
    end
  end
end
