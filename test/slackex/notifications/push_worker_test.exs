defmodule Slackex.Notifications.PushWorkerTest do
  @moduledoc """
  Tests for `PushWorker.perform/1` error propagation and fan-out semantics.

  These tests exist to prevent regression of the v0.5.36-style silent-failure
  pattern: a worker that always returns `:ok` despite dispatch errors, so
  `max_attempts` never triggers.
  """
  use Slackex.DataCase, async: false

  alias Slackex.Notifications.PushWorker

  defmodule StubAdapter do
    @moduledoc false

    def send_push(token, _platform, _payload) do
      Process.put(:push_calls, [token | Process.get(:push_calls, [])])

      case Process.get({:outcome, token}, :ok) do
        :raise -> raise "boom"
        other -> other
      end
    end
  end

  setup do
    FunWithFlags.enable(:push_notifications)
    previous = Application.get_env(:slackex, :push_adapter)
    Application.put_env(:slackex, :push_adapter, StubAdapter)
    Process.put(:push_calls, [])

    on_exit(fn ->
      FunWithFlags.disable(:push_notifications)

      case previous do
        nil -> Application.delete_env(:slackex, :push_adapter)
        mod -> Application.put_env(:slackex, :push_adapter, mod)
      end
    end)

    :ok
  end

  describe "perform/1 channel push error propagation" do
    test "returns {:error, _} and still attempts every subscriber when one fails" do
      sender = insert(:user)
      sub_a = insert(:user)
      sub_b = insert(:user)
      channel = insert(:channel)

      insert(:subscription, user: sender, channel: channel)
      insert(:subscription, user: sub_a, channel: channel)
      insert(:subscription, user: sub_b, channel: channel)

      insert(:device_token, user: sub_a, token: "tok-a")
      insert(:device_token, user: sub_b, token: "tok-b")

      Process.put({:outcome, "tok-a"}, {:error, :fcm_unavailable})

      job = build_job(channel.id, sender)

      assert {:error, :fcm_unavailable} = PushWorker.perform(job)

      calls = Process.get(:push_calls)
      assert "tok-a" in calls, "failed subscriber was attempted"
      assert "tok-b" in calls, "fan-out: later subscribers attempted despite earlier error"
    end

    test "fans out across a single user's tokens when one token errors" do
      sender = insert(:user)
      sub = insert(:user)
      channel = insert(:channel)

      insert(:subscription, user: sender, channel: channel)
      insert(:subscription, user: sub, channel: channel)

      insert(:device_token, user: sub, token: "device-1")
      insert(:device_token, user: sub, token: "device-2")
      insert(:device_token, user: sub, token: "device-3")

      Process.put({:outcome, "device-2"}, {:error, :transient})

      assert {:error, :transient} = PushWorker.perform(build_job(channel.id, sender))

      calls = Process.get(:push_calls)
      assert "device-1" in calls
      assert "device-2" in calls
      assert "device-3" in calls
    end

    test "returns :ok when every dispatch succeeds" do
      sender = insert(:user)
      sub = insert(:user)
      channel = insert(:channel)

      insert(:subscription, user: sender, channel: channel)
      insert(:subscription, user: sub, channel: channel)
      insert(:device_token, user: sub, token: "good-token")

      assert PushWorker.perform(build_job(channel.id, sender)) == :ok
    end

    test "rescues adapter exceptions into {:error, {:exception, module}}" do
      sender = insert(:user)
      sub = insert(:user)
      channel = insert(:channel)

      insert(:subscription, user: sender, channel: channel)
      insert(:subscription, user: sub, channel: channel)
      insert(:device_token, user: sub, token: "bad-token")

      Process.put({:outcome, "bad-token"}, :raise)

      assert {:error, {:exception, RuntimeError}} =
               PushWorker.perform(build_job(channel.id, sender))
    end
  end

  describe "perform/1 DM push error propagation" do
    test "returns {:error, _} when adapter fails for the DM recipient" do
      dm = insert(:dm_conversation)
      insert(:device_token, user: dm.user_b, token: "dm-tok")
      Process.put({:outcome, "dm-tok"}, {:error, :vapid_not_configured})

      job = %Oban.Job{
        args: %{
          "type" => "new_dm",
          "dm_conversation_id" => dm.id,
          "sender_id" => dm.user_a_id,
          "content" => "hi",
          "sender_username" => dm.user_a.username
        }
      }

      assert {:error, :vapid_not_configured} = PushWorker.perform(job)
    end
  end

  defp build_job(channel_id, sender) do
    %Oban.Job{
      args: %{
        "type" => "new_message",
        "channel_id" => channel_id,
        "sender_id" => sender.id,
        "content" => "hi everyone",
        "sender_username" => sender.username
      }
    }
  end
end
