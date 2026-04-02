defmodule SlackexWeb.MCP.Server do
  @moduledoc """
  MCP Streamable HTTP server (spec 2025-03-26).

  Pure Plug implementation — no dependencies on phantom_mcp. Implements
  the JSON-RPC methods Claude Code uses: initialize, tools/list, tools/call,
  resources/list, resources/read, prompts/list, prompts/get, ping.

  POST → JSON-RPC request/notification → JSON response or 202
  GET  → not implemented (no SSE notification stream needed)
  """

  import Plug.Conn

  alias Slackex.Chat.DMs
  alias Slackex.Integrations.McpTokens
  alias Slackex.Ops.SystemSummary
  alias SlackexWeb.MCP.FactoryTools
  alias SlackexWeb.MCP.Serializer

  @behaviour Plug

  @protocol_version "2025-03-26"
  @server_name "Tenun"
  @server_version "1.0.0"

  @instructions """
  Tenun is a messaging platform. You can read channels, send messages, \
  search message history, and subscribe to real-time channel events. \
  Use the bot user identity associated with your token.\
  """

  # -- Plug callbacks -------------------------------------------------------

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    case parse_body(conn) do
      {:ok, body} ->
        handle_post(conn, body)

      {:error, msg} ->
        json_resp(conn, 400, error_response(nil, -32_700, msg))
    end
  end

  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn |> put_cors_headers() |> send_resp(204, "")
  end

  def call(conn, _opts) do
    json_resp(conn, 405, %{error: "Method not allowed"})
  end

  # -- POST dispatch --------------------------------------------------------

  defp handle_post(conn, %{"method" => _method, "id" => _id} = body) do
    # Request (has id) — needs auth + response
    case authenticate(conn) do
      {:ok, session} ->
        response = dispatch(body, session)
        conn |> put_session_header(session) |> json_resp(200, response)

      {:error, challenge} ->
        conn
        |> put_resp_header("www-authenticate", challenge)
        |> json_resp(401, error_response(body["id"], -32_000, "Unauthorized"))
    end
  end

  defp handle_post(conn, %{"method" => _method} = _body) do
    # Notification (no id) — 202, no body. Still require valid auth.
    case authenticate(conn) do
      {:ok, _session} ->
        conn |> put_cors_headers() |> send_resp(202, "")

      {:error, challenge} ->
        conn
        |> put_resp_header("www-authenticate", challenge)
        |> json_resp(401, error_response(nil, -32_000, "Unauthorized"))
    end
  end

  defp handle_post(conn, _body) do
    json_resp(conn, 400, error_response(nil, -32_600, "Invalid request"))
  end

  # -- Method dispatch ------------------------------------------------------

  defp dispatch(%{"method" => "initialize"} = req, _session) do
    ok_response(req["id"], %{
      protocolVersion: @protocol_version,
      capabilities: %{
        tools: %{listChanged: false},
        resources: %{subscribe: false, listChanged: false},
        prompts: %{listChanged: false}
      },
      serverInfo: %{name: @server_name, version: @server_version},
      instructions: @instructions
    })
  end

  defp dispatch(%{"method" => "ping"} = req, _session) do
    ok_response(req["id"], %{})
  end

  defp dispatch(%{"method" => "tools/list"} = req, _session) do
    all_tools =
      if FunWithFlags.enabled?(:dark_factory),
        do: tools() ++ FactoryTools.tools(),
        else: tools()

    ok_response(req["id"], %{tools: all_tools})
  end

  defp dispatch(%{"method" => "tools/call", "params" => params} = req, session) do
    name = params["name"]
    args = params["arguments"] || %{}

    result =
      if factory_tool?(name) do
        if FunWithFlags.enabled?(:dark_factory) do
          FactoryTools.call_tool(name, args, session)
        else
          {:error, "Dark factory is not enabled"}
        end
      else
        call_tool(name, args, session)
      end

    case result do
      {:ok, content} ->
        ok_response(req["id"], %{content: content})

      {:error, msg} ->
        ok_response(req["id"], %{content: [%{type: "text", text: "Error: #{msg}"}], isError: true})
    end
  end

  defp dispatch(%{"method" => "resources/list"} = req, _session) do
    ok_response(req["id"], %{resources: resources()})
  end

  defp dispatch(%{"method" => "resources/read", "params" => params} = req, session) do
    case read_resource(params["uri"], session) do
      {:ok, contents} ->
        ok_response(req["id"], %{contents: contents})

      {:error, msg} ->
        error_response(req["id"], -32_002, msg)
    end
  end

  defp dispatch(%{"method" => "prompts/list"} = req, _session) do
    ok_response(req["id"], %{prompts: prompts()})
  end

  defp dispatch(%{"method" => "prompts/get", "params" => params} = req, session) do
    case get_prompt(params["name"], params["arguments"] || %{}, session) do
      {:ok, result} ->
        ok_response(req["id"], result)

      {:error, msg} ->
        error_response(req["id"], -32_002, msg)
    end
  end

  defp dispatch(%{"method" => method} = req, _session) do
    error_response(req["id"], -32_601, "Method not found: #{method}")
  end

  # -- Tools ----------------------------------------------------------------

  defp tools do
    [
      %{
        name: "send_message",
        description: "Send a message to a channel as your bot user",
        inputSchema: %{
          type: "object",
          required: ["channel_id", "content"],
          properties: %{
            "channel_id" => %{type: "string", description: "Channel ID"},
            "content" => %{type: "string", description: "Message content (supports markdown)"}
          }
        }
      },
      %{
        name: "reply_to_thread",
        description: "Reply to a thread in a channel as your bot user",
        inputSchema: %{
          type: "object",
          required: ["channel_id", "parent_message_id", "content"],
          properties: %{
            "channel_id" => %{type: "string", description: "Channel ID"},
            "parent_message_id" => %{type: "string", description: "Parent message Snowflake ID"},
            "content" => %{type: "string", description: "Reply content"}
          }
        }
      },
      %{
        name: "react_to_message",
        description: "Add or remove a reaction on a message",
        inputSchema: %{
          type: "object",
          required: ["channel_id", "message_id", "emoji"],
          properties: %{
            "channel_id" => %{type: "string", description: "Channel ID (for authorization)"},
            "message_id" => %{type: "string", description: "Message Snowflake ID"},
            "emoji" => %{type: "string", description: "Emoji name (e.g. thumbsup, heart)"}
          }
        }
      },
      %{
        name: "search_messages",
        description:
          "Search message history. Modes: text (FTS), semantic (vector), hybrid (default)",
        inputSchema: %{
          type: "object",
          required: ["query"],
          properties: %{
            "query" => %{type: "string", description: "Search query"},
            "mode" => %{type: "string", description: "text, semantic, or hybrid (default)"},
            "channel_id" => %{type: "string", description: "Optional: scope to specific channel"},
            "limit" => %{type: "integer", description: "Max results (default 20)"}
          }
        }
      },
      %{
        name: "find_user",
        description: "Find a user by username search (minimum 2 characters)",
        inputSchema: %{
          type: "object",
          required: ["query"],
          properties: %{
            "query" => %{type: "string", description: "Username to search for (min 2 chars)"}
          }
        }
      },
      %{
        name: "send_dm",
        description: "Send a direct message to a user. Creates the DM conversation if needed.",
        inputSchema: %{
          type: "object",
          required: ["user_id", "content"],
          properties: %{
            "user_id" => %{type: "string", description: "Recipient user ID"},
            "content" => %{type: "string", description: "Message content"}
          }
        }
      }
    ]
  end

  defp call_tool("find_user", %{"query" => query}, _session) do
    users = Slackex.Accounts.search_users(query)

    data =
      Enum.map(users, fn u ->
        %{
          id: to_string(u.id),
          username: u.username,
          display_name: u.display_name,
          avatar_url: u.avatar_url
        }
      end)

    {:ok, [%{type: "text", text: Jason.encode!(data)}]}
  end

  defp call_tool("send_dm", %{"user_id" => uid, "content" => content}, session) do
    bot_id = session.bot_user.id

    with {:ok, recipient_id} <- parse_id(uid),
         {:ok, dm} <- DMs.find_or_create_dm(bot_id, recipient_id),
         {:ok, msg} <- DMs.send_dm(dm.id, bot_id, content) do
      {:ok, [%{type: "text", text: Jason.encode!(Serializer.message(msg))}]}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp call_tool("send_message", %{"channel_id" => cid, "content" => content}, session) do
    with {:ok, channel_id} <- parse_id(cid),
         :member <- check_membership(session.bot_user.id, channel_id),
         {:ok, msg} <-
           Slackex.Messaging.send_message(channel_id, session.bot_user.id, content, []) do
      {:ok, [%{type: "text", text: Jason.encode!(Serializer.message_from_map(msg))}]}
    else
      :not_member -> {:error, "Not a member of this channel"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp call_tool(
         "reply_to_thread",
         %{"channel_id" => cid, "parent_message_id" => pid, "content" => content},
         session
       ) do
    with {:ok, channel_id} <- parse_id(cid),
         {:ok, parent_id} <- parse_id(pid),
         :member <- check_membership(session.bot_user.id, channel_id),
         {:ok, msg} <-
           Slackex.Messaging.send_reply(
             channel_id,
             :channel,
             session.bot_user.id,
             parent_id,
             content
           ) do
      {:ok, [%{type: "text", text: Jason.encode!(Serializer.message(msg))}]}
    else
      :not_member -> {:error, "Not a member of this channel"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp call_tool(
         "react_to_message",
         %{"channel_id" => cid, "message_id" => mid, "emoji" => emoji},
         session
       ) do
    with {:ok, channel_id} <- parse_id(cid),
         {:ok, message_id} <- parse_id(mid),
         :member <- check_membership(session.bot_user.id, channel_id) do
      case Slackex.Messaging.toggle_reaction(message_id, session.bot_user.id, emoji) do
        {:ok, {:swapped, _, _}} -> {:ok, [%{type: "text", text: "Reaction swapped"}]}
        {:ok, {action, _}} -> {:ok, [%{type: "text", text: "Reaction #{action}"}]}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      :not_member -> {:error, "Not a member of this channel"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp call_tool("search_messages", %{"query" => query} = params, session) do
    mode =
      case Map.get(params, "mode", "hybrid") do
        "text" -> :text
        "semantic" -> :semantic
        _ -> :hybrid
      end

    limit = params |> Map.get("limit", 20) |> min(100) |> max(1)
    opts = [mode: mode, limit: limit] ++ parse_channel_filter(params)

    case Slackex.Search.search_messages(session.bot_user.id, query, opts) do
      {:ok, messages} ->
        {:ok, [%{type: "text", text: Jason.encode!(Serializer.messages(messages))}]}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp call_tool(name, _args, _session), do: {:error, "Unknown tool: #{name}"}

  # -- Resources ------------------------------------------------------------

  defp resources do
    [
      %{
        uri: "tenun:///channels",
        name: "channels",
        description: "List all public channels with member counts",
        mimeType: "application/json"
      },
      %{
        uri: "tenun:///users/{id}",
        name: "user",
        description: "User profile: display name, username, avatar, is_bot flag",
        mimeType: "application/json"
      },
      %{
        uri: "tenun:///ops/summary",
        name: "ops_summary",
        description: "Low-sensitivity operational snapshot for authenticated MCP clients",
        mimeType: "application/json"
      }
    ]
  end

  defp read_resource("tenun:///channels", _session) do
    channels = Slackex.Chat.list_public_channels([])

    data =
      Enum.map(channels, fn ch ->
        count = Slackex.Chat.count_members(ch.id)
        Serializer.channel(ch, count)
      end)

    {:ok, [%{uri: "tenun:///channels", mimeType: "application/json", text: Jason.encode!(data)}]}
  end

  defp read_resource("tenun:///users/" <> id_str, _session) do
    with {:ok, id} <- parse_id(id_str),
         %{} = user <- Slackex.Accounts.get_user(id) do
      {:ok,
       [
         %{
           uri: "tenun:///users/#{id}",
           mimeType: "application/json",
           text: Jason.encode!(Serializer.user(user))
         }
       ]}
    else
      {:error, msg} -> {:error, msg}
      nil -> {:error, "User not found"}
    end
  end

  defp read_resource("tenun:///ops/summary", _session) do
    snapshot = SystemSummary.snapshot()

    {:ok,
     [
       %{
         uri: "tenun:///ops/summary",
         mimeType: "application/json",
         text: snapshot |> Serializer.ops_summary() |> Jason.encode!()
       }
     ]}
  end

  defp read_resource(uri, _session), do: {:error, "Resource not found: #{uri}"}

  # -- Prompts --------------------------------------------------------------

  defp prompts do
    [
      %{
        name: "summarize_channel",
        description: "Summarize recent activity in a channel",
        arguments: [
          %{name: "channel_id", description: "Channel ID to summarize", required: true},
          %{name: "since", description: "ISO 8601 timestamp (optional)"}
        ]
      },
      %{
        name: "draft_spec",
        description: "Draft a feature spec from a channel discussion",
        arguments: [
          %{
            name: "channel_id",
            description: "Channel ID containing the discussion",
            required: true
          },
          %{name: "thread_id", description: "Optional: specific thread message ID to focus on"}
        ]
      }
    ]
  end

  defp get_prompt("summarize_channel", %{"channel_id" => channel_id} = args, _session) do
    since =
      case Map.get(args, "since") do
        nil -> ""
        s -> " Only include messages after #{s}."
      end

    {:ok,
     %{
       description: "Summarize recent activity in a channel",
       messages: [
         %{
           role: "user",
           content: %{
             type: "text",
             text:
               "Use the `search_messages` tool to fetch recent messages from channel #{channel_id}.#{since}\n\nThen produce a structured summary with: Key Topics, Decisions, Action Items, Open Questions."
           }
         }
       ]
     }}
  end

  defp get_prompt("draft_spec", %{"channel_id" => channel_id} = args, _session) do
    thread =
      case Map.get(args, "thread_id") do
        nil -> ""
        t -> " Focus on the thread starting at message #{t} using `read_thread`."
      end

    {:ok,
     %{
       description: "Draft a feature spec from a channel discussion",
       messages: [
         %{
           role: "user",
           content: %{
             type: "text",
             text:
               "Use the `search_messages` tool to find messages in channel #{channel_id}.#{thread}\n\nThen produce a structured feature spec with: Title, Problem Statement, Proposed Solution, Acceptance Criteria (Given/When/Then), Constraints, Open Questions."
           }
         }
       ]
     }}
  end

  defp get_prompt(name, _args, _session), do: {:error, "Unknown prompt: #{name}"}

  # -- Auth -----------------------------------------------------------------

  defp authenticate(conn) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         hash = McpTokens.hash_token(raw_token),
         %{is_active: true} = token <- McpTokens.get_by_token_hash(hash) do
      McpTokens.touch_last_used(token)
      {:ok, %{bot_user: token.bot_user, mcp_token: token}}
    else
      _ -> {:error, "Bearer"}
    end
  end

  # -- JSON-RPC helpers -----------------------------------------------------

  defp ok_response(id, result) do
    %{jsonrpc: "2.0", id: id, result: result}
  end

  defp error_response(id, code, message) do
    %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_cors_headers()
    |> send_resp(status, Jason.encode!(body))
  end

  defp put_session_header(conn, session) do
    put_resp_header(conn, "mcp-session-id", session.mcp_token.id |> to_string())
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

  defp check_membership(user_id, channel_id) do
    if Slackex.Chat.get_role(user_id, channel_id), do: :member, else: :not_member
  end

  defp parse_channel_filter(%{"channel_id" => cid}) do
    case parse_id(cid) do
      {:ok, id} -> [channel_id: id]
      {:error, _} -> []
    end
  end

  defp parse_channel_filter(_), do: []

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid ID: #{str}"}
    end
  end

  defp parse_id(_), do: {:error, "Invalid ID"}

  defp factory_tool?(name) do
    String.starts_with?(name, "queue_factory") or
      String.starts_with?(name, "list_factory") or
      String.starts_with?(name, "claim_factory") or
      String.starts_with?(name, "factory_") or
      String.starts_with?(name, "submit_factory") or
      String.starts_with?(name, "list_verification") or
      String.starts_with?(name, "claim_verification") or
      String.starts_with?(name, "submit_verification") or
      String.starts_with?(name, "cancel_factory")
  end

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:error, "No body"}
      %{"_json" => [first | _]} -> {:ok, first}
      params when map_size(params) > 0 -> {:ok, params}
      _ -> {:error, "Empty body"}
    end
  end
end
