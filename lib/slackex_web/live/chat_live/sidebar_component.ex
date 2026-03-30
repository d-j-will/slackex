defmodule SlackexWeb.ChatLive.SidebarComponent do
  @moduledoc """
  Sidebar LiveComponent for channel navigation and user footer.

  Receives assigns from the parent `ChatLive.Index`:
  - `@channels`           — list of the user's channels
  - `@active_channel`     — currently selected channel (or nil)
  - `@dm_conversations`   — list of DM conversation maps with :id, :other_user
  - `@active_dm`          — currently selected DM conversation (or nil)
  - `@current_user`       — logged-in user

  Channel creation, browsing, and new DM actions use `patch` links
  to navigate the parent LiveView to the corresponding modal routes.
  """
  use SlackexWeb, :live_component

  import SlackexWeb.ChatComponents

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:channels_expanded, true)
     |> assign(:dms_expanded, true)
     |> assign(:requests_expanded, true)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_section", %{"section" => "channels"}, socket) do
    {:noreply, assign(socket, :channels_expanded, !socket.assigns.channels_expanded)}
  end

  def handle_event("toggle_section", %{"section" => "dms"}, socket) do
    {:noreply, assign(socket, :dms_expanded, !socket.assigns.dms_expanded)}
  end

  def handle_event("toggle_section", %{"section" => "requests"}, socket) do
    {:noreply, assign(socket, :requests_expanded, !socket.assigns.requests_expanded)}
  end

  def handle_event("show_profile", %{"user-id" => user_id}, socket) do
    case Integer.parse(user_id) do
      {int_id, ""} -> send(self(), {:show_profile, int_id})
      _ -> :noop
    end

    {:noreply, socket}
  end

  defp truncate_preview(nil, _max_length), do: ""
  defp truncate_preview(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate_preview(text, max_length) do
    String.slice(text, 0, max_length) <> "..."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside class="flex flex-col h-full bg-base-200">
      <%!-- Workspace header --%>
      <div class="p-4 border-b border-base-300 flex items-center justify-between">
        <h1 class="font-bold text-lg truncate">Tenun</h1>
      </div>

      <%!-- Scrollable navigation --%>
      <nav class="flex-1 overflow-y-auto p-2 space-y-4">
        <%!-- Channels section --%>
        <div>
          <div class="flex items-center justify-between px-2 py-1">
            <button
              phx-click="toggle_section"
              phx-value-section="channels"
              phx-target={@myself}
              class="flex items-center gap-1 text-xs font-semibold uppercase tracking-wider text-base-content/60 hover:text-base-content"
            >
              <span>Channels</span>
              <svg
                class={["w-3 h-3 transition-transform", !@channels_expanded && "-rotate-90"]}
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 9l-7 7-7-7"
                />
              </svg>
            </button>
            <div class="flex items-center gap-0.5">
              <.link
                patch={~p"/chat/channels/browse"}
                class="btn btn-ghost btn-xs btn-circle text-base-content/60 hover:text-base-content"
                aria-label="Browse channels"
              >
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                  />
                </svg>
              </.link>
              <.link
                patch={~p"/chat/channels/new"}
                class="btn btn-ghost btn-xs btn-circle text-base-content/60 hover:text-base-content"
                aria-label="Create channel"
              >
                +
              </.link>
            </div>
          </div>

          <ul :if={@channels_expanded} class="mt-1 space-y-0.5">
            <.channel_list_item
              :for={channel <- @channels}
              channel={channel}
              active={@active_channel != nil && @active_channel.id == channel.id}
              unread_count={Map.get(@unread_counts.channel_counts, channel.id, 0)}
            />
          </ul>

          <p
            :if={@channels_expanded && @channels == []}
            class="text-xs text-base-content/40 px-2 py-2"
          >
            No channels yet.
          </p>
        </div>

        <%!-- Message Requests section --%>
        <div :if={@dm_request_count > 0}>
          <button
            phx-click="toggle_section"
            phx-value-section="requests"
            phx-target={@myself}
            class="flex items-center justify-between w-full px-2 py-1 text-xs font-semibold uppercase tracking-wider text-base-content/60 hover:text-base-content"
          >
            <span class="flex items-center gap-2">
              Message Requests
              <span class="badge badge-warning badge-sm min-w-5 h-5">
                {@dm_request_count}
              </span>
            </span>
            <svg
              class={["w-3 h-3 transition-transform", !@requests_expanded && "-rotate-90"]}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 9l-7 7-7-7"
              />
            </svg>
          </button>

          <ul :if={@requests_expanded} class="mt-1 space-y-1">
            <li :for={request <- @dm_requests} class="px-2 py-1.5 rounded-lg bg-base-300/50">
              <div class="flex items-center gap-2 mb-1">
                <.avatar user={request.sender} size="sm" />
                <span class="text-sm font-medium truncate">
                  {request.sender.display_name || request.sender.username}
                </span>
              </div>
              <p class="text-xs text-base-content/60 mb-2 line-clamp-2">
                {truncate_preview(request.preview_text, 100)}
              </p>
              <div class="flex gap-1">
                <button
                  phx-click="accept_request"
                  phx-value-id={request.id}
                  class="btn btn-success btn-xs flex-1"
                >
                  Accept
                </button>
                <button
                  phx-click="decline_request"
                  phx-value-id={request.id}
                  class="btn btn-ghost btn-xs flex-1"
                >
                  Decline
                </button>
                <button
                  phx-click="block_request_sender"
                  phx-value-id={request.id}
                  class="btn btn-error btn-xs"
                >
                  Block
                </button>
              </div>
            </li>
          </ul>
        </div>

        <%!-- Direct Messages section --%>
        <div>
          <button
            phx-click="toggle_section"
            phx-value-section="dms"
            phx-target={@myself}
            class="flex items-center justify-between w-full px-2 py-1 text-xs font-semibold uppercase tracking-wider text-base-content/60 hover:text-base-content"
          >
            <span>Direct Messages</span>
            <svg
              class={["w-3 h-3 transition-transform", !@dms_expanded && "-rotate-90"]}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 9l-7 7-7-7"
              />
            </svg>
          </button>

          <ul :if={@dms_expanded} class="mt-1 space-y-0.5">
            <.dm_list_item
              :for={dm <- @dm_conversations}
              dm={dm}
              active={@active_dm != nil && @active_dm.id == dm.id}
              unread_count={Map.get(@unread_counts.dm_counts, dm.id, 0)}
              online={MapSet.member?(@online_user_ids, dm.other_user.id)}
            />
          </ul>

          <div :if={@dms_expanded} class="mt-1 px-2">
            <.link
              patch={~p"/chat/dm/new"}
              class="btn btn-ghost btn-xs w-full justify-start gap-1 text-base-content/60"
            >
              + New Message
            </.link>
          </div>
        </div>
      </nav>

      <%!-- User footer --%>
      <div class="p-3 border-t border-base-300 flex items-center gap-2">
        <span
          data-profile-user-id={@current_user.id}
          phx-click="show_profile"
          phx-value-user-id={@current_user.id}
          phx-target={@myself}
          class="cursor-pointer"
        >
          <.avatar user={@current_user} size="sm" online={true} />
        </span>
        <span class="text-sm min-w-0 flex-1">
          <span class="font-medium truncate block">
            {@current_user.display_name || @current_user.username}
          </span>
          <span
            :if={@current_user.status && @current_user.status != ""}
            class="truncate block text-xs text-base-content/50 leading-tight"
          >
            {@current_user.status}
          </span>
        </span>
        <span
          :if={@show_node}
          data-testid="node-badge"
          class="badge badge-info badge-sm font-mono shrink-0"
        >
          {@node_name}
        </span>
        <button
          phx-click="edit_profile"
          class="btn btn-ghost btn-xs btn-circle"
          aria-label="Edit profile"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"
            />
          </svg>
        </button>
        <button
          phx-click={JS.dispatch("phx:set-theme", detail: %{toggle: true})}
          class="btn btn-ghost btn-xs btn-circle"
          aria-label="Toggle theme"
          data-phx-theme="toggle"
        >
          <span class="hero-sun-solid size-3.5 hidden dark:block" />
          <span class="hero-moon-solid size-3.5 dark:hidden" />
        </button>
        <.link
          href={~p"/users/log-out"}
          method="delete"
          class="btn btn-ghost btn-xs"
        >
          Log out
        </.link>
      </div>
    </aside>
    """
  end
end
