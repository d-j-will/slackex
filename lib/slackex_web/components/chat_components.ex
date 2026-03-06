defmodule SlackexWeb.ChatComponents do
  @moduledoc """
  Reusable function components for the chat interface.

  Provides avatar, channel/DM list items, message bubbles,
  typing indicators, empty states, and unread badges.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Slackex.Links.URLExtractor

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
    assigns =
      assigns
      |> assign(:display, display_name(assigns.dm.other_user))
      |> assign(:dm_path, "/chat/dm/#{assigns.dm.id}")

    ~H"""
    <li>
      <.link
        patch={@dm_path}
        class={sidebar_item_classes(@active, @unread_count)}
      >
        <span
          data-profile-user-id={@dm.other_user.id}
          phx-click="show_profile"
          phx-value-user-id={@dm.other_user.id}
          class="cursor-pointer"
        >
          <.avatar user={@dm.other_user} size="sm" online={@online} />
        </span>
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
  attr :in_dm, :boolean, default: false
  attr :editing_message_id, :integer, default: nil
  attr :current_user_role, :string, default: nil
  attr :reactions, :list, default: []
  attr :reactions_enabled, :boolean, default: false
  attr :threads_enabled, :boolean, default: false
  attr :channel_management_enabled, :boolean, default: false
  attr :link_previews, :list, default: []
  attr :link_previews_enabled, :boolean, default: false

  def message_bubble(assigns) do
    message = assigns.message
    is_own = own_message?(message, assigns.current_user_id)
    can_admin_delete = assigns.current_user_role in ["owner", "admin"]

    assigns =
      assigns
      |> assign(:sender_name, sender_name(message))
      |> assign(:time, format_time(message))
      |> assign(:sender, extract_sender(message))
      |> assign(:show_report_action, show_report_action?(assigns))
      |> assign(:is_deleted, message_deleted?(message))
      |> assign(:is_edited, message_edited?(message))
      |> assign(:is_own_message, is_own)
      |> assign(:can_delete, is_own or can_admin_delete)
      |> assign(:can_pin, can_admin_delete)
      |> assign(:is_editing, Map.get(message, :editing, false) == true)
      |> assign(
        :rendered_content,
        if assigns.link_previews_enabled do
          URLExtractor.linkify(Map.get(message, :content, ""))
        else
          Map.get(message, :content, "")
        end
      )

    ~H"""
    <div class="group relative flex gap-3 px-2 py-1 hover:bg-base-200/50 rounded-lg transition-colors">
      <div class="flex-shrink-0 pt-0.5">
        <.avatar user={@sender} size="md" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2">
          <span class="font-semibold text-sm">{@sender_name}</span>
          <time class="text-xs text-base-content/40">{@time}</time>
        </div>
        <%= if @is_deleted do %>
          <p class="text-sm text-base-content/40 italic">[This message has been deleted]</p>
        <% else %>
          <%= if @is_editing do %>
            <div class="mt-1">
              <textarea
                id={"edit-input-#{@message.id}"}
                class="textarea textarea-bordered textarea-sm w-full"
                maxlength="4000"
                phx-hook="EditMessage"
              >{Map.get(@message, :content, "")}</textarea>
              <div class="flex gap-2 mt-1">
                <button
                  phx-click="save_edit"
                  phx-value-msg-id={@message.id}
                  class="btn btn-primary btn-xs"
                  id={"save-edit-#{@message.id}"}
                >
                  Save
                </button>
                <button
                  phx-click="cancel_edit"
                  class="btn btn-ghost btn-xs"
                >
                  Cancel
                </button>
              </div>
            </div>
          <% else %>
            <p class="text-sm text-base-content/90 break-words whitespace-pre-wrap">
              {@rendered_content}<span :if={@is_edited} class="text-xs text-base-content/40 ml-1">(edited)</span>
            </p>
            <div :if={@link_previews_enabled and @link_previews != []} class="mt-1 space-y-2">
              <.link_preview_card :for={preview <- @link_previews} preview={preview} />
            </div>
          <% end %>
        <% end %>
        <.reaction_bar
          :if={@reactions_enabled}
          reactions={@reactions}
          current_user_id={@current_user_id}
          message_id={@message.id}
        />
        <button
          :if={
            @threads_enabled and Map.get(@message, :reply_count, 0) > 0 and
              is_nil(Map.get(@message, :parent_message_id))
          }
          phx-click="open_thread"
          phx-value-message-id={@message.id}
          class="text-xs text-primary hover:underline cursor-pointer mt-1"
        >
          {Map.get(@message, :reply_count)} {if Map.get(@message, :reply_count) == 1,
            do: "reply",
            else: "replies"}
        </button>
      </div>
      <div
        :if={not @is_deleted and not @is_editing}
        class="hidden group-hover:flex absolute right-2 top-1 items-center gap-1"
        data-role="message-actions"
      >
        <div
          :if={@reactions_enabled}
          id={"emoji-picker-#{@message.id}"}
          phx-hook="EmojiPicker"
          class="relative"
        >
          <button
            data-emoji-trigger
            data-message-id={@message.id}
            phx-click={JS.dispatch("emoji:open", to: "#emoji-picker-#{@message.id}")}
            class="btn btn-ghost btn-xs btn-circle"
            title="Add reaction"
          >
            <span class="hero-face-smile size-4" />
          </button>
        </div>
        <button
          :if={@threads_enabled and is_nil(Map.get(@message, :parent_message_id))}
          phx-click="open_thread"
          phx-value-message-id={@message.id}
          class="btn btn-ghost btn-xs btn-circle"
          title="Reply in thread"
        >
          <span class="hero-chat-bubble-left size-4" />
        </button>
        <button
          :if={
            @channel_management_enabled and @can_pin and
              is_nil(Map.get(@message, :parent_message_id))
          }
          phx-click="pin_message"
          phx-value-message-id={@message.id}
          class="btn btn-ghost btn-xs btn-circle"
          title="Pin message"
        >
          <span class="hero-bookmark size-4" />
        </button>
        <button
          :if={@is_own_message}
          phx-click="edit_message"
          phx-value-msg-id={@message.id}
          class="btn btn-ghost btn-xs"
          title="Edit message"
        >
          Edit
        </button>
        <button
          :if={@can_delete}
          phx-click="delete_message"
          phx-value-msg-id={@message.id}
          data-confirm="Are you sure you want to delete this message?"
          class="btn btn-ghost btn-xs text-error"
          title="Delete message"
        >
          Delete
        </button>
        <button
          :if={@show_report_action and not @can_delete}
          phx-click="report_message"
          phx-value-message-id={@message.id}
          class="btn btn-ghost btn-xs text-warning"
          title="Report message"
        >
          Report
        </button>
      </div>
    </div>
    """
  end

  # ────────────────────────── Reaction Bar ──────────────────────────────

  attr :reactions, :list, default: []
  attr :current_user_id, :integer, required: true
  attr :message_id, :integer, required: true

  def reaction_bar(assigns) do
    ~H"""
    <div :if={@reactions != []} class="flex flex-wrap gap-1 mt-1">
      <button
        :for={reaction <- @reactions}
        phx-click="toggle_reaction"
        phx-value-message-id={@message_id}
        phx-value-emoji={reaction.emoji}
        class={[
          "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs border",
          "hover:bg-base-300 transition-colors cursor-pointer",
          if(@current_user_id in reaction.user_ids,
            do: "border-primary bg-primary/10 text-primary",
            else: "border-base-300 bg-base-200 text-base-content"
          )
        ]}
      >
        <span>{reaction.emoji}</span>
        <span class="font-medium">{reaction.count}</span>
      </button>
    </div>
    """
  end

  defp message_deleted?(message), do: Map.get(message, :deleted_at) != nil
  defp message_edited?(message), do: Map.get(message, :edited_at) != nil

  defp own_message?(message, current_user_id) do
    Map.get(message, :sender_id) == current_user_id
  end

  defp show_report_action?(%{in_dm: true, message: message, current_user_id: current_user_id}) do
    sender_id = Map.get(message, :sender_id)
    sender_id != nil and sender_id != current_user_id
  end

  defp show_report_action?(_assigns), do: false

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
  attr :in_dm, :boolean, default: false
  attr :editing_message_id, :integer, default: nil
  attr :current_user_role, :string, default: nil
  attr :reactions, :map, default: %{}
  attr :reactions_enabled, :boolean, default: false
  attr :threads_enabled, :boolean, default: false
  attr :channel_management_enabled, :boolean, default: false
  attr :link_previews, :map, default: %{}
  attr :link_previews_enabled, :boolean, default: false

  def message_stream(assigns) do
    ~H"""
    <div
      id="message-list"
      phx-hook="MessageList"
      phx-update="stream"
      class="flex-1 overflow-y-auto px-2 py-4"
    >
      <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
        <.message_bubble
          message={message}
          current_user_id={@current_user_id}
          in_dm={@in_dm}
          editing_message_id={@editing_message_id}
          current_user_role={@current_user_role}
          reactions={Map.get(@reactions, message.id, [])}
          reactions_enabled={@reactions_enabled}
          threads_enabled={@threads_enabled}
          channel_management_enabled={@channel_management_enabled}
          link_previews={Map.get(@link_previews, message.id, [])}
          link_previews_enabled={@link_previews_enabled}
        />
      </div>
    </div>
    """
  end

  # ────────────────────────── Link Preview Card ─────────────────────────

  @doc "Renders an inline link preview card with OG metadata."
  attr :preview, :map, required: true

  def link_preview_card(assigns) do
    ~H"""
    <a
      href={@preview.url}
      target="_blank"
      rel="noopener noreferrer ugc"
      class="block max-w-md rounded-lg border border-base-300 bg-base-100 hover:bg-base-200 transition-colors overflow-hidden"
    >
      <img
        :if={@preview.image_url}
        src={@preview.image_url}
        alt=""
        class="w-full h-32 object-cover"
        loading="lazy"
      />
      <div class="p-3">
        <div :if={@preview.site_name} class="text-xs text-base-content/50 mb-1">
          <img
            :if={@preview.favicon_url}
            src={@preview.favicon_url}
            alt=""
            class="inline-block w-4 h-4 mr-1 align-text-bottom"
            loading="lazy"
          />
          {@preview.site_name}
        </div>
        <div :if={@preview.title} class="text-sm font-semibold text-primary line-clamp-2">
          {@preview.title}
        </div>
        <div :if={@preview.description} class="text-xs text-base-content/70 mt-1 line-clamp-2">
          {@preview.description}
        </div>
      </div>
    </a>
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
  attr :report_message_id, :integer, default: nil

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
            <input
              :if={@report_message_id}
              type="hidden"
              name="report[message_id]"
              value={@report_message_id}
            />
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

  # ────────────────────────── User Profile Card ───────────────────────────

  @doc "Renders a profile card modal for a user, showing name, username, status, and online indicator."
  attr :user, :map, default: nil
  attr :online, :boolean, default: false
  attr :show_send_message, :boolean, default: true

  def user_profile_card(assigns) do
    display = display_name(assigns.user)
    assigns = assign(assigns, :display, display)

    ~H"""
    <div
      :if={@user}
      id="user-profile-card"
      phx-window-keydown="close_profile"
      phx-key="Escape"
    >
      <div id="profile-backdrop" class="fixed inset-0 z-40 bg-black/50" phx-click="close_profile" />
      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full max-w-sm p-6 relative">
          <button
            type="button"
            phx-click="close_profile"
            class="btn btn-ghost btn-sm btn-square absolute top-2 right-2"
            aria-label="Close"
          >
            <span class="hero-x-mark size-5" />
          </button>
          <div class="flex flex-col items-center text-center space-y-3">
            <.avatar user={@user} size="lg" online={@online} />
            <div>
              <h3 class="font-bold text-lg">{@display}</h3>
              <p class="text-sm text-base-content/60">@{@user.username}</p>
            </div>
            <p :if={@user.status && @user.status != ""} class="text-sm text-base-content/70">
              {@user.status}
            </p>
            <span class={[
              "badge badge-sm",
              @online && "badge-success",
              !@online && "badge-ghost"
            ]}>
              {if @online, do: "Online", else: "Offline"}
            </span>
            <button
              :if={@show_send_message}
              phx-click="send_message_to_profile_user"
              class="btn btn-primary btn-sm w-full mt-2"
            >
              Send Message
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp display_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{username: username}), do: username
  defp display_name(_), do: "Unknown"

  # ────────────────────────── Edit Profile Modal ────────────────────────────

  @doc "Renders a modal for editing the current user's profile (display_name and status)."
  attr :show, :boolean, default: false
  attr :form, :any, required: true
  attr :current_user, :map, required: true

  def edit_profile_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id="edit-profile-modal"
      phx-window-keydown="close_edit_profile"
      phx-key="Escape"
    >
      <div
        id="edit-profile-backdrop"
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_edit_profile"
      />
      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full max-w-md">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-bold text-lg">Edit Profile</h3>
            <button
              type="button"
              phx-click="close_edit_profile"
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-5" />
            </button>
          </div>
          <.form
            for={@form}
            id="edit-profile-form"
            phx-submit="save_profile"
            phx-change="validate_profile"
            class="p-4 space-y-4"
          >
            <div>
              <label class="font-medium text-sm" for="profile-display-name">Display Name</label>
              <input
                type="text"
                name="profile[display_name]"
                id="profile-display-name"
                value={@form[:display_name].value}
                class="input input-bordered w-full mt-1"
                maxlength="50"
                placeholder={@current_user.username}
              />
              <.field_error :for={msg <- Enum.map(@form[:display_name].errors, &translate_error/1)}>
                {msg}
              </.field_error>
            </div>
            <div>
              <label class="font-medium text-sm" for="profile-status">Status</label>
              <input
                type="text"
                name="profile[status]"
                id="profile-status"
                value={@form[:status].value}
                class="input input-bordered w-full mt-1"
                maxlength="100"
                placeholder="What's on your mind?"
              />
              <.field_error :for={msg <- Enum.map(@form[:status].errors, &translate_error/1)}>
                {msg}
              </.field_error>
            </div>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="close_edit_profile" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp field_error(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-error">{render_slot(@inner_block)}</p>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

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
