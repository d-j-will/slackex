defmodule SlackexWeb.ChatLive.BrowseChannelsModal do
  @moduledoc """
  LiveComponent for the Browse Channels modal.

  Lists public channels the current user has not joined.
  Supports search/filter by name. Clicking Join adds the user
  to the channel and sends `{:channel_joined, channel}` to the parent LiveView.
  """
  use SlackexWeb, :live_component

  alias Slackex.Chat

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:search_query, "")
     |> assign(:all_channels, [])
     |> assign(:filtered_channels, [])}
  end

  @impl true
  def update(assigns, socket) do
    channels =
      Chat.list_public_channels(exclude_member: assigns.current_user.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:all_channels, channels)
     |> assign(:filtered_channels, filter_channels(channels, socket.assigns.search_query))}
  end

  @impl true
  def handle_event("search", %{"search_query" => query}, socket) do
    filtered = filter_channels(socket.assigns.all_channels, query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:filtered_channels, filtered)}
  end

  def handle_event("join", %{"channel-id" => channel_id}, socket) do
    user = socket.assigns.current_user

    case Chat.join_channel(user.id, String.to_integer(channel_id)) do
      {:ok, _subscription} ->
        channel = Chat.get_channel!(String.to_integer(channel_id))
        send(self(), {:channel_joined, channel})
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end

  defp filter_channels(channels, ""), do: channels

  defp filter_channels(channels, query) do
    downcased = String.downcase(query)

    Enum.filter(channels, fn channel ->
      channel.name
      |> String.downcase()
      |> String.contains?(downcased)
    end)
  end

  defp member_count_label(1), do: "1 member"
  defp member_count_label(count), do: "#{count} members"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="browse-channels-modal">
      <div
        id="browse-channels-modal-backdrop"
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_modal"
        phx-target={@myself}
      />

      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full sm:max-w-2xl">
          <div class="p-4 border-b border-base-300">
            <h3 class="font-bold text-lg">Browse Channels</h3>
          </div>

          <form
            id="browse-channels-search"
            phx-change="search"
            phx-target={@myself}
            phx-submit="search"
          >
            <div class="p-4 sticky top-0 bg-base-100">
              <input
                type="text"
                name="search_query"
                value={@search_query}
                placeholder="Search channels..."
                class="input input-bordered w-full"
                phx-debounce="300"
                autocomplete="off"
              />
            </div>
          </form>

          <ul class="max-h-80 overflow-y-auto px-2 pb-2">
            <li
              :for={channel <- @filtered_channels}
              class="flex items-center justify-between px-3 py-3 rounded-lg hover:bg-base-200 transition-colors"
            >
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium">
                  <span class="text-base-content/50">#</span> {channel.name}
                </p>
                <p :if={channel.description} class="text-xs text-base-content/50 truncate mt-0.5">
                  {channel.description}
                </p>
              </div>
              <div class="flex items-center gap-3 ml-3 flex-shrink-0">
                <span class="badge badge-sm badge-ghost">
                  {member_count_label(channel.member_count)}
                </span>
                <button
                  phx-click="join"
                  phx-value-channel-id={channel.id}
                  phx-target={@myself}
                  class="btn btn-primary btn-sm"
                >
                  Join
                </button>
              </div>
            </li>
          </ul>

          <div
            :if={@filtered_channels == []}
            class="px-4 pb-4 text-sm text-base-content/50"
          >
            No channels found
          </div>
        </div>
      </div>
    </div>
    """
  end
end
