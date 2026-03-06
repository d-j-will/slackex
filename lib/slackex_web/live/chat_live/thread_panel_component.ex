defmodule SlackexWeb.ChatLive.ThreadPanelComponent do
  use SlackexWeb, :live_component

  alias Slackex.Chat

  import SlackexWeb.ChatComponents

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:replies, [])
     |> assign(:reply_form, to_form(%{"content" => ""}, as: :reply))}
  end

  @impl true
  def update(%{new_reply: reply}, socket) do
    {:ok, assign(socket, :replies, socket.assigns.replies ++ [reply])}
  end

  def update(assigns, socket) do
    replies = Chat.list_thread(assigns.parent_message.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:replies, replies)}
  end

  @impl true
  def handle_event("send_reply", %{"reply" => %{"content" => content}}, socket) do
    if String.trim(content) != "" do
      send(self(), {:send_thread_reply, socket.assigns.parent_message.id, content})
    end

    {:noreply, assign(socket, :reply_form, to_form(%{"content" => ""}, as: :reply))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={[
      "flex flex-col border-l border-base-300 bg-base-100",
      "w-full md:w-[400px] h-full"
    ]}>
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <h3 class="font-semibold text-sm">Thread</h3>
        <button
          phx-click="close_thread"
          class="btn btn-ghost btn-sm btn-square"
        >
          <span class="hero-x-mark size-5" />
        </button>
      </div>

      <div class="px-4 py-3 border-b border-base-300 bg-base-200/50">
        <.message_bubble
          message={@parent_message}
          current_user_id={@current_user.id}
        />
      </div>

      <div class="flex-1 overflow-y-auto px-4 py-2 space-y-2">
        <div :if={@replies == []} class="text-center text-base-content/50 py-8 text-sm">
          No replies yet. Start the conversation!
        </div>
        <.message_bubble
          :for={reply <- @replies}
          message={reply}
          current_user_id={@current_user.id}
        />
      </div>

      <div class="px-4 py-3 border-t border-base-300">
        <.form
          for={@reply_form}
          phx-submit="send_reply"
          phx-target={@myself}
        >
          <div class="flex gap-2">
            <textarea
              name="reply[content]"
              value={@reply_form[:content].value}
              placeholder="Reply..."
              class="textarea textarea-bordered textarea-sm flex-1 min-h-[36px] max-h-[120px] resize-none"
              rows="1"
              phx-hook="Compose"
              id={"thread-compose-#{@parent_message.id}"}
            />
            <button type="submit" class="btn btn-primary btn-sm self-end">
              <span class="hero-paper-airplane size-4" />
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
