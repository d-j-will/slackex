defmodule SlackexWeb.MCP.Router do
  use Phantom.Router,
    name: "Tenun",
    vsn: "1.0.0",
    instructions: """
    Tenun is a messaging platform. You can read channels, send messages,
    search message history, and subscribe to real-time channel events.
    Use the bot user identity associated with your token.
    """

  alias Slackex.Chat
  alias Slackex.Accounts
  alias Slackex.Integrations.McpTokens
  alias SlackexWeb.MCP.Serializer

  require Phantom.Resource, as: Resource
  require Phantom.Tool, as: Tool

  @json "application/json"

  # -- Auth ------------------------------------------------------------------

  @impl true
  def connect(session, %Plug.Conn{} = conn) do
    with ["Bearer " <> raw_token] <- Plug.Conn.get_req_header(conn, "authorization"),
         hash = McpTokens.hash_token(raw_token),
         %{is_active: true} = token <- McpTokens.get_by_token_hash(hash) do
      McpTokens.touch_last_used(token)
      session = Phantom.Session.assign(session, :bot_user, token.bot_user)
      session = Phantom.Session.assign(session, :mcp_token, token)
      {:ok, session}
    else
      _ -> {:unauthorized, "Bearer"}
    end
  end

  # -- Resources -------------------------------------------------------------

  resource("tenun:///channels", __MODULE__, :list_channels,
    description: "List all public channels with member counts",
    mime_type: "application/json"
  )

  resource("tenun:///channels/:id", __MODULE__, :read_channel,
    description: "Get channel metadata: name, slug, description, member count",
    mime_type: "application/json"
  )

  resource("tenun:///channels/:id/messages", __MODULE__, :read_messages,
    description:
      "Paginated messages in a channel. Params: before, after (Snowflake IDs), limit (default 50, max 200)",
    mime_type: "application/json"
  )

  resource("tenun:///channels/:id/threads/:message_id", __MODULE__, :read_thread,
    description: "Full thread from a parent message",
    mime_type: "application/json"
  )

  resource("tenun:///users/:id", __MODULE__, :read_user,
    description: "User profile: display name, username, avatar, is_bot flag",
    mime_type: "application/json"
  )

  # Resource handlers receive (path_params, session) per Phantom.ResourcePlug.
  # We pass uri: and mime_type: explicitly so handlers are testable without
  # a full Phantom request context in session.

  def list_channels(_params, session) do
    channels = Chat.list_public_channels([])

    data =
      Enum.map(channels, fn ch ->
        count = Chat.count_members(ch.id)
        Serializer.channel(ch, count)
      end)

    {:reply, Resource.text(Jason.encode!(data), uri: "tenun:///channels", mime_type: @json),
     session}
  end

  def read_channel(%{"id" => id}, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(id)
    uri = "tenun:///channels/#{id}"

    if Chat.get_role(bot.id, channel_id) do
      channel = Chat.get_channel!(channel_id)
      count = Chat.count_members(channel.id)

      {:reply,
       Resource.text(Jason.encode!(Serializer.channel(channel, count)),
         uri: uri,
         mime_type: @json
       ), session}
    else
      {:reply,
       Resource.text(Jason.encode!(%{error: "Not a member of this channel"}),
         uri: uri,
         mime_type: @json
       ), session}
    end
  end

  def read_messages(%{"id" => id}, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(id)
    uri = "tenun:///channels/#{id}/messages"

    if Chat.get_role(bot.id, channel_id) do
      query_params = extract_query_params(session)
      limit = query_params |> Map.get("limit", "50") |> parse_int() |> min(200)
      opts = [limit: limit]

      opts =
        if query_params["before"],
          do: [{:before, String.to_integer(query_params["before"])} | opts],
          else: opts

      opts =
        if query_params["after"],
          do: [{:after, String.to_integer(query_params["after"])} | opts],
          else: opts

      messages = Chat.list_messages(channel_id, opts)

      {:reply,
       Resource.text(Jason.encode!(Serializer.messages(messages)), uri: uri, mime_type: @json),
       session}
    else
      {:reply,
       Resource.text(Jason.encode!(%{error: "Not a member of this channel"}),
         uri: uri,
         mime_type: @json
       ), session}
    end
  end

  def read_thread(%{"id" => channel_id_str, "message_id" => msg_id_str}, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(channel_id_str)
    uri = "tenun:///channels/#{channel_id_str}/threads/#{msg_id_str}"

    if Chat.get_role(bot.id, channel_id) do
      parent = Chat.get_message!(String.to_integer(msg_id_str))

      if parent.channel_id == channel_id do
        messages = Chat.list_thread(parent.id, [])

        {:reply,
         Resource.text(Jason.encode!(Serializer.messages(messages)), uri: uri, mime_type: @json),
         session}
      else
        {:reply,
         Resource.text(Jason.encode!(%{error: "Message does not belong to this channel"}),
           uri: uri,
           mime_type: @json
         ), session}
      end
    else
      {:reply,
       Resource.text(Jason.encode!(%{error: "Not a member of this channel"}),
         uri: uri,
         mime_type: @json
       ), session}
    end
  end

  def read_user(%{"id" => id}, session) do
    uri = "tenun:///users/#{id}"

    case Accounts.get_user(String.to_integer(id)) do
      nil ->
        {:reply,
         Resource.text(Jason.encode!(%{error: "User not found"}), uri: uri, mime_type: @json),
         session}

      user ->
        {:reply, Resource.text(Jason.encode!(Serializer.user(user)), uri: uri, mime_type: @json),
         session}
    end
  end

  # -- Tools ----------------------------------------------------------------

  tool(:send_message,
    description: "Send a message to a channel as your bot user",
    input_schema: %{
      required: ["channel_id", "content"],
      properties: %{
        "channel_id" => %{type: "string", description: "Channel ID"},
        "content" => %{type: "string", description: "Message content (supports markdown)"}
      }
    }
  )

  tool(:reply_to_thread,
    description: "Reply to a thread in a channel as your bot user",
    input_schema: %{
      required: ["channel_id", "parent_message_id", "content"],
      properties: %{
        "channel_id" => %{type: "string", description: "Channel ID"},
        "parent_message_id" => %{type: "string", description: "Parent message Snowflake ID"},
        "content" => %{type: "string", description: "Reply content"}
      }
    }
  )

  tool(:react_to_message,
    description: "Add or remove a reaction on a message",
    input_schema: %{
      required: ["channel_id", "message_id", "emoji"],
      properties: %{
        "channel_id" => %{type: "string", description: "Channel ID (for authorization)"},
        "message_id" => %{type: "string", description: "Message Snowflake ID"},
        "emoji" => %{type: "string", description: "Emoji name (e.g. thumbsup, heart)"}
      }
    }
  )

  tool(:search_messages,
    description: "Search message history. Modes: text (FTS), semantic (vector), hybrid (default)",
    input_schema: %{
      required: ["query"],
      properties: %{
        "query" => %{type: "string", description: "Search query"},
        "mode" => %{type: "string", description: "text, semantic, or hybrid (default)"},
        "channel_id" => %{type: "string", description: "Optional: scope to specific channel"},
        "limit" => %{type: "integer", description: "Max results (default 20)"}
      }
    }
  )

  # Tool handlers

  def send_message(%{"channel_id" => cid, "content" => content}, session) do
    bot = session.assigns.bot_user
    channel_id = String.to_integer(cid)

    case Slackex.Messaging.send_message(channel_id, bot.id, content, []) do
      {:ok, msg} ->
        {:reply, Tool.text(Jason.encode!(Serializer.message_from_map(msg))), session}

      {:error, reason} ->
        {:reply, Tool.text("Error: #{inspect(reason)}"), session}
    end
  end

  def reply_to_thread(
        %{"channel_id" => cid, "parent_message_id" => pid, "content" => content},
        session
      ) do
    bot = session.assigns.bot_user

    case Slackex.Messaging.send_reply(
           String.to_integer(cid),
           :channel,
           bot.id,
           String.to_integer(pid),
           content
         ) do
      {:ok, msg} ->
        {:reply, Tool.text(Jason.encode!(Serializer.message(msg))), session}

      {:error, reason} ->
        {:reply, Tool.text("Error: #{inspect(reason)}"), session}
    end
  end

  def react_to_message(
        %{"channel_id" => cid, "message_id" => mid, "emoji" => emoji},
        session
      ) do
    bot = session.assigns.bot_user

    if Chat.get_role(bot.id, String.to_integer(cid)) do
      case Slackex.Messaging.toggle_reaction(String.to_integer(mid), bot.id, emoji) do
        {:ok, {:swapped, _, _}} ->
          {:reply, Tool.text("Reaction swapped"), session}

        {:ok, {action, _}} ->
          {:reply, Tool.text("Reaction #{action}"), session}

        {:error, reason} ->
          {:reply, Tool.text("Error: #{inspect(reason)}"), session}
      end
    else
      {:reply, Tool.text("Error: Not a member of this channel"), session}
    end
  end

  def search_messages(%{"query" => query} = params, session) do
    bot = session.assigns.bot_user

    mode =
      case Map.get(params, "mode", "hybrid") do
        "text" -> :text
        "semantic" -> :semantic
        _ -> :hybrid
      end

    limit = Map.get(params, "limit", 20)
    opts = [mode: mode, limit: limit]

    opts =
      if params["channel_id"],
        do: [{:channel_id, String.to_integer(params["channel_id"])} | opts],
        else: opts

    case Slackex.Search.search_messages(bot.id, query, opts) do
      {:ok, messages} ->
        {:reply, Tool.text(Jason.encode!(Serializer.messages(messages))), session}

      {:error, reason} ->
        {:reply, Tool.text("Error: #{inspect(reason)}"), session}
    end
  end

  # -- Private ---------------------------------------------------------------

  defp extract_query_params(session) do
    case session do
      %{request: %{params: %{"uri" => uri}}} when is_binary(uri) ->
        case URI.new(uri) do
          {:ok, %{query: query}} when is_binary(query) -> URI.decode_query(query)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 50
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: 50
end
