defmodule SlackexWeb.MCP.OpsResourcesTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.McpTokens
  alias Slackex.Ops.SystemSummary
  alias SlackexWeb.MCP.Serializer

  setup do
    user = insert(:user)

    {:ok, %{mcp_token: _token, raw_token: raw_token}} =
      McpTokens.create_mcp_token(%{name: "Ops Agent"})

    %{user: user, raw_token: raw_token}
  end

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

  describe "ops summary MCP resource" do
    test "resources/list includes exactly one new MVP resource", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn = mcp_post(conn, raw_token, jsonrpc("resources/list"))

      assert %{"result" => %{"resources" => resources}} = json_response(conn, 200)

      uris = Enum.map(resources, & &1["uri"])

      assert "tenun:///channels" in uris
      assert "tenun:///users/{id}" in uris
      assert "tenun:///ops/summary" in uris
      assert Enum.count(uris, &(&1 == "tenun:///ops/summary")) == 1
    end

    test "reads ops summary with exact top-level JSON shape", %{conn: conn, raw_token: raw_token} do
      conn =
        mcp_post(conn, raw_token, jsonrpc("resources/read", %{"uri" => "tenun:///ops/summary"}))

      assert %{"result" => %{"contents" => [%{"uri" => "tenun:///ops/summary", "text" => text}]}} =
               json_response(conn, 200)

      summary = Jason.decode!(text)

      assert Map.keys(summary) |> Enum.sort() == [
               "active_channel_servers",
               "generated_at",
               "node",
               "online_users_count",
               "partial_failures",
               "queue_running_counts"
             ]

      assert {:ok, _, _} = DateTime.from_iso8601(summary["generated_at"])
      assert is_binary(summary["node"])
      assert is_integer(summary["active_channel_servers"])
      assert is_integer(summary["online_users_count"])

      assert Map.keys(summary["queue_running_counts"]) |> Enum.sort() == [
               "default",
               "embeddings",
               "link_previews",
               "notifications"
             ]

      assert Map.keys(summary["partial_failures"]) |> Enum.sort() == [
               "active_channel_servers",
               "online_users",
               "queues"
             ]

      refute text =~ "#PID<"
      refute text =~ "Elixir."
    end

    test "revoked token is denied for resources/read", %{conn: conn, raw_token: raw_token} do
      hash = McpTokens.hash_token(raw_token)
      token = McpTokens.get_by_token_hash(hash)
      McpTokens.revoke_mcp_token(token)

      conn =
        mcp_post(conn, raw_token, jsonrpc("resources/read", %{"uri" => "tenun:///ops/summary"}))

      assert %{"error" => %{"code" => -32_000, "message" => "Unauthorized"}} =
               json_response(conn, 401)
    end

    test "revoked token is denied for resources/list", %{conn: conn, raw_token: raw_token} do
      hash = McpTokens.hash_token(raw_token)
      token = McpTokens.get_by_token_hash(hash)
      McpTokens.revoke_mcp_token(token)

      conn = mcp_post(conn, raw_token, jsonrpc("resources/list"))

      assert %{"error" => %{"code" => -32_000, "message" => "Unauthorized"}} =
               json_response(conn, 401)
    end

    test "serializer preserves the exact ops summary contract" do
      snapshot = SystemSummary.snapshot()
      serialized = Serializer.ops_summary(snapshot)

      assert Map.keys(serialized) |> Enum.sort() == [
               :active_channel_servers,
               :generated_at,
               :node,
               :online_users_count,
               :partial_failures,
               :queue_running_counts
             ]
    end

    test "MCP client can read ops summary and post a derived status message", %{
      conn: conn,
      raw_token: raw_token,
      user: user
    } do
      channel = insert(:channel, creator: user, is_private: false)
      insert(:subscription, user: user, channel: channel)

      hash = McpTokens.hash_token(raw_token)
      token = McpTokens.get_by_token_hash(hash)
      insert(:subscription, user: token.bot_user, channel: channel)

      read_conn =
        mcp_post(conn, raw_token, jsonrpc("resources/read", %{"uri" => "tenun:///ops/summary"}))

      assert %{"result" => %{"contents" => [%{"text" => text}]}} = json_response(read_conn, 200)
      summary = Jason.decode!(text)

      message =
        "Ops snapshot: node=#{summary["node"]} active_channel_servers=#{summary["active_channel_servers"]} online_users_count=#{summary["online_users_count"]}"

      send_conn =
        mcp_post(
          build_conn(),
          raw_token,
          jsonrpc("tools/call", %{
            "name" => "send_message",
            "arguments" => %{
              "channel_id" => to_string(channel.id),
              "content" => message
            }
          })
        )

      assert %{"result" => %{"content" => [%{"text" => sent_text}]}} =
               json_response(send_conn, 200)

      sent = Jason.decode!(sent_text)
      assert sent["content"] == message
      assert sent["channel_id"] == to_string(channel.id)
    end
  end
end
