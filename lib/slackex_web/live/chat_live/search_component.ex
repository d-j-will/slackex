defmodule SlackexWeb.ChatLive.SearchComponent do
  @moduledoc """
  LiveComponent for searching messages across channels and DMs.

  Manages search state: query text, results, search mode, and loading flag.
  Delegates actual search execution to the parent LiveView via message passing
  to keep async work outside the component.

  ## Assigns

    * `@query` - current search query string
    * `@results` - list of search result maps
    * `@search_mode` - one of :hybrid, :text, :semantic
    * `@searching` - boolean loading flag
    * `@current_user` - the logged-in user

  ## Events

    * `"search"` - fires on input change (debounced 300ms via phx-debounce)
    * `"set_mode"` - switches search mode
    * `"jump_to_message"` - navigates to the message in its conversation
    * `"close_search"` - closes the search panel

  """
  use SlackexWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:search_mode, :hybrid)
     |> assign(:searching, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if String.length(query) >= 2 do
      send(
        self(),
        {:perform_search, query, socket.assigns.search_mode, socket.assigns.id}
      )

      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:searching, true)}
    else
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:results, [])
       |> assign(:searching, false)}
    end
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    search_mode = String.to_existing_atom(mode)
    query = socket.assigns.query

    socket = assign(socket, :search_mode, search_mode)

    if String.length(query) >= 2 do
      send(
        self(),
        {:perform_search, query, search_mode, socket.assigns.id}
      )

      {:noreply, assign(socket, :searching, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "jump_to_message",
        %{"message-id" => message_id, "channel-id" => channel_id},
        socket
      ) do
    send(self(), {:jump_to_message, message_id, channel_id, nil})
    {:noreply, socket}
  end

  def handle_event("jump_to_message", %{"message-id" => message_id, "dm-id" => dm_id}, socket) do
    send(self(), {:jump_to_message, message_id, nil, dm_id})
    {:noreply, socket}
  end

  def handle_event("close_search", _params, socket) do
    send(self(), :close_search)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="search-component" class="flex flex-col h-full border-l border-base-300 bg-base-100 w-80">
      <div class="p-3 border-b border-base-300 flex items-center justify-between">
        <h3 class="font-bold text-sm">Search messages</h3>
        <button
          type="button"
          phx-click="close_search"
          phx-target={@myself}
          class="btn btn-ghost btn-sm btn-square"
          aria-label="Close"
        >
          <span class="hero-x-mark size-5" />
        </button>
      </div>

      <div class="p-3 space-y-2">
        <form phx-change="search" phx-submit="search" phx-target={@myself}>
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Search messages..."
            class="input input-bordered input-sm w-full"
            phx-debounce="300"
            autocomplete="off"
          />
        </form>

        <div class="flex gap-1">
          <button
            :for={mode <- [:hybrid, :text, :semantic]}
            phx-click="set_mode"
            phx-value-mode={mode}
            phx-target={@myself}
            class={[
              "btn btn-xs",
              @search_mode == mode && "btn-primary",
              @search_mode != mode && "btn-ghost"
            ]}
          >
            {mode}
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto px-3 pb-3">
        <%= if @searching do %>
          <div class="flex items-center justify-center py-8 text-sm text-base-content/50">
            <span class="loading loading-spinner loading-sm mr-2"></span> Searching...
          </div>
        <% else %>
          <%= if @results != [] do %>
            <ul class="space-y-1">
              <li :for={result <- @results} class="rounded-lg hover:bg-base-200 transition-colors">
                <button
                  phx-click="jump_to_message"
                  phx-target={@myself}
                  phx-value-message-id={result.id}
                  phx-value-channel-id={Map.get(result, :channel_id)}
                  phx-value-dm-id={Map.get(result, :dm_conversation_id)}
                  class="w-full text-left px-3 py-2"
                >
                  <div class="flex items-baseline gap-2">
                    <span class="font-semibold text-xs">
                      {sender_name(result)}
                    </span>
                    <time class="text-xs text-base-content/40">
                      {format_result_time(result)}
                    </time>
                  </div>
                  <p class="text-sm text-base-content/80 truncate mt-0.5">
                    {Map.get(result, :content, "")}
                  </p>
                </button>
              </li>
            </ul>
          <% else %>
            <%= if @query != "" and String.length(@query) >= 2 do %>
              <p class="text-sm text-base-content/50 text-center py-8">
                No results found
              </p>
            <% else %>
              <p class="text-sm text-base-content/40 text-center py-8">
                Type at least 2 characters to search
              </p>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp sender_name(%{sender: %{username: username}}), do: username
  defp sender_name(%{sender: %{"username" => username}}), do: username
  defp sender_name(_), do: "unknown"

  defp format_result_time(%{inserted_at: ts}) when not is_nil(ts) do
    Calendar.strftime(ts, "%b %d, %H:%M")
  end

  defp format_result_time(_), do: ""
end
