defmodule SlackexWeb.ChatLive.QuickSwitcherModal do
  @moduledoc """
  Quick switcher modal for fuzzy-searching channels and DMs.
  Triggered by Ctrl+K / Cmd+K.
  """
  use SlackexWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])}
  end

  @impl true
  def update(assigns, socket) do
    all_items = build_items(assigns.channels, assigns.dm_conversations, assigns.current_user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:all_items, all_items)
     |> assign(:results, filter_items(all_items, socket.assigns.query))}
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), :close_quick_switcher)
    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) do
    results = filter_items(socket.assigns.all_items, query)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:results, results)}
  end

  def handle_event("navigate", %{"to" => path}, socket) do
    send(self(), :close_quick_switcher)
    {:noreply, push_navigate(socket, to: path)}
  end

  defp build_items(channels, dm_conversations, current_user) do
    channel_items =
      Enum.map(channels, fn ch ->
        %{type: :channel, name: "##{ch.name}", path: ~p"/chat/#{ch.slug}"}
      end)

    dm_items =
      Enum.map(dm_conversations, fn dm ->
        other = dm_other_name(dm, current_user.id)
        %{type: :dm, name: other, path: ~p"/chat/dm/#{dm.id}"}
      end)

    channel_items ++ dm_items
  end

  defp dm_other_name(dm, current_user_id) do
    cond do
      dm.user_a_id == dm.user_b_id ->
        dm.user_a.display_name || dm.user_a.username

      dm.user_a_id == current_user_id ->
        dm.user_b.display_name || dm.user_b.username

      true ->
        dm.user_a.display_name || dm.user_a.username
    end
  end

  defp filter_items(_items, ""), do: []

  defp filter_items(items, query) do
    downcased = String.downcase(query)

    items
    |> Enum.filter(fn item ->
      item.name |> String.downcase() |> String.contains?(downcased)
    end)
    |> Enum.take(10)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="quick-switcher"
      phx-window-keydown="close"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close"
        phx-target={@myself}
      />

      <div class="fixed inset-0 z-50 flex items-start justify-center pt-[15vh] px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full sm:max-w-md">
          <div class="p-3">
            <input
              type="text"
              name="query"
              value={@query}
              placeholder="Search channels and conversations..."
              class="input input-bordered w-full"
              phx-keyup="search"
              phx-target={@myself}
              phx-debounce="100"
              autofocus
            />
          </div>

          <div class="max-h-64 overflow-y-auto">
            <div
              :if={@query != "" and @results == []}
              class="px-4 py-6 text-center text-base-content/50 text-sm"
            >
              No matches found.
            </div>
            <button
              :for={item <- @results}
              phx-click="navigate"
              phx-value-to={item.path}
              phx-target={@myself}
              class="w-full px-4 py-2.5 flex items-center gap-3 hover:bg-base-200 text-left transition-colors"
            >
              <span :if={item.type == :channel} class="text-base-content/50 text-sm">#</span>
              <span
                :if={item.type == :dm}
                class="hero-chat-bubble-left-right size-4 text-base-content/50"
              />
              <span class="text-sm truncate">{item.name}</span>
            </button>
          </div>

          <div class="px-4 py-2 border-t border-base-300 text-xs text-base-content/40">
            <kbd class="kbd kbd-xs">↵</kbd> to select <span class="mx-2">·</span>
            <kbd class="kbd kbd-xs">esc</kbd> to close
          </div>
        </div>
      </div>
    </div>
    """
  end
end
