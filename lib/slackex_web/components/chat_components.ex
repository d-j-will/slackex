defmodule SlackexWeb.ChatComponents do
  @moduledoc """
  Reusable function components for the chat interface.

  Provides avatar, channel/DM list items, message bubbles,
  typing indicators, empty states, and unread badges.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: SlackexWeb.Endpoint,
    router: SlackexWeb.Router,
    statics: SlackexWeb.static_paths()

  # ─────────────────────────────── Avatar ──────────────────────────────────

  @doc "Renders a circular avatar with initials and optional online indicator."
  attr :user, :map, required: true
  attr :size, :string, default: "md"
  attr :online, :boolean, default: false

  def avatar(assigns) do
    size_class =
      case assigns.size do
        "sm" -> "w-6 h-6 text-xs"
        "lg" -> "w-12 h-12 text-base"
        _ -> "w-8 h-8 text-sm"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <div class="relative inline-flex flex-shrink-0">
      <div class={[
        "rounded-full bg-primary text-primary-content",
        "flex items-center justify-center font-semibold",
        @size_class
      ]}>
        {initials(@user)}
      </div>
      <span
        :if={@online}
        class="absolute bottom-0 right-0 w-2.5 h-2.5 bg-success rounded-full ring-2 ring-base-100"
      />
    </div>
    """
  end

  defp initials(%{display_name: name}) when is_binary(name) and name != "" do
    name
    |> String.split(~r/\s+/, parts: 2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp initials(%{username: username}) when is_binary(username) do
    username |> String.first() |> String.upcase()
  end

  defp initials(_), do: "?"

  # ─────────────────────────── Channel List Item ───────────────────────────

  @doc "Renders a channel item for the sidebar navigation."
  attr :channel, :map, required: true
  attr :active, :boolean, default: false
  attr :unread_count, :integer, default: 0

  def channel_list_item(assigns) do
    ~H"""
    <li>
      <.link
        patch={~p"/chat/#{@channel.slug}"}
        class={sidebar_item_classes(@active, @unread_count)}
      >
        <span class="text-base-content/50">#</span>
        <span class="truncate flex-1">{@channel.name}</span>
        <.unread_badge :if={@unread_count > 0} count={@unread_count} />
      </.link>
    </li>
    """
  end

  # ────────────────────────── DM List Item ─────────────────────────────────

  @doc "Renders a DM conversation item for the sidebar navigation."
  attr :dm, :map, required: true
  attr :active, :boolean, default: false
  attr :online, :boolean, default: false
  attr :unread_count, :integer, default: 0

  def dm_list_item(assigns) do
    other = assigns.dm.other_user

    assigns =
      assigns
      |> assign(:display, other.display_name || other.username)
      |> assign(:dm_path, "/chat/dm/#{assigns.dm.id}")

    ~H"""
    <li>
      <.link
        patch={@dm_path}
        class={sidebar_item_classes(@active, @unread_count)}
      >
        <.avatar user={@dm.other_user} size="sm" online={@online} />
        <span class="truncate flex-1">{@display}</span>
        <.unread_badge :if={@unread_count > 0} count={@unread_count} />
      </.link>
    </li>
    """
  end

  # ────────────────────────── Shared Helpers ───────────────────────────────

  defp sidebar_item_classes(active, unread_count) do
    [
      "flex items-center gap-2 px-2 py-1.5 rounded-lg text-sm transition-colors",
      "hover:bg-base-300",
      active && "bg-base-300",
      (active || unread_count > 0) && "font-semibold"
    ]
  end

  # ────────────────────────── Message Bubble ───────────────────────────────

  @doc "Renders a single message with sender avatar, name, timestamp, and content."
  attr :message, :map, required: true
  attr :current_user_id, :integer, required: true
  attr :show_hover_actions, :boolean, default: false

  def message_bubble(assigns) do
    assigns =
      assigns
      |> assign(:sender_name, sender_name(assigns.message))
      |> assign(:time, format_time(assigns.message))
      |> assign(:sender, extract_sender(assigns.message))

    ~H"""
    <div class="group flex gap-3 px-2 py-1 hover:bg-base-200/50 rounded-lg transition-colors">
      <div class="flex-shrink-0 pt-0.5">
        <.avatar user={@sender} size="md" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2">
          <span class="font-semibold text-sm">{@sender_name}</span>
          <time class="text-xs text-base-content/40">{@time}</time>
        </div>
        <p class="text-sm text-base-content/90 break-words whitespace-pre-wrap">
          {Map.get(@message, :content, "")}
        </p>
      </div>
    </div>
    """
  end

  defp extract_sender(%{sender: %{username: _} = sender}), do: sender

  defp extract_sender(%{sender: %{"username" => u} = s}),
    do: %{username: u, display_name: s["display_name"]}

  defp extract_sender(_), do: %{username: "unknown", display_name: nil}

  defp sender_name(%{sender: %{username: username}}), do: username
  defp sender_name(%{sender: %{"username" => username}}), do: username
  defp sender_name(_), do: "unknown"

  defp format_time(%{inserted_at: ts}) when not is_nil(ts), do: Calendar.strftime(ts, "%H:%M")
  defp format_time(_), do: ""

  # ────────────────────────── Typing Indicator ─────────────────────────────

  @doc "Renders a typing indicator bar when users are typing."
  attr :users, :list, default: []

  def typing_indicator(assigns) do
    assigns = assign(assigns, :text, typing_text(assigns.users))

    ~H"""
    <div :if={@text} class="px-4 py-1 text-xs text-base-content/50 italic">
      {@text}
    </div>
    """
  end

  defp typing_text([]), do: nil
  defp typing_text([name]), do: "#{name} is typing..."
  defp typing_text([a, b]), do: "#{a} and #{b} are typing..."
  defp typing_text(_), do: "Several people are typing..."

  # ────────────────────────── Sidebar Toggle ───────────────────────────────

  @doc "Renders a hamburger menu button for toggling the sidebar on mobile."
  attr :class, :string, default: nil

  def sidebar_toggle(assigns) do
    ~H"""
    <button
      class={["md:hidden btn btn-ghost btn-sm btn-square", @class]}
      phx-click="toggle_sidebar"
      aria-label="Toggle sidebar"
    >
      <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M4 6h16M4 12h16M4 18h16"
        />
      </svg>
    </button>
    """
  end

  # ────────────────────────── Conversation Header ────────────────────────

  @doc "Renders the header bar for a channel or DM conversation."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  slot :actions

  def conversation_header(assigns) do
    ~H"""
    <div class="px-4 py-3 border-b border-base-300 bg-base-100 flex items-center gap-3">
      <.sidebar_toggle />
      <div class="flex-1 min-w-0">
        <h2 class="font-bold text-lg truncate">{@title}</h2>
        <p :if={@subtitle} class="text-xs text-base-content/60 truncate">
          {@subtitle}
        </p>
      </div>
      {render_slot(@actions)}
    </div>
    """
  end

  # ────────────────────────── Message Stream ─────────────────────────────

  @doc "Renders the scrollable message list with stream updates."
  attr :streams, :any, required: true
  attr :current_user_id, :integer, required: true

  def message_stream(assigns) do
    ~H"""
    <div
      id="message-list"
      phx-hook="MessageList"
      phx-update="stream"
      class="flex-1 overflow-y-auto px-2 py-4"
    >
      <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
        <.message_bubble message={message} current_user_id={@current_user_id} />
      </div>
    </div>
    """
  end

  # ────────────────────────── Compose Area ───────────────────────────────

  @doc "Renders the message compose form with textarea and send button."
  attr :message_form, :any, required: true
  attr :placeholder, :string, required: true

  def compose_area(assigns) do
    ~H"""
    <div class="p-3 border-t border-base-300 bg-base-100">
      <.form
        for={@message_form}
        id="message-form"
        phx-submit="send_message"
        phx-hook="Compose"
        class="flex gap-2 items-end"
      >
        <textarea
          name="message[content]"
          placeholder={@placeholder}
          class="textarea textarea-bordered flex-1 min-h-[2.5rem] max-h-[200px] resize-none leading-normal py-2"
          rows="1"
          autocomplete="off"
          phx-debounce="100"
        >{@message_form[:content].value}</textarea>
        <button type="submit" class="btn btn-primary btn-sm">Send</button>
      </.form>
    </div>
    """
  end

  # ────────────────────────── Empty State ──────────────────────────────────

  @doc "Renders a centered empty-state placeholder."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center text-base-content/50">
      <div class="text-center space-y-2">
        <div :if={@icon} class="text-4xl mb-4">{@icon}</div>
        <h2 class="text-2xl font-bold">{@title}</h2>
        <p :if={@subtitle} class="text-sm">{@subtitle}</p>
      </div>
    </div>
    """
  end

  # ────────────────────────── Report Modal ─────────────────────────────────

  @doc "Renders a modal for reporting a user with category selection and description."
  attr :show, :boolean, default: false
  attr :report_form, :any, required: true

  def report_modal(assigns) do
    ~H"""
    <div :if={@show} id="report-modal" phx-window-keydown="close_report_modal" phx-key="Escape">
      <div class="fixed inset-0 z-40 bg-black/50" phx-click="close_report_modal" />
      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full max-w-md">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-bold text-lg">Report User</h3>
            <button
              type="button"
              phx-click="close_report_modal"
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-5" />
            </button>
          </div>
          <.form for={@report_form} id="report-form" phx-submit="submit_report" class="p-4 space-y-4">
            <div class="space-y-2">
              <label class="font-medium text-sm">Category</label>
              <div class="space-y-1">
                <label
                  :for={cat <- ~w(spam harassment inappropriate_content phishing other)}
                  class="flex items-center gap-2 cursor-pointer"
                >
                  <input
                    type="radio"
                    name="report[category]"
                    value={cat}
                    class="radio radio-sm radio-primary"
                    required
                  />
                  <span class="text-sm">{category_label(cat)}</span>
                </label>
              </div>
            </div>
            <div>
              <label class="font-medium text-sm" for="report-description">
                Description (optional)
              </label>
              <textarea
                name="report[description]"
                id="report-description"
                class="textarea textarea-bordered w-full mt-1"
                rows="3"
                placeholder="Provide additional details..."
              />
            </div>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="close_report_modal" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-error btn-sm">Submit Report</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp category_label("spam"), do: "Spam"
  defp category_label("harassment"), do: "Harassment"
  defp category_label("inappropriate_content"), do: "Inappropriate Content"
  defp category_label("phishing"), do: "Phishing"
  defp category_label("other"), do: "Other"

  # ────────────────────────── Unread Badge ─────────────────────────────────

  @doc "Renders a small badge with an unread message count."
  attr :count, :integer, default: 0

  def unread_badge(assigns) do
    ~H"""
    <span :if={@count > 0} class="badge badge-primary badge-sm min-w-5 h-5">
      {if @count > 99, do: "99+", else: @count}
    </span>
    """
  end
end
