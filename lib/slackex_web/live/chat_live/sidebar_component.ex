defmodule SlackexWeb.ChatLive.SidebarComponent do
  @moduledoc """
  Sidebar LiveComponent for channel navigation and user footer.

  Receives assigns from the parent `ChatLive.Index`:
  - `@channels`           — list of the user's channels
  - `@active_channel`     — currently selected channel (or nil)
  - `@dm_conversations`   — list of DM conversation maps with :id, :other_user
  - `@active_dm`          — currently selected DM conversation (or nil)
  - `@current_user`       — logged-in user

  Sends sidebar actions to the parent via `send(self(), {:sidebar_action, action})`.
  """
  use SlackexWeb, :live_component

  import SlackexWeb.ChatComponents

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:channels_expanded, true)
     |> assign(:dms_expanded, true)}
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

  @impl true
  def render(assigns) do
    ~H"""
    <aside class="flex flex-col h-full bg-base-200">
      <%!-- Workspace header --%>
      <div class="p-4 border-b border-base-300 flex items-center justify-between">
        <h1 class="font-bold text-lg truncate">Slackex</h1>
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
            <.link
              patch={~p"/chat/channels/new"}
              class="btn btn-ghost btn-xs btn-circle text-base-content/60 hover:text-base-content"
              aria-label="Create channel"
            >
              +
            </.link>
          </div>

          <ul :if={@channels_expanded} class="mt-1 space-y-0.5">
            <.channel_list_item
              :for={channel <- @channels}
              channel={channel}
              active={@active_channel != nil && @active_channel.id == channel.id}
            />
          </ul>

          <p
            :if={@channels_expanded && @channels == []}
            class="text-xs text-base-content/40 px-2 py-2"
          >
            No channels yet.
          </p>
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
        <.avatar user={@current_user} size="sm" />
        <span class="text-sm font-medium truncate flex-1">
          {@current_user.display_name || @current_user.username}
        </span>
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
