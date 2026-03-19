defmodule SlackexWeb.WebhookControllerTest do
  # async: false — Messaging.send_message spawns ChannelServer processes
  # that need shared sandbox access for DB queries
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.Webhook
  alias Slackex.Integrations.Webhooks

  setup do
    user = insert(:user)
    channel = insert(:channel, creator: user, is_private: false)

    {:ok, %{webhook: webhook, token: raw_token}} =
      Webhooks.create_webhook(%{name: "Test Bot", channel_id: channel.id})

    # Enable the feature flag — sandbox rollback cleans up automatically
    FunWithFlags.enable(:incoming_webhooks)

    %{channel: channel, webhook: webhook, token: raw_token, user: user}
  end

  describe "POST /api/webhooks/:token" do
    test "delivers message with valid token and text", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/webhooks/#{token}", %{text: "Hello from CI"})

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 401 for invalid token", %{conn: conn} do
      conn = post(conn, ~p"/api/webhooks/bogus-token-value", %{text: "Hello"})

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "returns 400 when text field is missing", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/webhooks/#{token}", %{content: "wrong field"})

      assert %{"error" => "invalid_payload", "message" => message} = json_response(conn, 400)
      assert message =~ "text field is required"
    end

    test "returns 400 when text field is empty", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/webhooks/#{token}", %{text: "   "})

      assert %{"error" => "invalid_payload"} = json_response(conn, 400)
    end

    test "returns 400 when text field is not a string", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/webhooks/#{token}", %{text: 12_345})

      assert %{"error" => "invalid_payload"} = json_response(conn, 400)
    end

    test "returns 404 when feature flag is disabled", %{conn: conn, token: token} do
      FunWithFlags.disable(:incoming_webhooks)

      conn = post(conn, ~p"/api/webhooks/#{token}", %{text: "Hello"})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 when channel is deleted (webhook cascade-deleted by FK)", %{
      conn: conn,
      token: token,
      channel: channel
    } do
      # FK on_delete: :delete_all cascades channel deletion to webhooks,
      # so the token lookup fails before we reach the channel check
      Slackex.Repo.delete!(channel)

      conn = post(conn, ~p"/api/webhooks/#{token}", %{text: "Hello"})

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "returns 401 for deactivated webhook", %{conn: conn, token: token, webhook: webhook} do
      webhook
      |> Webhook.changeset(%{is_active: false})
      |> Slackex.Repo.update!()

      conn = post(conn, ~p"/api/webhooks/#{token}", %{text: "Hello"})

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "returns 400 when body is empty JSON", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/webhooks/#{token}", %{})

      assert %{"error" => "invalid_payload"} = json_response(conn, 400)
    end
  end
end
