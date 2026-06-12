defmodule SlackexWeb.MCP.FactoryToolsTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.McpTokens

  setup do
    user = insert(:user)
    channel = insert(:channel, creator: user, is_private: false)
    insert(:subscription, user: user, channel: channel)

    {:ok, %{mcp_token: _token, raw_token: raw_token, bot_user: bot}} =
      McpTokens.create_mcp_token(%{name: "Factory Agent"})

    insert(:subscription, user: bot, channel: channel)
    FunWithFlags.enable(:dark_factory)

    %{channel: channel, bot: bot, raw_token: raw_token}
  end

  defp mcp_post(conn, raw_token, body) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp jsonrpc(method, params, id \\ 1) do
    %{"jsonrpc" => "2.0", "method" => method, "id" => id, "params" => params}
  end

  defp call_tool(conn, token, name, args \\ %{}) do
    mcp_post(conn, token, jsonrpc("tools/call", %{"name" => name, "arguments" => args}))
  end

  defp parse_tool_result(conn) do
    %{"result" => %{"content" => [%{"text" => text}]}} = json_response(conn, 200)
    Jason.decode!(text)
  end

  describe "full factory pipeline via MCP" do
    test "queue -> claim -> submit success -> claim verification -> submit pass", %{
      conn: conn,
      raw_token: token,
      channel: channel
    } do
      # Queue
      conn1 =
        call_tool(conn, token, "queue_factory_run", %{
          "spec_path" => "docs/feature/test/",
          "channel_id" => to_string(channel.id)
        })

      result = parse_tool_result(conn1)
      run_id = result["run_id"]
      assert result["status"] == "queued"
      # Factory coordination polish (2c): human name for the chosen status channel_id
      # must be visible in the queue response (so operator/plan sees where thread appears).
      # Additive to shape; uses the channel from setup.
      assert result["channel_name"] == channel.name

      # List work
      conn2 = call_tool(build_conn(), token, "list_factory_work")
      runs = parse_tool_result(conn2)
      assert length(runs) == 1
      assert hd(runs)["run_id"] == run_id

      # Claim
      conn3 =
        call_tool(build_conn(), token, "claim_factory_work", %{
          "run_id" => run_id,
          "commit_sha" => "abc123"
        })

      claim = parse_tool_result(conn3)
      assert claim["claim_token"] != nil
      claim_token = claim["claim_token"]

      # Heartbeat
      conn4 =
        call_tool(build_conn(), token, "factory_heartbeat", %{
          "run_id" => run_id,
          "claim_token" => claim_token,
          "message" => "Working on it"
        })

      assert %{"ok" => true} = parse_tool_result(conn4)

      # Submit success
      conn5 =
        call_tool(build_conn(), token, "submit_factory_result", %{
          "run_id" => run_id,
          "claim_token" => claim_token,
          "success" => true,
          "branch_name" => "factory/run-1",
          "summary" => %{"tests" => 42}
        })

      submit = parse_tool_result(conn5)
      assert submit["status"] == "awaiting_verification"

      # List verification work
      conn6 = call_tool(build_conn(), token, "list_verification_work")
      v_runs = parse_tool_result(conn6)
      assert length(v_runs) == 1
      assert hd(v_runs)["branch_name"] == "factory/run-1"

      # Claim verification
      conn7 =
        call_tool(build_conn(), token, "claim_verification_work", %{"run_id" => run_id})

      v_claim = parse_tool_result(conn7)
      v_token = v_claim["claim_token"]
      assert v_token != nil

      # Submit verification pass
      conn8 =
        call_tool(build_conn(), token, "submit_verification", %{
          "run_id" => run_id,
          "claim_token" => v_token,
          "passed" => true,
          "scenarios_run" => 5,
          "scenarios_passed" => 5,
          "details" => %{}
        })

      v_result = parse_tool_result(conn8)
      assert v_result["status"] == "completed"
    end

    test "cancel by owner", %{conn: conn, raw_token: token, channel: channel} do
      conn1 =
        call_tool(conn, token, "queue_factory_run", %{
          "spec_path" => "docs/feature/cancel-test/",
          "channel_id" => to_string(channel.id)
        })

      run_id = parse_tool_result(conn1)["run_id"]

      conn2 =
        call_tool(build_conn(), token, "cancel_factory_run", %{"run_id" => run_id})

      assert %{"status" => "cancelled"} = parse_tool_result(conn2)
    end

    test "tools hidden when feature flag disabled", %{conn: conn, raw_token: token} do
      FunWithFlags.disable(:dark_factory)

      body = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1}
      conn1 = mcp_post(conn, token, body)

      %{"result" => %{"tools" => tools}} = json_response(conn1, 200)
      tool_names = Enum.map(tools, & &1["name"])
      refute "queue_factory_run" in tool_names
    end
  end
end
