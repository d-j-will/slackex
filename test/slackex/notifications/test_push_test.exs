defmodule Slackex.Notifications.TestPushTest do
  use Slackex.DataCase, async: false
  import Slackex.TestFactory

  alias Slackex.Notifications.TestPush

  setup do
    Process.put(:push_test_pid, self())
    :ok
  end

  test "returns {:ok, 0} when the user has no tokens" do
    user = insert(:user)
    assert {:ok, 0} = TestPush.send(user.id)
    refute_received {:stub_push_sent, _, _}
  end

  test "fans out to every token registered for the user" do
    user = insert(:user)
    insert(:device_token, user: user, token: "token-a", platform: "web_push")
    insert(:device_token, user: user, token: "token-b", platform: "web_push")
    other = insert(:user)
    insert(:device_token, user: other, token: "token-other", platform: "web_push")

    assert {:ok, 2} = TestPush.send(user.id)

    assert_received {:stub_push_sent, "token-a", payload}
    assert_received {:stub_push_sent, "token-b", _}
    refute_received {:stub_push_sent, "token-other", _}
    assert payload["title"] == "Tenun test notification"
    assert payload["type"] == "test"
  end

  test "returns {:error, reason} when adapter fails" do
    defmodule AlwaysFailAdapter do
      def send_push(_token, _platform, _payload), do: {:error, :boom}
    end

    original = Application.get_env(:slackex, :push_adapter)
    Application.put_env(:slackex, :push_adapter, AlwaysFailAdapter)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:slackex, :push_adapter)
        mod -> Application.put_env(:slackex, :push_adapter, mod)
      end
    end)

    user = insert(:user)
    insert(:device_token, user: user, token: "token-a", platform: "web_push")

    assert {:error, _} = TestPush.send(user.id)
  end
end
