defmodule SlackexWeb.ChatLive.NewDmModal do
  @moduledoc """
  LiveComponent for the New DM modal.

  Manages its own search state and renders a user search interface.
  When a user is selected, sends `{:start_dm, user_id}` to the parent LiveView.
  """
  use SlackexWeb, :live_component

  alias Slackex.Accounts
  alias Slackex.Chat

  import SlackexWeb.ChatComponents

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("search", %{"search_query" => query}, socket) do
    blocked_ids = Chat.list_blocked_user_ids(socket.assigns.current_user.id)

    results =
      Accounts.search_users(query, exclude: blocked_ids)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("select_user", %{"user-id" => user_id}, socket) do
    send(self(), {:start_dm_request, String.to_integer(user_id)})
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="new-dm-modal" phx-window-keydown="close_modal" phx-key="Escape" phx-target={@myself}>
      <div
        id="new-dm-modal-backdrop"
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_modal"
        phx-target={@myself}
      />

      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full max-w-md">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-bold text-lg">New Message</h3>
            <button
              type="button"
              phx-click="close_modal"
              phx-target={@myself}
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-5" />
            </button>
          </div>

          <form id="new-dm-search" phx-change="search" phx-target={@myself} phx-submit="search">
            <div class="p-4">
              <input
                type="text"
                name="search_query"
                value={@search_query}
                placeholder="Search users..."
                class="input input-bordered w-full"
                phx-debounce="300"
                autocomplete="off"
              />
            </div>
          </form>

          <ul class="max-h-60 overflow-y-auto px-2 pb-2">
            <li
              :for={user <- @search_results}
              data-user-id={user.id}
              phx-click="select_user"
              phx-value-user-id={user.id}
              phx-target={@myself}
              class="flex items-center gap-3 px-3 py-2 rounded-lg cursor-pointer hover:bg-base-200 transition-colors"
            >
              <.avatar user={user} size="sm" />
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium truncate">
                  {user.display_name || user.username}
                </p>
                <p class="text-xs text-base-content/50 truncate">@{user.username}</p>
              </div>
            </li>
          </ul>

          <div
            :if={@search_query != "" and byte_size(@search_query) >= 2 and @search_results == []}
            class="px-4 pb-4 text-sm text-base-content/50"
          >
            No users found.
          </div>
        </div>
      </div>
    </div>
    """
  end
end
