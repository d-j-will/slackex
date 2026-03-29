defmodule Slackex.NotificationsTest do
  use Slackex.DataCase, async: false

  import Slackex.TestFactory

  alias Slackex.Chat
  alias Slackex.Notifications.{DeviceToken, OnlineTracker, PushWorker}
  alias Slackex.PushCapture
  alias Slackex.Repo

  setup do
    # Clean Redis online keys between tests
    Enum.each(0..9, fn i ->
      {:ok, keys} = Redix.command(:"redix_#{i}", ["KEYS", "online:*"])
      Enum.each(keys, fn k -> Redix.command(:"redix_#{i}", ["DEL", k]) end)
    end)

    # Register push capture adapter
    original = Application.get_env(:slackex, :push_adapter)
    Application.put_env(:slackex, :push_adapter, PushCapture)
    PushCapture.register()

    on_exit(fn ->
      PushCapture.unregister()

      if original do
        Application.put_env(:slackex, :push_adapter, original)
      else
        Application.delete_env(:slackex, :push_adapter)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # DeviceToken schema
  # ---------------------------------------------------------------------------

  describe "DeviceToken changeset" do
    test "valid with all required fields" do
      user = insert(:user)
      attrs = %{user_id: user.id, token: "abc123", platform: "fcm"}
      assert %{valid?: true} = DeviceToken.changeset(%DeviceToken{}, attrs)
    end

    test "valid with apns platform" do
      user = insert(:user)
      attrs = %{user_id: user.id, token: "apns-token", platform: "apns"}
      assert %{valid?: true} = DeviceToken.changeset(%DeviceToken{}, attrs)
    end

    test "invalid without token" do
      user = insert(:user)
      changeset = DeviceToken.changeset(%DeviceToken{}, %{user_id: user.id, platform: "fcm"})
      assert "can't be blank" in errors_on(changeset).token
    end

    test "invalid without platform" do
      user = insert(:user)
      changeset = DeviceToken.changeset(%DeviceToken{}, %{user_id: user.id, token: "tok"})
      assert "can't be blank" in errors_on(changeset).platform
    end

    test "invalid platform value rejected" do
      user = insert(:user)

      changeset =
        DeviceToken.changeset(%DeviceToken{}, %{
          user_id: user.id,
          token: "tok",
          platform: "safari"
        })

      assert "is invalid" in errors_on(changeset).platform
    end

    test "token uniqueness constraint enforced" do
      user = insert(:user)
      insert(:device_token, user: user, token: "dup-token", platform: "fcm")

      {:error, changeset} =
        %DeviceToken{}
        |> DeviceToken.changeset(%{user_id: user.id, token: "dup-token", platform: "apns"})
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token
    end

    test "deleting user cascades to device tokens" do
      user = insert(:user)
      dt = insert(:device_token, user: user)

      Repo.delete!(user)

      assert Repo.get(DeviceToken, dt.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # OnlineTracker
  # ---------------------------------------------------------------------------

  describe "OnlineTracker" do
    test "mark_online makes user appear online" do
      user = insert(:user)
      refute OnlineTracker.online?(user.id)

      :ok = OnlineTracker.mark_online(user.id)
      assert OnlineTracker.online?(user.id)
    end

    test "mark_offline removes online status" do
      user = insert(:user)
      OnlineTracker.mark_online(user.id)

      :ok = OnlineTracker.mark_offline(user.id)
      refute OnlineTracker.online?(user.id)
    end

    test "refresh keeps user online" do
      user = insert(:user)
      OnlineTracker.mark_online(user.id)

      :ok = OnlineTracker.refresh(user.id)
      assert OnlineTracker.online?(user.id)
    end

    test "online? returns false for unknown user" do
      refute OnlineTracker.online?(999_999_999)
    end

    test "multiple users tracked independently" do
      u1 = insert(:user)
      u2 = insert(:user)
      OnlineTracker.mark_online(u1.id)

      assert OnlineTracker.online?(u1.id)
      refute OnlineTracker.online?(u2.id)
    end
  end

  # ---------------------------------------------------------------------------
  # PushWorker — new_message
  # ---------------------------------------------------------------------------

  describe "PushWorker new_message" do
    test "dispatches push to offline subscribers, skips sender" do
      sender = insert(:user)
      offline_user = insert(:user)

      {:ok, channel} =
        Chat.create_channel(sender.id, %{name: "push-ch-#{System.unique_integer()}"})

      Chat.join_channel(offline_user.id, channel.id)
      insert(:device_token, user: offline_user, token: "offline-tok", platform: "fcm")

      assert :ok ==
               PushWorker.perform(%Oban.Job{
                 args: %{
                   "type" => "new_message",
                   "channel_id" => channel.id,
                   "sender_id" => sender.id,
                   "content" => "Hello",
                   "sender_username" => sender.username
                 }
               })

      pushes = PushCapture.collect()
      assert Enum.any?(pushes, &(&1.token == "offline-tok"))
    end

    test "skips online subscribers" do
      sender = insert(:user)
      online_user = insert(:user)

      {:ok, channel} =
        Chat.create_channel(sender.id, %{name: "push-online-#{System.unique_integer()}"})

      Chat.join_channel(online_user.id, channel.id)
      insert(:device_token, user: online_user, token: "online-tok", platform: "fcm")
      OnlineTracker.mark_online(online_user.id)

      PushWorker.perform(%Oban.Job{
        args: %{
          "type" => "new_message",
          "channel_id" => channel.id,
          "sender_id" => sender.id,
          "content" => "Hi",
          "sender_username" => sender.username
        }
      })

      pushes = PushCapture.collect()
      refute Enum.any?(pushes, &(&1.token == "online-tok"))
    end

    test "does not send to sender even if sender has a device token" do
      sender = insert(:user)
      insert(:device_token, user: sender, token: "sender-tok", platform: "fcm")

      {:ok, channel} =
        Chat.create_channel(sender.id, %{name: "push-nosender-#{System.unique_integer()}"})

      PushWorker.perform(%Oban.Job{
        args: %{
          "type" => "new_message",
          "channel_id" => channel.id,
          "sender_id" => sender.id,
          "content" => "Test",
          "sender_username" => sender.username
        }
      })

      pushes = PushCapture.collect()
      refute Enum.any?(pushes, &(&1.token == "sender-tok"))
    end

    test "body is truncated to 100 characters" do
      sender = insert(:user)
      recipient = insert(:user)

      {:ok, channel} =
        Chat.create_channel(sender.id, %{name: "trunc-#{System.unique_integer()}"})

      Chat.join_channel(recipient.id, channel.id)
      insert(:device_token, user: recipient, token: "trunc-tok", platform: "apns")

      long_content = String.duplicate("x", 200)

      PushWorker.perform(%Oban.Job{
        args: %{
          "type" => "new_message",
          "channel_id" => channel.id,
          "sender_id" => sender.id,
          "content" => long_content,
          "sender_username" => "bob"
        }
      })

      pushes = PushCapture.collect()
      [push] = Enum.filter(pushes, &(&1.token == "trunc-tok"))
      assert byte_size(push.body) == 100
    end

    test "title includes channel name with # prefix" do
      sender = insert(:user)
      recipient = insert(:user)

      {:ok, channel} =
        Chat.create_channel(sender.id, %{name: "my-channel-#{System.unique_integer()}"})

      Chat.join_channel(recipient.id, channel.id)
      insert(:device_token, user: recipient, token: "title-tok", platform: "fcm")

      PushWorker.perform(%Oban.Job{
        args: %{
          "type" => "new_message",
          "channel_id" => channel.id,
          "sender_id" => sender.id,
          "content" => "Hey",
          "sender_username" => sender.username
        }
      })

      pushes = PushCapture.collect()
      [push] = Enum.filter(pushes, &(&1.token == "title-tok"))
      assert String.starts_with?(push.title, "#")
    end
  end

  # ---------------------------------------------------------------------------
  # PushWorker — new_dm
  # ---------------------------------------------------------------------------

  describe "PushWorker new_dm" do
    test "sends to offline DM recipient" do
      {dm, sender, recipient} = make_dm()
      insert(:device_token, user: recipient, token: "dm-tok", platform: "fcm")

      assert :ok ==
               PushWorker.perform(%Oban.Job{
                 args: %{
                   "type" => "new_dm",
                   "dm_conversation_id" => dm.id,
                   "sender_id" => sender.id,
                   "content" => "Hey!",
                   "sender_username" => sender.username
                 }
               })

      pushes = PushCapture.collect()
      assert Enum.any?(pushes, &(&1.token == "dm-tok"))
    end

    test "skips push when DM recipient is online" do
      {dm, sender, recipient} = make_dm()
      insert(:device_token, user: recipient, token: "dm-online-tok", platform: "fcm")
      OnlineTracker.mark_online(recipient.id)

      PushWorker.perform(%Oban.Job{
        args: %{
          "type" => "new_dm",
          "dm_conversation_id" => dm.id,
          "sender_id" => sender.id,
          "content" => "Hi!",
          "sender_username" => sender.username
        }
      })

      pushes = PushCapture.collect()
      assert pushes == []
    end

    test "recipient is determined from dm conversation (user_b sends, user_a receives)" do
      user_a = insert(:user)
      user_b = insert(:user)
      # find_or_create_dm normalises order so user_a_id < user_b_id
      {:ok, dm} = Chat.find_or_create_dm(user_a.id, user_b.id)

      dm = Repo.reload!(dm)
      sender_id = dm.user_b_id
      recipient = Repo.get!(Slackex.Accounts.User, dm.user_a_id)

      insert(:device_token, user: recipient, token: "recv-tok", platform: "fcm")

      PushWorker.perform(%Oban.Job{
        args: %{
          "type" => "new_dm",
          "dm_conversation_id" => dm.id,
          "sender_id" => sender_id,
          "content" => "Hello from b",
          "sender_username" => "userb"
        }
      })

      pushes = PushCapture.collect()
      assert Enum.any?(pushes, &(&1.token == "recv-tok"))
    end
  end

  # ---------------------------------------------------------------------------
  # PushWorker — deleted target graceful discard
  # ---------------------------------------------------------------------------

  describe "PushWorker deleted target" do
    test "returns :ok without crashing when channel has been deleted" do
      assert :ok ==
               PushWorker.perform(%Oban.Job{
                 args: %{
                   "type" => "new_message",
                   "channel_id" => 999_999_999,
                   "sender_id" => 1,
                   "content" => "Hello",
                   "sender_username" => "ghost"
                 }
               })
    end

    test "returns :ok without crashing when DM conversation has been deleted" do
      assert :ok ==
               PushWorker.perform(%Oban.Job{
                 args: %{
                   "type" => "new_dm",
                   "dm_conversation_id" => 999_999_999,
                   "sender_id" => 1,
                   "content" => "Hey",
                   "sender_username" => "ghost"
                 }
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp make_dm do
    sender = insert(:user)
    recipient = insert(:user)
    {:ok, dm} = Chat.find_or_create_dm(sender.id, recipient.id)
    dm = Repo.reload!(dm)
    sender = if dm.user_a_id == sender.id, do: sender, else: recipient
    recipient = if dm.user_a_id == sender.id, do: recipient, else: sender
    {dm, sender, recipient}
  end
end
