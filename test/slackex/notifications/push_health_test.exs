defmodule Slackex.Notifications.PushHealthTest do
  use Slackex.DataCase, async: true

  import Slackex.TestFactory

  alias Slackex.Notifications.DeviceTokens
  alias Slackex.Notifications.PushHealth

  describe "derive/3" do
    test "denied permission is :browser_blocked regardless of subscription/token" do
      user = insert(:user)

      assert PushHealth.derive("denied", false, user.id) == :browser_blocked
      assert PushHealth.derive("denied", true, user.id) == :browser_blocked
    end

    test ":ok when subscribed and a device token exists" do
      user = insert(:user)
      {:ok, _} = DeviceTokens.register(user.id, "sub-1")

      assert PushHealth.derive("granted", true, user.id) == :ok
    end

    test ":not_set_up when subscribed but no token exists" do
      user = insert(:user)

      assert PushHealth.derive("granted", true, user.id) == :not_set_up
    end

    test ":not_set_up when not subscribed, even with a token present" do
      user = insert(:user)
      {:ok, _} = DeviceTokens.register(user.id, "sub-1")

      assert PushHealth.derive("default", false, user.id) == :not_set_up
    end
  end
end
