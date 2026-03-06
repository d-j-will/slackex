defmodule SlackexWeb.ChatLive.PinnedMessagesModal do
  @moduledoc """
  LiveComponent for the pinned messages modal.
  Lists all pinned messages with content preview and sender info.
  Admin+ users can unpin messages.
  """
  use SlackexWeb, :live_component

  alias Slackex.Chat
  alias Slackex.Chat.Permissions
  alias Slackex.Chat.Pins

  @impl true
  def update(assigns, socket) do
    pins = Pins.list_pinned_messages(assigns.channel.id)
    actor_role = Chat.get_role(assigns.current_user.id, assigns.channel.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:pins, pins)
     |> assign(:can_unpin, Permissions.can?(actor_role, :pin_message))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{socket.assigns.channel.slug}")}
  end

  def handle_event("unpin", %{"message-id" => raw_id}, socket) do
    _result =
      with {message_id, ""} <- Integer.parse(raw_id) do
        Pins.unpin_message(
          socket.assigns.channel.id,
          socket.assigns.current_user.id,
          message_id
        )
      end

    pins = Pins.list_pinned_messages(socket.assigns.channel.id)
    send(self(), {:pin_count_updated, length(pins)})
    {:noreply, assign(socket, :pins, pins)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="pinned-messages-modal"
      phx-window-keydown="close_modal"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_modal"
        phx-target={@myself}
      />

      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full sm:max-w-lg max-h-[70vh] flex flex-col">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-bold text-lg">
              Pinned Messages ({length(@pins)})
            </h3>
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

          <div class="overflow-y-auto flex-1">
            <div
              :if={@pins == []}
              class="text-center text-base-content/50 py-12 text-sm"
            >
              No pinned messages yet.
            </div>
            <div
              :for={pin <- @pins}
              class="px-4 py-3 border-b border-base-200 last:border-b-0"
            >
              <div class="flex items-start gap-3">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 mb-1">
                    <span class="font-medium text-sm">
                      {pin.message.sender.display_name || pin.message.sender.username}
                    </span>
                    <span class="text-xs text-base-content/40">
                      {Calendar.strftime(pin.inserted_at, "%b %d, %Y")}
                    </span>
                  </div>
                  <p class="text-sm text-base-content/80 line-clamp-3">
                    {pin.message.content}
                  </p>
                </div>
                <button
                  :if={@can_unpin}
                  phx-click="unpin"
                  phx-value-message-id={pin.message.id}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs text-warning shrink-0"
                  title="Unpin message"
                >
                  Unpin
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
