defmodule Slackex.Notifications.DeviceTokensTest do
  use Slackex.DataCase, async: true

  import Slackex.TestFactory

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Notifications.DeviceTokens
  alias Slackex.Repo

  describe "register/2" do
    test "inserts a web_push token for a new subscription" do
      user = insert(:user)

      assert {:ok, token} = DeviceTokens.register(user.id, "sub-json-1")
      assert token.user_id == user.id
      assert token.token == "sub-json-1"
      assert token.platform == "web_push"
      assert token.device_name == "PWA"
    end

    test "is idempotent on {token, user_id} — refreshes rather than duplicating" do
      user = insert(:user)

      assert {:ok, _} = DeviceTokens.register(user.id, "sub-json-1")
      assert {:ok, _} = DeviceTokens.register(user.id, "sub-json-1")
      assert Repo.aggregate(DeviceToken, :count) == 1
    end
  end

  describe "remove/2" do
    test "deletes a matching token and returns :ok" do
      user = insert(:user)
      {:ok, _} = DeviceTokens.register(user.id, "sub-json-1")

      assert :ok = DeviceTokens.remove(user.id, "sub-json-1")
      refute DeviceTokens.exists?(user.id)
    end

    test "is a no-op (:ok) when no matching token exists" do
      user = insert(:user)

      assert :ok = DeviceTokens.remove(user.id, "absent")
    end
  end

  describe "exists?/1" do
    test "false when the user has no tokens" do
      user = insert(:user)

      refute DeviceTokens.exists?(user.id)
    end

    test "true once a token is registered" do
      user = insert(:user)
      {:ok, _} = DeviceTokens.register(user.id, "sub-json-1")

      assert DeviceTokens.exists?(user.id)
    end
  end

  describe "maybe_heal/3" do
    test "inserts a missing token when subscribed and returns :healed" do
      user = insert(:user)

      assert :healed = DeviceTokens.maybe_heal(user.id, true, "sub-json-1")
      assert DeviceTokens.exists?(user.id)
    end

    test "is a no-op when a matching token already exists" do
      user = insert(:user)
      {:ok, _} = DeviceTokens.register(user.id, "sub-json-1")

      assert :noop = DeviceTokens.maybe_heal(user.id, true, "sub-json-1")
      assert Repo.aggregate(DeviceToken, :count) == 1
    end

    test "is a no-op when the client is not subscribed" do
      user = insert(:user)

      assert :noop = DeviceTokens.maybe_heal(user.id, false, "sub-json-1")
      refute DeviceTokens.exists?(user.id)
    end

    test "is a no-op when the subscription is nil" do
      user = insert(:user)

      assert :noop = DeviceTokens.maybe_heal(user.id, true, nil)
      refute DeviceTokens.exists?(user.id)
    end
  end
end
