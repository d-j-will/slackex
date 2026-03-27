defmodule SlackexWeb.Plugs.McpHttp do
  @moduledoc """
  MCP Streamable HTTP transport adapter (spec 2025-03-26).

  Phantom MCP 0.3.4 hardcodes `text/event-stream` chunked responses for all
  POST requests. This Plug implements the MCP Streamable HTTP spec directly,
  calling Phantom.Router.dispatch_method/4 and returning proper JSON responses.

  Key spec requirements:
  - Requests (have `id`) → respond with `application/json` or `text/event-stream`
  - Notifications/responses (no `id`) → respond with `202 Accepted`, no body
  - Session ID via `Mcp-Session-Id` header
  - GET → delegate to Phantom.Plug for SSE notification stream
  - DELETE → terminate session
  """

  import Plug.Conn

  alias Phantom.Request
  alias Phantom.Session
  alias SlackexWeb.MCP.Router, as: McpRouter

  @session_store :mcp_http_sessions

  def init(opts) do
    _ = ensure_session_store()
    Phantom.Cache.register(opts[:router])

    %{
      phantom_opts: Phantom.Plug.init(opts),
      router: opts[:router]
    }
  end

  def call(%{method: "POST"} = conn, opts) do
    handle_post(conn, opts)
  end

  def call(conn, %{phantom_opts: phantom_opts}) do
    Phantom.Plug.call(conn, phantom_opts)
  end

  # -- POST handling ----------------------------------------------------------

  defp handle_post(conn, opts) do
    case parse_body(conn) do
      {:ok, body} ->
        if notification?(body) do
          handle_notification(conn, body, opts)
        else
          handle_request(conn, body, opts)
        end

      {:error, error} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{jsonrpc: "2.0", error: error}))
    end
  end

  # Notifications have method but no id
  defp notification?(%{"method" => _, "id" => _}), do: false
  defp notification?(%{"method" => _}), do: true
  # Responses have result/error but no method
  defp notification?(%{"result" => _}), do: true
  defp notification?(%{"error" => _}), do: true
  defp notification?(_), do: false

  defp handle_notification(conn, _body, opts) do
    case get_or_create_session(conn, opts) do
      {:ok, session} ->
        # Spec: notifications MUST return 202 Accepted with no body
        conn
        |> put_resp_header("mcp-session-id", session.id)
        |> put_cors_headers()
        |> send_resp(202, "")

      {:unauthorized, challenge} ->
        conn
        |> put_resp_header("www-authenticate", challenge)
        |> send_resp(401, "")
    end
  end

  defp handle_request(conn, body, opts) do
    with {:ok, session} <- get_or_create_session(conn, opts),
         {:ok, response, session} <- dispatch(body, session) do
      save_session(session)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("mcp-session-id", session.id)
      |> put_cors_headers()
      |> send_resp(200, Jason.encode!(response))
    else
      {:unauthorized, challenge} ->
        conn
        |> put_resp_header("www-authenticate", challenge)
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))

      {:error, error} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{jsonrpc: "2.0", id: body["id"], error: error}))
    end
  end

  # -- Dispatch ---------------------------------------------------------------

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:error, Request.parse_error("No body")}
      %{"_json" => list} when is_list(list) -> {:ok, List.first(list)}
      params when map_size(params) > 0 -> {:ok, params}
      _ -> {:error, Request.parse_error("Empty body")}
    end
  end

  # Handle initialize directly — Phantom's validate_protocol rejects newer
  # protocol versions that Claude Code sends. Per MCP spec, the server responds
  # with the latest version it supports and the client adapts.
  defp dispatch(%{"jsonrpc" => "2.0", "method" => "initialize"} = body, session) do
    capabilities =
      %{}
      |> Phantom.Router.tool_capability(McpRouter, session)
      |> Phantom.Router.resource_capability(McpRouter, session)
      |> Phantom.Router.prompt_capability(McpRouter, session)
      |> Phantom.Router.logging_capability(McpRouter, session)

    result = %{
      protocolVersion: "2025-03-26",
      capabilities: capabilities,
      serverInfo: %{name: "Tenun", version: "1.0.0"},
      instructions:
        "Tenun is a messaging platform. You can read channels, send messages, " <>
          "search message history, and subscribe to real-time channel events. " <>
          "Use the bot user identity associated with your token."
    }

    {:ok, %{jsonrpc: "2.0", id: body["id"], result: result}, session}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = body, session) do
    request = Request.build(body)
    params = Map.get(body, "params", %{})
    session = %{session | request: request}

    case McpRouter.dispatch_method(method, params, request, session) do
      {:reply, result, session} ->
        {:ok, %{jsonrpc: "2.0", id: body["id"], result: result}, session}

      {:error, error, session} ->
        {:ok, %{jsonrpc: "2.0", id: body["id"], error: error}, session}

      {:noreply, session} ->
        {:ok, %{jsonrpc: "2.0", id: body["id"], result: %{}}, session}
    end
  end

  defp dispatch(_body, _session), do: {:error, Request.invalid("Invalid JSON-RPC request")}

  # -- Session management -----------------------------------------------------

  defp get_or_create_session(conn, opts) do
    case get_req_header(conn, "mcp-session-id") do
      [id] ->
        case :ets.lookup(@session_store, id) do
          [{^id, session}] -> {:ok, session}
          [] -> create_session(conn, opts)
        end

      [] ->
        create_session(conn, opts)
    end
  end

  defp create_session(conn, opts) do
    session =
      Session.new(nil,
        router: opts.router,
        pubsub: Slackex.PubSub
      )

    case opts.router.connect(session, conn) do
      {:ok, session} -> {:ok, session}
      {:unauthorized, challenge} -> {:unauthorized, challenge}
    end
  end

  defp save_session(session) do
    :ets.insert(@session_store, {session.id, session})
  end

  # -- Helpers ----------------------------------------------------------------

  defp ensure_session_store do
    case :ets.whereis(@session_store) do
      :undefined -> :ets.new(@session_store, [:named_table, :public, :set])
      ref -> ref
    end
  end

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "content-type, authorization, mcp-session-id"
    )
    |> put_resp_header("access-control-expose-headers", "mcp-session-id")
  end
end
