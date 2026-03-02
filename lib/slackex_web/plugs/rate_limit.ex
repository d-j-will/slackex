defmodule SlackexWeb.Plugs.RateLimit do
  @moduledoc """
  Redis-backed distributed rate limiter plug for protecting authentication endpoints.

  Uses Redis INCR + EXPIRE for atomic, cross-node rate limiting.
  Degrades gracefully — if Redis is unavailable, requests are allowed through.

  ## Options

    * `:max_requests` - Maximum requests allowed per window (default: 10)
    * `:window_seconds` - Window duration in seconds (default: 60)

  ## Usage

      plug SlackexWeb.Plugs.RateLimit, max_requests: 5, window_seconds: 60
  """

  import Plug.Conn

  require Logger

  @behaviour Plug

  @default_max_requests 10
  @default_window_seconds 60
  @pool_size 10

  @impl Plug
  def init(opts) do
    %{
      max_requests: Keyword.get(opts, :max_requests, @default_max_requests),
      window_seconds: Keyword.get(opts, :window_seconds, @default_window_seconds)
    }
  end

  @impl Plug
  def call(conn, %{max_requests: max_requests, window_seconds: window_seconds}) do
    key = "rate_limit:#{client_ip(conn)}"

    case check_rate(key, max_requests, window_seconds) do
      {:allow, _count} ->
        conn

      {:deny, _count} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many requests. Please try again later.")
        |> halt()
    end
  end

  defp check_rate(key, max_requests, window_seconds) do
    with {:ok, count} <- redis_command(["INCR", key]),
         :ok <- maybe_set_expiry(key, count, window_seconds) do
      if count > max_requests do
        {:deny, count}
      else
        {:allow, count}
      end
    else
      {:error, _reason} ->
        # Redis unavailable — fail open to avoid blocking all logins
        {:allow, 0}
    end
  end

  defp maybe_set_expiry(key, 1, window_seconds) do
    case redis_command(["EXPIRE", key, to_string(window_seconds)]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp maybe_set_expiry(_key, _count, _window_seconds), do: :ok

  defp client_ip(conn) do
    # Use conn.remote_ip directly — Caddy (reverse proxy) sets the real
    # client IP on the TCP connection. Never trust X-Forwarded-For for
    # security decisions as it's client-controlled.
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp redis_command(cmd) do
    conn = :"redix_#{:rand.uniform(@pool_size) - 1}"
    Redix.command(conn, cmd, timeout: 1_000)
  rescue
    e ->
      Logger.warning("RateLimit Redis error: #{inspect(e)}")
      {:error, e}
  end
end
