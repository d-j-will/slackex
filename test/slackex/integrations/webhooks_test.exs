defmodule Slackex.Integrations.WebhooksTest do
  use Slackex.DataCase, async: true

  alias Slackex.Integrations.Webhook
  alias Slackex.Integrations.Webhooks

  describe "create_webhook/1" do
    test "creates webhook with bot user and channel subscription atomically" do
      user = insert(:user)
      channel = insert(:channel, creator: user, is_private: false)

      assert {:ok, %{webhook: webhook, token: raw_token}} =
               Webhooks.create_webhook(%{name: "Deploy Bot", channel_id: channel.id})

      # Webhook persisted with correct associations
      assert webhook.name == "Deploy Bot"
      assert webhook.channel_id == channel.id
      assert webhook.is_active == true
      assert webhook.bot_user_id != nil

      # Raw token returned (not the hash)
      assert is_binary(raw_token)
      assert byte_size(raw_token) > 0
      assert webhook.token_hash == Webhooks.hash_token(raw_token)

      # Bot user created with is_bot flag
      bot_user = Slackex.Accounts.get_user!(webhook.bot_user_id)
      assert bot_user.is_bot == true
      assert bot_user.username == "webhook-deploy-bot"
      assert bot_user.display_name == "Deploy Bot"

      # Bot user subscribed to channel
      role = Slackex.Chat.Channels.get_role(bot_user.id, channel.id)
      assert role == "member"
    end

    test "returns raw token that differs from stored hash" do
      user = insert(:user)
      channel = insert(:channel, creator: user, is_private: false)

      {:ok, %{webhook: webhook, token: raw_token}} =
        Webhooks.create_webhook(%{name: "CI Bot", channel_id: channel.id})

      assert raw_token != webhook.token_hash
      assert Webhooks.hash_token(raw_token) == webhook.token_hash
    end

    test "rejects private channels" do
      user = insert(:user)
      channel = insert(:channel, creator: user, is_private: true)

      assert {:error, :private_channel_not_supported} =
               Webhooks.create_webhook(%{name: "Secret Bot", channel_id: channel.id})
    end

    test "returns error for non-existent channel" do
      assert {:error, :channel_not_found} =
               Webhooks.create_webhook(%{name: "Ghost Bot", channel_id: 999_999})
    end

    test "sanitizes webhook name into valid bot username" do
      user = insert(:user)
      channel = insert(:channel, creator: user, is_private: false)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(%{name: "My Cool Bot!!", channel_id: channel.id})

      bot_user = Slackex.Accounts.get_user!(webhook.bot_user_id)
      assert bot_user.username == "webhook-my-cool-bot"
    end
  end

  describe "get_by_token_hash/1" do
    test "finds active webhook by token hash with preloaded associations" do
      user = insert(:user)
      channel = insert(:channel, creator: user, is_private: false)

      {:ok, %{webhook: _webhook, token: raw_token}} =
        Webhooks.create_webhook(%{name: "Lookup Bot", channel_id: channel.id})

      hash = Webhooks.hash_token(raw_token)
      found = Webhooks.get_by_token_hash(hash)

      assert found != nil
      assert found.name == "Lookup Bot"
      assert found.is_active == true
      assert found.channel.id == channel.id
      assert found.bot_user.is_bot == true
    end

    test "returns nil for inactive webhook" do
      user = insert(:user)
      channel = insert(:channel, creator: user, is_private: false)

      {:ok, %{webhook: webhook, token: raw_token}} =
        Webhooks.create_webhook(%{name: "Deactivated Bot", channel_id: channel.id})

      # Deactivate the webhook
      webhook
      |> Webhook.changeset(%{is_active: false})
      |> Repo.update!()

      hash = Webhooks.hash_token(raw_token)
      assert Webhooks.get_by_token_hash(hash) == nil
    end

    test "returns nil for unknown hash" do
      assert Webhooks.get_by_token_hash("nonexistent_hash") == nil
    end
  end

  describe "hash_token/1" do
    test "produces consistent SHA-256 hex output" do
      token = "test-token-value"
      hash1 = Webhooks.hash_token(token)
      hash2 = Webhooks.hash_token(token)

      assert hash1 == hash2
      # SHA-256 produces 64 hex characters
      assert byte_size(hash1) == 64
      assert hash1 =~ ~r/^[a-f0-9]{64}$/
    end

    test "different tokens produce different hashes" do
      hash1 = Webhooks.hash_token("token-a")
      hash2 = Webhooks.hash_token("token-b")

      assert hash1 != hash2
    end
  end
end
