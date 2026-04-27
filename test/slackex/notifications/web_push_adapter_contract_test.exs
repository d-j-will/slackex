defmodule Slackex.Notifications.WebPushAdapterContractTest do
  @moduledoc """
  Contract tests for WebPushAdapter expired-token cleanup behaviour.

  These tests lock in the contract: when web_push_elixir returns {:error, :expired}
  (which it does for both HTTP 404 and 410 responses), the adapter must delete the
  matching DeviceToken row and return :ok so Oban does not retry the job.
  """
  use Slackex.DataCase, async: false

  import Slackex.TestFactory

  alias Slackex.Notifications.{DeviceToken, WebPushAdapter}
  alias Slackex.Repo

  defmodule ExpiredPusher do
    @moduledoc false
    def send_notification(_token, _payload), do: {:error, :expired}
  end

  defmodule SuccessPusher do
    @moduledoc false
    def send_notification(_token, _payload), do: {:ok, %{status: 201}}
  end

  setup do
    # Ensure VAPID guard does not short-circuit before the adapter logic runs
    original_vapid = Application.get_env(:web_push_elixir, :vapid_public_key)
    Application.put_env(:web_push_elixir, :vapid_public_key, "test-vapid-key")

    on_exit(fn ->
      if is_nil(original_vapid) do
        Application.delete_env(:web_push_elixir, :vapid_public_key)
      else
        Application.put_env(:web_push_elixir, :vapid_public_key, original_vapid)
      end

      Application.delete_env(:slackex, :web_push_elixir_module)
    end)

    :ok
  end

  @valid_payload %{
    "title" => "Test",
    "body" => "Hello",
    "tag" => "tag:1",
    "url" => "/",
    "type" => "new_message"
  }

  describe "send_push/3 with expired subscription" do
    test "deletes the matching DeviceToken row when push service returns {:error, :expired}" do
      Application.put_env(:slackex, :web_push_elixir_module, ExpiredPusher)

      user = insert(:user)
      device_token = insert(:device_token, user: user, token: "expired-token", platform: "web")

      result = WebPushAdapter.send_push("expired-token", "web", @valid_payload)

      # Adapter swallows :expired into :ok so Oban does not retry
      assert result == :ok

      # Dead token row must be gone
      refute Repo.get(DeviceToken, device_token.id)
    end

    test "does NOT delete other users' tokens when one token expires" do
      Application.put_env(:slackex, :web_push_elixir_module, ExpiredPusher)

      user1 = insert(:user)
      user2 = insert(:user)
      stale = insert(:device_token, user: user1, token: "stale-token", platform: "web")
      keep = insert(:device_token, user: user2, token: "keep-token", platform: "web")

      WebPushAdapter.send_push("stale-token", "web", @valid_payload)

      refute Repo.get(DeviceToken, stale.id)
      assert Repo.get(DeviceToken, keep.id)
    end
  end

  describe "send_push/3 with successful delivery" do
    test "leaves the DeviceToken in place on :ok" do
      Application.put_env(:slackex, :web_push_elixir_module, SuccessPusher)

      user = insert(:user)
      kept = insert(:device_token, user: user, token: "good-token", platform: "web")

      result = WebPushAdapter.send_push("good-token", "web", @valid_payload)

      assert result == :ok
      assert Repo.get(DeviceToken, kept.id)
    end
  end
end
