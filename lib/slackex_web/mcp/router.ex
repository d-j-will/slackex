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
