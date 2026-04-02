defmodule Slackex.Notifications.PushNotificationsIntegrationTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Notifications.{Preference, DeviceToken, WebPushAdapter, Mention}

  setup do
    FunWithFlags.enable(:push_notifications)
    on_exit(fn -> FunWithFlags.disable(:push_notifications) end)
    :ok
  end

  describe "preference resolution" do
    test "per-channel overrides global default" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_global_default(user.id, "all")
      Preference.set_preference(user.id, channel.id, "nothing")

      assert Preference.resolve_level(user.id, channel.id) == "nothing"
    end

    test "falls back to global when no per-channel preference" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_global_default(user.id, "mentions")

      assert Preference.resolve_level(user.id, channel.id) == "mentions"
    end

    test "defaults to 'all' when no preferences exist at all" do
      user = insert(:user)
      channel = insert(:channel)

      assert Preference.resolve_level(user.id, channel.id) == "all"
    end
  end

  describe "mention detection" do
    test "detects mentions with word boundaries" do
      assert Mention.mentioned?("hey @alice check this", "alice")
      refute Mention.mentioned?("paying with cash", "ash")
      refute Mention.mentioned?("email bob@example.com", "bob")
    end
  end

  describe "WebPushAdapter payload contract" do
    test "payload contains all required fields for service worker" do
      payload = %{
        "title" => "#general",
        "body" => "alice: test message",
        "tag" => "channel:123",
        "url" => "/chat/general",
        "type" => "new_message"
      }

      json = WebPushAdapter.build_payload(payload)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "title")
      assert Map.has_key?(decoded, "body")
      assert Map.has_key?(decoded, "tag")
      assert Map.has_key?(decoded, "url")
      assert Map.has_key?(decoded, "type")
    end

    test "payload values match input" do
      payload = %{
        "title" => "Test",
        "body" => "Hello",
        "tag" => "dm:1",
        "url" => "/chat/dm/1",
        "type" => "new_dm"
      }

      json = WebPushAdapter.build_payload(payload)
      decoded = Jason.decode!(json)

      assert decoded["title"] == "Test"
      assert decoded["body"] == "Hello"
      assert decoded["tag"] == "dm:1"
      assert decoded["url"] == "/chat/dm/1"
      assert decoded["type"] == "new_dm"
    end
  end

  describe "device token platform" do
    test "accepts web_push platform" do
      user = insert(:user)

      subscription =
        Jason.encode!(%{
          endpoint: "https://push.example.com/sub/123",
          keys: %{p256dh: "publickey", auth: "authsecret"}
        })

      changeset =
        DeviceToken.changeset(%DeviceToken{}, %{
          user_id: user.id,
          token: subscription,
          platform: "web_push"
        })

      assert changeset.valid?
    end

    test "still accepts fcm and apns platforms" do
      user = insert(:user)

      fcm =
        DeviceToken.changeset(%DeviceToken{}, %{
          user_id: user.id,
          token: "fcm-token-123",
          platform: "fcm"
        })

      assert fcm.valid?

      apns =
        DeviceToken.changeset(%DeviceToken{}, %{
          user_id: user.id,
          token: "apns-token-123",
          platform: "apns"
        })

      assert apns.valid?
    end

    test "rejects invalid platform" do
      user = insert(:user)

      changeset =
        DeviceToken.changeset(%DeviceToken{}, %{
          user_id: user.id,
          token: "token",
          platform: "invalid"
        })

      refute changeset.valid?
    end
  end

  describe "preference + mention integration" do
    test "mentions level with mentioned user should notify" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_preference(user.id, channel.id, "mentions")

      level = Preference.resolve_level(user.id, channel.id)
      content = "hey @#{user.username} check this out"

      should_notify =
        level == "all" or (level == "mentions" and Mention.mentioned?(content, user.username))

      assert should_notify
    end

    test "mentions level without mention should not notify" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_preference(user.id, channel.id, "mentions")

      level = Preference.resolve_level(user.id, channel.id)
      content = "just a regular message"

      should_notify =
        level == "all" or (level == "mentions" and Mention.mentioned?(content, user.username))

      refute should_notify
    end

    test "nothing level should never notify" do
      user = insert(:user)
      channel = insert(:channel)

      Preference.set_preference(user.id, channel.id, "nothing")

      level = Preference.resolve_level(user.id, channel.id)
      refute level == "all"
      refute level == "mentions"
    end
  end
end
