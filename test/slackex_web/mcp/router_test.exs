defmodule SlackexWeb.MCP.RouterTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.McpTokens
  alias Slackex.Chat
  alias SlackexWeb.MCP.Router

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    {:ok, %{raw_token: token, bot_user: bot}} =
      McpTokens.create_mcp_token(%{name: "Test Agent"})

    user = insert(:user)
    channel = insert(:channel, creator: user, name: "general", slug: "general")
    insert(:subscription, user: user, channel: channel)
    {:ok, _sub} = Chat.join_channel(bot.id, channel.id)

    %{token: token, bot: bot, channel: channel, user: user}
  end

  # ---------------------------------------------------------------------------
  # Auth -- connect/2
  # ---------------------------------------------------------------------------

  describe "connect/2 authentication" do
    test "valid bearer token authenticates and assigns bot user", %{token: token, bot: bot} do
      session = build_session()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")

      assert {:ok, session} = Router.connect(session, conn)
      assert session.assigns.bot_user.id == bot.id
      assert session.assigns.mcp_token
    end

    test "missing authorization header returns unauthorized" do
      session = build_session()
      conn = build_conn()

      assert {:unauthorized, "Bearer"} = Router.connect(session, conn)
    end

    test "invalid token returns unauthorized" do
      session = build_session()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer mcp_bogus_token_value")

      assert {:unauthorized, "Bearer"} = Router.connect(session, conn)
    end

    test "revoked token returns unauthorized", %{token: token} do
      hash = McpTokens.hash_token(token)
      mcp_token = McpTokens.get_by_token_hash(hash)
      {:ok, _} = McpTokens.revoke_mcp_token(mcp_token)

      session = build_session()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")

      assert {:unauthorized, "Bearer"} = Router.connect(session, conn)
    end

    test "connect touches last_used_at", %{token: token} do
      hash = McpTokens.hash_token(token)
      token_before = McpTokens.get_by_token_hash(hash)
      assert is_nil(token_before.last_used_at)

      session = build_session()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")

      assert {:ok, _session} = Router.connect(session, conn)

      token_after = McpTokens.get_by_token_hash(hash)
      assert token_after.last_used_at
    end
  end

  # ---------------------------------------------------------------------------
  # Resources -- list_channels
  # ---------------------------------------------------------------------------

  describe "list_channels/2" do
    test "returns all public channels with member counts", %{channel: channel} do
      session = build_session()
      {:reply, result, _session} = Router.list_channels(%{}, session)

      data = decode_resource_text(result)
      assert is_list(data)
      ch = Enum.find(data, fn c -> c["slug"] == channel.slug end)
      assert ch
      assert ch["member_count"] >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Resources -- read_channel
  # ---------------------------------------------------------------------------

  describe "read_channel/2" do
    test "returns channel data for a member", %{channel: channel, bot: bot} do
      session = build_session_with_bot(bot)

      {:reply, result, _session} =
        Router.read_channel(%{"id" => to_string(channel.id)}, session)

      data = decode_resource_text(result)
      assert data["slug"] == channel.slug
      assert data["member_count"] >= 1
    end

    test "returns error for non-member", %{bot: bot} do
      other_user = insert(:user)
      private_ch = insert(:channel, creator: other_user, is_private: true)
      insert(:subscription, user: other_user, channel: private_ch)

      session = build_session_with_bot(bot)

      {:reply, result, _session} =
        Router.read_channel(%{"id" => to_string(private_ch.id)}, session)

      data = decode_resource_text(result)
      assert data["error"] =~ "Not a member"
    end
  end

  # ---------------------------------------------------------------------------
  # Resources -- read_messages
  # ---------------------------------------------------------------------------

  describe "read_messages/2" do
    test "returns messages for a joined channel", %{channel: channel, user: user, bot: bot} do
      {:ok, _msg} = Chat.send_message(channel.id, user.id, "Hello from test")

      session = build_session_with_bot(bot)

      {:reply, result, _session} =
        Router.read_messages(%{"id" => to_string(channel.id)}, session)

      data = decode_resource_text(result)
      assert is_list(data)
      assert Enum.any?(data, fn m -> m["content"] == "Hello from test" end)
    end

    test "returns error for non-member channel", %{bot: bot} do
      other_user = insert(:user)
      other_ch = insert(:channel, creator: other_user)
      insert(:subscription, user: other_user, channel: other_ch)

      session = build_session_with_bot(bot)

      {:reply, result, _session} =
        Router.read_messages(%{"id" => to_string(other_ch.id)}, session)

      data = decode_resource_text(result)
      assert data["error"] =~ "Not a member"
    end
  end

  # ---------------------------------------------------------------------------
  # Resources -- read_thread
  # ---------------------------------------------------------------------------

  describe "read_thread/2" do
    test "returns thread messages", %{channel: channel, user: user, bot: bot} do
      {:ok, parent} = Chat.send_message(channel.id, user.id, "Parent message")

      session = build_session_with_bot(bot)

      {:reply, result, _session} =
        Router.read_thread(
          %{"id" => to_string(channel.id), "message_id" => to_string(parent.id)},
          session
        )

      data = decode_resource_text(result)
      assert is_list(data)
    end

    test "returns error when message does not belong to channel", %{bot: bot, user: user} do
      channel_a = insert(:channel, creator: user)
      insert(:subscription, user: user, channel: channel_a)
      {:ok, _} = Chat.join_channel(bot.id, channel_a.id)

      channel_b = insert(:channel, creator: user)
      insert(:subscription, user: user, channel: channel_b)
      {:ok, _} = Chat.join_channel(bot.id, channel_b.id)

      {:ok, msg_in_b} = Chat.send_message(channel_b.id, user.id, "In channel B")

      session = build_session_with_bot(bot)

      {:reply, result, _session} =
        Router.read_thread(
          %{"id" => to_string(channel_a.id), "message_id" => to_string(msg_in_b.id)},
          session
        )

      data = decode_resource_text(result)
      assert data["error"] =~ "does not belong"
    end
  end

  # ---------------------------------------------------------------------------
  # Resources -- read_user
  # ---------------------------------------------------------------------------

  describe "read_user/2" do
    test "returns user data", %{user: user} do
      session = build_session()

      {:reply, result, _session} =
        Router.read_user(%{"id" => to_string(user.id)}, session)

      data = decode_resource_text(result)
      assert data["username"] == user.username
      assert data["id"] == to_string(user.id)
    end

    test "returns error for unknown user" do
      session = build_session()

      {:reply, result, _session} =
        Router.read_user(%{"id" => "999999999999"}, session)

      data = decode_resource_text(result)
      assert data["error"] =~ "User not found"
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP integration -- pipeline wiring
  # ---------------------------------------------------------------------------

  describe "HTTP endpoint wiring" do
    test "POST /mcp without auth returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => "1",
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-03-26",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_session do
    Phantom.Session.new(nil, router: SlackexWeb.MCP.Router)
  end

  defp build_session_with_bot(bot) do
    build_session()
    |> Phantom.Session.assign(:bot_user, bot)
  end

  defp decode_resource_text(%{text: text}), do: Jason.decode!(text)
  defp decode_resource_text(text) when is_binary(text), do: Jason.decode!(text)
end
