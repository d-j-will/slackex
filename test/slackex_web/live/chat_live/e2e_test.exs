defmodule SlackexWeb.ChatLive.E2ETest do
  @moduledoc """
  End-to-end tests verifying full user flows across multiple LiveView sessions.

  Tagged :e2e — excluded from the default test run, run with:
    mix test --include e2e
  """
  use SlackexWeb.ConnCase, async: false

  import Slackex.Factory

  @moduletag :e2e

  describe "channel messaging flow" do
    test "message sent by Alice appears in Bob's LiveView via PubSub", %{conn: conn} do
      alice = insert(:user)
      bob = insert(:user)
      channel = insert(:channel) |> with_subscription(alice) |> with_subscription(bob)

      alice_conn = log_in_user(conn, alice)
      bob_conn = Phoenix.ConnTest.build_conn() |> log_in_user(bob)

      {:ok, alice_view, _html} = live(alice_conn, ~p"/chat/#{channel.slug}")
      {:ok, bob_view, _html} = live(bob_conn, ~p"/chat/#{channel.slug}")

      # Alice sends a message
      alice_view
      |> form("#message-form", %{message: %{content: "hello from alice"}})
      |> render_submit()

      # Wait for ChannelServer batch flush (~2s interval) + PubSub propagation
      assert_eventually(fn ->
        render(bob_view) =~ "hello from alice"
      end)
    end
  end

  # Poll helper — retries assertion for up to timeout_ms
  defp assert_eventually(fun, timeout_ms \\ 5_000, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, interval_ms)
  end

  defp do_assert_eventually(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Assertion did not become true within timeout")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline, interval_ms)
      end
    end
  end
end
