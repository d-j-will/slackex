defmodule SlackexWeb.MCP.Subscriber do
  @moduledoc """
  PubSub → SSE bridge for MCP sessions. One subscriber per channel subscription
  per MCP session. Filters events by the agent's requested event types and
  forwards matching events to the session process.
  """

  use GenServer

  @default_event_types ["new_message", "message_edited", "message_deleted"]

  # Maps PubSub envelope event names (dot notation) to MCP event types (underscore)
  @event_map %{
    "message.new" => "new_message",
    "message.edited" => "message_edited",
    "message.deleted" => "message_deleted",
    "reaction.toggled" => "reaction_toggled",
    "typing" => "typing"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(%{session_pid: session_pid, channel_id: channel_id, event_types: event_types}) do
    types = event_types || @default_event_types
    :ok = Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel_id}")

    {:ok,
     %{
       session_pid: session_pid,
       channel_id: channel_id,
       event_types: MapSet.new(types)
     }}
  end

  @impl true
  def handle_info({:envelope, %{event: event, payload: payload, meta: meta}}, state) do
    case Map.get(@event_map, event) do
      nil ->
        {:noreply, state}

      mcp_type ->
        if MapSet.member?(state.event_types, mcp_type) do
          send(
            state.session_pid,
            {:mcp_event,
             %{
               type: mcp_type,
               payload: payload,
               timestamp: meta.sent_at,
               channel_id: state.channel_id
             }}
          )
        end

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
