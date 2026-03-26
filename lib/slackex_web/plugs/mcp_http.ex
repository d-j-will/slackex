defmodule SlackexWeb.Plugs.McpHttp do
  @moduledoc """
  MCP Streamable HTTP transport adapter.

  Phantom MCP 0.3.4 hardcodes `text/event-stream` chunked responses for all
  POST requests. Claude Code's `type: "http"` transport expects plain JSON.

  This Plug sits alongside Phantom.Plug and serves JSON responses for HTTP
  clients while letting SSE clients through to Phantom for streaming.

  Implements the MCP Streamable HTTP spec:
  - POST with Accept including text/event-stream → delegate to Phantom.Plug (SSE)
  - POST without → process via Router.dispatch_method, return application/json
  - GET → delegate to Phantom.Plug (SSE notification stream)
  - DELETE → delegate to Phantom.Plug (session termination)
  """

  import Plug.Conn

  alias Phantom.Request
  alias Phantom.Session
  alias SlackexWeb.MCP.Router, as: McpRouter

  @session_store :mcp_http_sessions

  def init(opts) do
    _ = ensure_session_store()

    %{
      phantom_opts: Phantom.Plug.init(opts),
      router: opts[:router]
    }
  end

  def call(%{method: "POST"} = conn, %{phantom_opts: phantom_opts} = opts) do
    if accepts_sse?(conn) do
      Phantom.Plug.call(conn, phantom_opts)
    else
      handle_json(conn, opts)
    end
  end

  def call(conn, %{phantom_opts: phantom_opts}) do
    Phantom.Plug.call(conn, phantom_opts)
  end

  # -- JSON transport ---------------------------------------------------------

  defp handle_json(conn, opts) do
    with {:ok, body} <- parse_body(conn),
         {:ok, session} <- get_or_create_session(conn, opts),
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
        |> send_resp(400, Jason.encode!(error))
    end
  end

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:error, Request.parse_error("No body")}
      %{"_json" => list} when is_list(list) -> {:ok, List.first(list)}
      params when map_size(params) > 0 -> {:ok, params}
      _ -> {:error, Request.parse_error("Empty body")}
    end
  end

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = body, session) do
    request = Request.build(body)
    params = Map.get(body, "params", %{})
    session = %{session | request: request}

    case McpRouter.dispatch_method(method, params, request, session) do
      {:reply, result, session} ->
        response = %{
          jsonrpc: "2.0",
          id: body["id"],
          result: result
        }

        {:ok, response, session}

      {:error, error, session} ->
        response = %{
          jsonrpc: "2.0",
          id: body["id"],
          error: error
        }

        {:ok, response, session}

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

  defp accepts_sse?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

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
