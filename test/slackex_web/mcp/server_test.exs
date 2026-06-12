defmodule SlackexWeb.MCP.ServerTest do
  # async: false — Messaging.send_message spawns ChannelServer processes
  # that need shared sandbox access for DB queries
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.McpTokens

  setup do
    user = insert(:user)
    channel = insert(:channel, creator: user, is_private: false)
    insert(:subscription, user: user, channel: channel)

    {:ok, %{mcp_token: _token, raw_token: raw_token, bot_user: bot}} =
      McpTokens.create_mcp_token(%{name: "Test Agent"})

    # Bot must be a member of the channel for tool calls
    insert(:subscription, user: bot, channel: channel)

    %{
      channel: channel,
      user: user,
      bot: bot,
      raw_token: raw_token
    }
  end

  # -- Helpers ---------------------------------------------------------------

  defp mcp_post(conn, raw_token, body) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp jsonrpc(method, params \\ nil, id \\ 1) do
    body = %{"jsonrpc" => "2.0", "method" => method, "id" => id}
    if params, do: Map.put(body, "params", params), else: body
  end

  defp jsonrpc_notification(method) do
    %{"jsonrpc" => "2.0", "method" => method}
  end

  # -- Authentication --------------------------------------------------------

  describe "authentication" do
    test "rejects request with no auth header", %{conn: conn} do
      body = jsonrpc("initialize")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert %{"error" => %{"code" => -32_000, "message" => "Unauthorized"}} =
               json_response(conn, 401)

      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "rejects request with invalid token", %{conn: conn} do
      conn = mcp_post(conn, "bogus-token", jsonrpc("initialize"))

      assert %{"error" => %{"code" => -32_000, "message" => "Unauthorized"}} =
               json_response(conn, 401)
    end

    test "rejects request with revoked token", %{conn: conn, raw_token: raw_token} do
      hash = McpTokens.hash_token(raw_token)
      token = McpTokens.get_by_token_hash(hash)
      McpTokens.revoke_mcp_token(token)

      conn = mcp_post(conn, raw_token, jsonrpc("initialize"))

      assert %{"error" => %{"code" => -32_000, "message" => "Unauthorized"}} =
               json_response(conn, 401)
    end

    test "accepts request with valid token", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("initialize"))

      assert %{"result" => %{"protocolVersion" => _}} = json_response(conn, 200)
    end

    test "returns mcp-session-id header on success", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("initialize"))

      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      assert json_response(conn, 200)
    end
  end

  # -- HTTP method handling --------------------------------------------------

  describe "HTTP methods" do
    test "OPTIONS returns 204 with CORS headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> options("/mcp")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end

    test "GET returns 405", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> get("/mcp")

      assert %{"error" => "Method not allowed"} = json_response(conn, 405)
    end

    test "notifications return 202", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc_notification("notifications/initialized"))

      assert conn.status == 202
    end
  end

  # -- Protocol methods ------------------------------------------------------

  describe "initialize" do
    test "returns protocol version and capabilities", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("initialize"))

      assert %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "protocolVersion" => "2025-03-26",
                 "capabilities" => %{
                   "tools" => %{},
                   "resources" => %{},
                   "prompts" => %{}
                 },
                 "serverInfo" => %{"name" => "Tenun", "version" => "1.0.0"},
                 "instructions" => instructions
               }
             } = json_response(conn, 200)

      assert instructions =~ "messaging platform"
    end
  end

  describe "ping" do
    test "returns empty result", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("ping"))

      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}} = json_response(conn, 200)
    end
  end

  describe "unknown method" do
    test "returns method not found error", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("nonexistent/method"))

      assert %{"error" => %{"code" => -32_601, "message" => msg}} = json_response(conn, 200)
      assert msg =~ "Method not found"
    end
  end

  # -- Tools -----------------------------------------------------------------

  describe "tools/list" do
    test "returns all tool definitions", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("tools/list"))

      assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      tool_names = Enum.map(tools, & &1["name"]) |> Enum.sort()

      assert tool_names == [
               "find_user",
               "list_channels",
               "react_to_message",
               "reply_to_thread",
               "search_messages",
               "send_dm",
               "send_message"
             ]

      # Each tool has required fields
      for tool <- tools do
        assert Map.has_key?(tool, "name")
        assert Map.has_key?(tool, "description")
        assert Map.has_key?(tool, "inputSchema")
        assert tool["inputSchema"]["type"] == "object"
      end
    end
  end

  describe "tools/call — send_message" do
    test "sends message to channel", %{
      conn: conn,
      raw_token: raw_token,
      channel: channel
    } do
      params = %{
        "name" => "send_message",
        "arguments" => %{
          "channel_id" => to_string(channel.id),
          "content" => "Hello from MCP"
        }
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(conn, 200)

      msg = Jason.decode!(text)
      assert msg["content"] == "Hello from MCP"
      # Slice 2b contract: send_message response carries channel human identity (from enrichment + serializer)
      assert msg["channel_id"] == to_string(channel.id)
      assert msg["channel_name"] == channel.name
      assert msg["channel_slug"] == channel.slug
    end

    test "rejects send to channel bot is not a member of", %{
      conn: conn,
      raw_token: raw_token
    } do
      other_user = insert(:user)
      other_channel = insert(:channel, creator: other_user)

      params = %{
        "name" => "send_message",
        "arguments" => %{
          "channel_id" => to_string(other_channel.id),
          "content" => "Should fail"
        }
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "Not a member"
    end
  end

  describe "tools/call — reply_to_thread" do
    test "replies to a thread", %{
      conn: conn,
      raw_token: raw_token,
      channel: channel,
      bot: bot
    } do
      # Send parent via Chat (writes to DB immediately, unlike Messaging which batches)
      {:ok, parent} = Slackex.Chat.send_message(channel.id, bot.id, "parent msg")

      params = %{
        "name" => "reply_to_thread",
        "arguments" => %{
          "channel_id" => to_string(channel.id),
          "parent_message_id" => to_string(parent.id),
          "content" => "Thread reply from MCP"
        }
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(conn, 200)

      msg = Jason.decode!(text)
      assert msg["content"] == "Thread reply from MCP"
      # Slice 2b: reply_to_thread also returns channel_name/slug (enriched via get_channel + serializer attach)
      assert msg["channel_id"] == to_string(channel.id)
      assert msg["channel_name"] == channel.name
      assert msg["channel_slug"] == channel.slug
    end

    test "rejects reply to channel bot is not a member of", %{
      conn: conn,
      raw_token: raw_token
    } do
      other_user = insert(:user)
      other_channel = insert(:channel, creator: other_user)

      params = %{
        "name" => "reply_to_thread",
        "arguments" => %{
          "channel_id" => to_string(other_channel.id),
          "parent_message_id" => "12345",
          "content" => "Should fail"
        }
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "Not a member"
    end
  end

  describe "tools/call — search_messages (Slice 2b enrichment)" do
    test "returns serialized messages carrying channel_name and channel_slug (from preloaded channel in search query)", %{
      conn: conn,
      raw_token: raw_token,
      channel: channel,
      bot: bot
    } do
      # Enable for this test only (DB write rolled back by sandbox tx at end of test; no on_exit writes)
      FunWithFlags.enable(:message_search)

      # Populate a searchable message via prod path (Chat direct for immediate FTS content)
      {:ok, _sent} = Slackex.Chat.send_message(channel.id, bot.id, "searchable mcp content for names test")

      params = %{
        "name" => "search_messages",
        "arguments" => %{"query" => "searchable mcp content", "limit" => 5}
      }

      call_conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(call_conn, 200)

      results = Jason.decode!(text)
      assert is_list(results)
      found = Enum.find(results, &(&1["content"] =~ "searchable mcp content"))
      assert found, "expected search result for the inserted message"
      assert found["channel_id"] == to_string(channel.id)
      assert found["channel_name"] == channel.name
      assert found["channel_slug"] == channel.slug
    end
  end

  describe "tools/call — react_to_message" do
    test "rejects reaction on channel bot is not a member of", %{
      conn: conn,
      raw_token: raw_token
    } do
      other_user = insert(:user)
      other_channel = insert(:channel, creator: other_user)

      params = %{
        "name" => "react_to_message",
        "arguments" => %{
          "channel_id" => to_string(other_channel.id),
          "message_id" => "12345",
          "emoji" => "thumbsup"
        }
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "Not a member"
    end
  end

  describe "tools/call — find_user" do
    test "finds users by username", %{conn: conn, raw_token: raw_token, user: user} do
      params = %{
        "name" => "find_user",
        "arguments" => %{"query" => String.slice(user.username, 0, 4)}
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(conn, 200)

      users = Jason.decode!(text)
      assert is_list(users)
      assert Enum.any?(users, &(&1["username"] == user.username))
    end
  end

  describe "tools/call — send_dm" do
    test "sends a DM to a user", %{conn: conn, raw_token: raw_token, user: user} do
      params = %{
        "name" => "send_dm",
        "arguments" => %{
          "user_id" => to_string(user.id),
          "content" => "Hello via DM"
        }
      }

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(conn, 200)

      msg = Jason.decode!(text)
      assert msg["content"] == "Hello via DM"
    end
  end

  describe "tools/call — list_channels" do
    test "returns only channels the bot is subscribed to, using full Serializer.channel shape with human names", %{
      conn: conn,
      raw_token: raw_token,
      channel: channel,
      bot: _bot
    } do
      # Contract: after membership (here via test setup mirroring prod sub), the tool returns
      # rich entries an agent can use immediately: numeric id (string) + name/slug etc.
      # Non-member channels must be excluded (bot-scoped via Subscription).
      params = %{"name" => "list_channels", "arguments" => %{}}

      call_conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(call_conn, 200)

      listed = Jason.decode!(text)
      assert is_list(listed)

      # The setup channel that bot is subscribed to must be present with name
      found = Enum.find(listed, &(&1["id"] == to_string(channel.id)))
      assert found, "expected subscribed channel to appear in list_channels"
      assert found["name"] == channel.name
      assert found["slug"] == channel.slug
      assert Map.has_key?(found, "description")
      assert Map.has_key?(found, "member_count")
      assert Map.has_key?(found, "inserted_at")

      # Prove scoping: a channel the bot has no Subscription for must not be returned
      other_owner = insert(:user)
      other_channel = insert(:channel, creator: other_owner, name: "secret-other")
      # (no sub for bot)

      # Re-call using the fresh setup conn (do not reuse sent conn from prior mcp_post)
      call_conn2 = mcp_post(conn, raw_token, jsonrpc("tools/call", params))
      listed2 = Jason.decode!(json_response(call_conn2, 200)["result"]["content"] |> hd() |> Map.get("text"))

      ids = Enum.map(listed2, & &1["id"])
      refute to_string(other_channel.id) in ids
      assert to_string(channel.id) in ids
    end

    test "returns empty list when bot has no channel memberships", %{conn: conn} do
      # Fresh bot with token but no subs at all
      {:ok, %{raw_token: fresh_raw}} = McpTokens.create_mcp_token(%{name: "fresh-no-subs"})

      params = %{"name" => "list_channels", "arguments" => %{}}

      call_conn = mcp_post(conn, fresh_raw, jsonrpc("tools/call", params))

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               json_response(call_conn, 200)

      listed = Jason.decode!(text)
      assert listed == []
    end
  end

  describe "tools/call — unknown tool" do
    test "returns error for unknown tool", %{conn: conn, raw_token: raw_token} do
      params = %{"name" => "nonexistent", "arguments" => %{}}

      conn = mcp_post(conn, raw_token, jsonrpc("tools/call", params))

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ "Unknown tool"
    end
  end

  # -- Resources -------------------------------------------------------------

  describe "resources/list" do
    test "returns available resources", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("resources/list"))

      assert %{"result" => %{"resources" => resources}} = json_response(conn, 200)
      uris = Enum.map(resources, & &1["uri"])

      assert "tenun:///channels" in uris
      assert "tenun:///users/{id}" in uris
      assert "tenun:///ops/summary" in uris
    end
  end

  describe "resources/read" do
    test "reads channels resource", %{conn: conn, raw_token: raw_token, channel: channel} do
      params = %{"uri" => "tenun:///channels"}

      conn = mcp_post(conn, raw_token, jsonrpc("resources/read", params))

      assert %{"result" => %{"contents" => [%{"uri" => "tenun:///channels", "text" => text}]}} =
               json_response(conn, 200)

      channels = Jason.decode!(text)
      assert is_list(channels)
      assert Enum.any?(channels, &(&1["id"] == to_string(channel.id)))
    end

    test "reads user resource", %{conn: conn, raw_token: raw_token, user: user} do
      params = %{"uri" => "tenun:///users/#{user.id}"}

      conn = mcp_post(conn, raw_token, jsonrpc("resources/read", params))

      assert %{"result" => %{"contents" => [%{"text" => text}]}} = json_response(conn, 200)

      u = Jason.decode!(text)
      assert u["username"] == user.username
      refute Map.has_key?(u, "email")
      refute Map.has_key?(u, "hashed_password")
    end

    test "returns error for unknown user", %{conn: conn, raw_token: raw_token} do
      params = %{"uri" => "tenun:///users/999999999"}

      conn = mcp_post(conn, raw_token, jsonrpc("resources/read", params))

      assert %{"error" => %{"message" => "User not found"}} = json_response(conn, 200)
    end

    test "returns error for unknown resource URI", %{conn: conn, raw_token: raw_token} do
      params = %{"uri" => "tenun:///nonexistent"}

      conn = mcp_post(conn, raw_token, jsonrpc("resources/read", params))

      assert %{"error" => %{"message" => msg}} = json_response(conn, 200)
      assert msg =~ "Resource not found"
    end
  end

  # -- Prompts ---------------------------------------------------------------

  describe "prompts/list" do
    test "returns available prompts", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("prompts/list"))

      assert %{"result" => %{"prompts" => prompts}} = json_response(conn, 200)
      names = Enum.map(prompts, & &1["name"])

      assert "summarize_channel" in names
      assert "draft_spec" in names
    end
  end

  describe "prompts/get" do
    test "returns summarize_channel prompt", %{conn: conn, raw_token: raw_token} do
      params = %{
        "name" => "summarize_channel",
        "arguments" => %{"channel_id" => "123"}
      }

      conn = mcp_post(conn, raw_token, jsonrpc("prompts/get", params))

      assert %{"result" => %{"messages" => [%{"role" => "user", "content" => content}]}} =
               json_response(conn, 200)

      assert content["text"] =~ "search_messages"
      assert content["text"] =~ "123"
    end

    test "returns draft_spec prompt", %{conn: conn, raw_token: raw_token} do
      params = %{
        "name" => "draft_spec",
        "arguments" => %{"channel_id" => "456"}
      }

      conn = mcp_post(conn, raw_token, jsonrpc("prompts/get", params))

      assert %{"result" => %{"messages" => [%{"role" => "user", "content" => content}]}} =
               json_response(conn, 200)

      assert content["text"] =~ "search_messages"
      assert content["text"] =~ "456"
    end

    test "returns error for unknown prompt", %{conn: conn, raw_token: raw_token} do
      params = %{"name" => "nonexistent", "arguments" => %{}}

      conn = mcp_post(conn, raw_token, jsonrpc("prompts/get", params))

      assert %{"error" => %{"message" => msg}} = json_response(conn, 200)
      assert msg =~ "Unknown prompt"
    end
  end

  # -- Malformed requests ----------------------------------------------------

  describe "malformed requests" do
    test "returns parse error for non-JSON-RPC body", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, %{"not" => "jsonrpc"})

      assert %{"error" => %{"code" => -32_600}} = json_response(conn, 400)
    end

    test "returns parse error for empty body", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, %{})

      assert json_response(conn, 400)
    end
  end

  # -- CORS ------------------------------------------------------------------

  describe "CORS headers" do
    test "all responses include CORS headers", %{conn: conn, raw_token: raw_token} do
      conn = mcp_post(conn, raw_token, jsonrpc("ping"))

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-expose-headers") == ["mcp-session-id"]
    end
  end
end
