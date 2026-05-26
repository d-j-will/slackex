defmodule SlackexWeb.ChatLive.ThreadPanelComponent do
  use SlackexWeb, :live_component

  alias Slackex.Chat
  alias Slackex.Chat.MessageGrouping

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
    replies =
      assigns.parent_message.id
      |> Chat.list_thread()
      |> MessageGrouping.annotate()

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

  attr :loom, :boolean, default: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class={[
      "flex flex-col border-l border-base-300 bg-base-100 thread-panel",
      "w-full md:w-[400px] h-full"
    ]}>
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <h3 class="font-semibold text-sm thread-title">Thread</h3>
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
          markdown_enabled={assigns[:markdown_enabled] || false}
          id_prefix="thread-"
        />
      </div>

      <svg
        :if={@loom}
        class="loom-weft"
        viewBox="0 0 200 20"
        preserveAspectRatio="none"
        width="100%"
        height="14"
        aria-hidden="true"
      >
        <line
          :for={i <- 0..4}
          x1="0"
          x2="200"
          y1={(i + 0.5) * 4}
          y2={(i + 0.5) * 4}
          stroke-width="1.3"
          stroke-dasharray="2 4"
          opacity="0.5"
        />
      </svg>

      <div class="flex-1 overflow-y-auto px-4 py-2 space-y-2">
        <div :if={@replies == []} class="text-center text-base-content/50 py-8 text-sm">
          No replies yet. Start the conversation!
        </div>
        <div :for={reply <- @replies}>
          <.time_divider
            :if={Map.get(reply, :show_divider, false)}
            label={Map.get(reply, :divider_label) || ""}
          />
          <.message_bubble
            message={reply}
            current_user_id={@current_user.id}
            grouped={Map.get(reply, :grouped, false)}
            markdown_enabled={assigns[:markdown_enabled] || false}
          />
        </div>
      </div>

      <div class="px-4 py-3 border-t border-base-300">
        <.form
          for={@reply_form}
          phx-submit="send_reply"
          phx-target={@myself}
        >
          <div class="flex gap-2 items-end">
            <textarea
              name="reply[content]"
              value={@reply_form[:content].value}
              placeholder="Reply..."
              class="textarea textarea-bordered textarea-sm flex-1 min-h-[36px] max-h-[120px] resize-none"
              rows="1"
              phx-hook="Compose"
              id={"thread-compose-#{@parent_message.id}"}
            />
            <button type="submit" class="btn btn-primary btn-sm h-[36px]">
              <span class="hero-paper-airplane size-4" />
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
