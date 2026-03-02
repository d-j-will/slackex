defmodule SlackexWeb.Plugs.RateLimitTest do
  use SlackexWeb.ConnCase, async: false

  alias SlackexWeb.Plugs.RateLimit

  @opts RateLimit.init(max_requests: 3, window_seconds: 2)

  setup do
    # Clean up rate limit keys before each test
    conn_name = :redix_0

    case Redix.command(conn_name, ["KEYS", "rate_limit:*"]) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        Redix.command(conn_name, ["DEL" | keys])

      _ ->
        :ok
    end

    :ok
  end

  describe "rate limiting" do
    test "allows requests under the limit", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 1}}
      result = RateLimit.call(conn, @opts)
      refute result.halted
    end

    test "blocks requests over the limit", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 2}}

      # First 3 should pass
      for _ <- 1..3 do
        result = RateLimit.call(conn, @opts)
        refute result.halted
      end

      # 4th should be blocked
      blocked = RateLimit.call(conn, @opts)
      assert blocked.halted
      assert blocked.status == 429
    end

    test "resets after window expires", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 3}}
      opts = RateLimit.init(max_requests: 2, window_seconds: 1)

      # Exhaust the limit
      RateLimit.call(conn, opts)
      RateLimit.call(conn, opts)
      blocked = RateLimit.call(conn, opts)
      assert blocked.halted

      # Wait for window to expire
      Process.sleep(1_100)

      # Should be allowed again
      fresh = RateLimit.call(conn, opts)
      refute fresh.halted
    end

    test "rates by remote_ip, ignoring x-forwarded-for", %{conn: conn} do
      opts = RateLimit.init(max_requests: 1, window_seconds: 2)

      # Two requests from same remote_ip but different X-Forwarded-For
      # should still be rate-limited (we don't trust XFF)
      conn1 =
        %{conn | remote_ip: {10, 1, 0, 5}}
        |> put_req_header("x-forwarded-for", "203.0.113.60")
        |> RateLimit.call(opts)

      refute conn1.halted

      conn2 =
        %{conn | remote_ip: {10, 1, 0, 5}}
        |> put_req_header("x-forwarded-for", "203.0.113.61")
        |> RateLimit.call(opts)

      # Same remote_ip = blocked, even though XFF differs
      assert conn2.halted
      assert conn2.status == 429
    end

    test "different remote_ips are tracked independently", %{conn: conn} do
      opts = RateLimit.init(max_requests: 1, window_seconds: 2)

      conn1 = %{conn | remote_ip: {10, 1, 0, 6}} |> RateLimit.call(opts)
      refute conn1.halted

      conn2 = %{conn | remote_ip: {10, 1, 0, 7}} |> RateLimit.call(opts)
      refute conn2.halted
    end

    test "returns 429 with plain text body", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 4}}
      opts = RateLimit.init(max_requests: 1, window_seconds: 2)

      RateLimit.call(conn, opts)
      blocked = RateLimit.call(conn, opts)

      assert blocked.status == 429
      assert blocked.resp_body =~ "Too many requests"
    end
  end
end
