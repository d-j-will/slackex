defmodule SlackexWeb.ChatLive.SubscribeBotTest do
  # async: false — shared sandbox (ChannelServer processes) + global flag state
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Chat.Members
  alias Slackex.Chat.Subscription
  alias Slackex.Integrations.McpTokens
  alias Slackex.Repo

  setup %{conn: conn} do
    # Flag writes go through the sandboxed Repo and roll back with each test,
    # so setup must enable per test. Never disable in on_exit: it runs after
    # the sandbox owner has died — DBConnection.OwnershipError on slow runners
    # (CI run 27250133107) — and the rollback already cleaned up. Enforced by
    # TestTeardownSafetyTest.
    FunWithFlags.enable(:bot_subscription)

    owner = insert(:user, username: "owner-#{System.unique_integer([:positive])}")

    {:ok, channel} =
      Slackex.Chat.create_channel(owner.id, %{
        name: "engineering-#{System.unique_integer([:positive])}"
      })

    # Bot minted through the production path; username is "mcp-claude-code-max".
    {:ok, %{bot_user: bot, raw_token: raw_token}} =
      McpTokens.create_mcp_token(%{name: "claude-code-max"})

    conn = log_in_user(conn, owner)
    %{conn: conn, owner: owner, channel: channel, bot: bot, raw_token: raw_token}
  end

  defp submit_command(lv, content) do
    lv
    |> form("#message-form", %{message: %{content: content}})
    |> render_submit()
  end

  defp subscription(bot, channel) do
    Repo.get_by(Subscription, user_id: bot.id, channel_id: channel.id)
  end

  test "flag off: /subscribe-bot behaves as an unknown command and inserts nothing", %{
    conn: conn,
    channel: channel,
    bot: bot
  } do
    FunWithFlags.disable(:bot_subscription)
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html = submit_command(lv, "/subscribe-bot claude-code-max")

    assert html =~ "Unknown command: /subscribe-bot"
    refute html =~ "subscribed"
    assert subscription(bot, channel) == nil
  end

  test "flag on: subscribing a bot inserts the membership row and flashes the channel id", %{
    conn: conn,
    channel: channel,
    bot: bot
  } do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html = submit_command(lv, "/subscribe-bot claude-code-max")

    assert html =~ "claude-code-max subscribed to ##{channel.name}"
    assert html =~ to_string(channel.id)
    assert %Subscription{role: "member"} = subscription(bot, channel)
  end

  test "input is cleared after a successful subscribe", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    submit_command(lv, "/subscribe-bot claude-code-max")

    refute lv |> element("#message-form") |> render() =~ "subscribe-bot claude-code-max"
  end

  test "non-matching bot name flashes a not-found error", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html = submit_command(lv, "/subscribe-bot nonexistent")

    assert html =~ "No bot named &#39;nonexistent&#39; found"
  end

  test "bare /subscribe-bot flashes a usage hint", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html = submit_command(lv, "/subscribe-bot")

    assert html =~ "Usage: /subscribe-bot &lt;name&gt; — &lt;name&gt; is the label chosen at MCP token creation (bot username becomes mcp-&lt;name&gt;)"
  end

  test "subscribing twice reports already subscribed", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    submit_command(lv, "/subscribe-bot claude-code-max")
    html = submit_command(lv, "/subscribe-bot claude-code-max")

    assert html =~ "already subscribed"
  end

  test "/unsubscribe-bot removes the membership row", %{
    conn: conn,
    channel: channel,
    owner: owner,
    bot: bot
  } do
    {:ok, _} = Members.add_bot_member(channel.id, owner.id, bot.id)
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html = submit_command(lv, "/unsubscribe-bot claude-code-max")

    assert html =~ "claude-code-max unsubscribed from ##{channel.name}"
    assert subscription(bot, channel) == nil
  end

  test "unsubscribing a bot that is not a member flashes an error", %{
    conn: conn,
    channel: channel
  } do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html = submit_command(lv, "/unsubscribe-bot claude-code-max")

    assert html =~ "not subscribed to this channel"
  end

  # Full producer -> consumer path (CLAUDE.md spec-driven acceptance rule):
  # the slash command must actually unlock the MCP write path — proving a row
  # was inserted is not enough. Expanded (TDD) to also cover search_messages
  # (with channel_id scope), reply_to_thread, and react_to_message after a
  # fresh subscribe. Pre-subscribe write attempts fail with membership error.
  test "INTEGRATION: /subscribe-bot unlocks MCP send_message, search_messages (scoped), reply_to_thread, react_to_message for the bot", %{
    conn: conn,
    channel: channel,
    raw_token: raw_token
  } do
    mcp_call = fn name, args ->
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{
          "name" => name,
          "arguments" => args
        }
      })
    end

    # Before subscription the MCP write paths are closed (membership gate).
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => before_text}]}} =
             json_response(mcp_call.("send_message", %{"channel_id" => to_string(channel.id), "content" => "pre-subscribe"}), 200)

    assert before_text =~ "Not a member of this channel"

    # Owner subscribes the bot in-chat (the producer action).
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")
    submit_command(lv, "/subscribe-bot claude-code-max")

    # send_message now succeeds (core consumer path)
    send_resp = json_response(mcp_call.("send_message", %{"channel_id" => to_string(channel.id), "content" => "Hello from the subscribed bot"}), 200)
    assert %{"result" => result_send} = send_resp
    refute result_send["isError"]

    assert [%{"type" => "text", "text" => send_text}] = result_send["content"]
    sent_msg = Jason.decode!(send_text)
    assert sent_msg["content"] == "Hello from the subscribed bot"
    sent_id = sent_msg["id"]

    # search_messages (scoped via channel_id filter) — now returns the bot's messages
    # because membership (from subscribe) makes the channel visible to Search for this bot_user_id.
    search_resp = json_response(
      mcp_call.("search_messages", %{
        "query" => "subscribed bot",
        "channel_id" => to_string(channel.id),
        "limit" => 5
      }),
      200
    )
    assert %{"result" => search_res} = search_resp
    refute search_res["isError"]
    [%{"type" => "text", "text" => search_json}] = search_res["content"]
    hits = Jason.decode!(search_json)
    assert Enum.any?(hits, fn h -> h["content"] =~ "subscribed bot" end)

    # reply_to_thread succeeds using the id from the prior send
    reply_resp = json_response(
      mcp_call.("reply_to_thread", %{
        "channel_id" => to_string(channel.id),
        "parent_message_id" => sent_id,
        "content" => "reply from bot after subscribe"
      }),
      200
    )
    assert %{"result" => result_reply} = reply_resp
    refute result_reply["isError"]

    # react_to_message succeeds
    react_resp = json_response(
      mcp_call.("react_to_message", %{
        "channel_id" => to_string(channel.id),
        "message_id" => sent_id,
        "emoji" => "thumbsup"
      }),
      200
    )
    assert %{"result" => result_react} = react_resp
    refute result_react["isError"]
  end
end
