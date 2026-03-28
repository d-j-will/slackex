defmodule SlackexWeb.ChatLive.Helpers do
  @moduledoc """
  Pure helper functions extracted from ChatLive.Index.

  Parsing, message stream updates, profile refresh, error messages,
  and other small functions that don't manage conversation state.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, stream_insert: 3]

  alias Slackex.Accounts
  alias Slackex.Accounts.User
  alias Slackex.Chat
  alias Slackex.Messaging
  alias Slackex.Messaging.Envelope

  # -- Parsing ----------------------------------------------------------------

  def extract_message_id(%{"msg-id" => id}, _fallback), do: safe_to_integer(id)
  def extract_message_id(_params, fallback), do: fallback

  def parse_message_id(nil), do: nil
  def parse_message_id(""), do: nil
  def parse_message_id(id) when is_binary(id), do: safe_to_integer(id)

  def safe_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def safe_to_integer(value) when is_integer(value), do: value
  def safe_to_integer(_), do: nil

  def to_integer(value) when is_integer(value), do: value

  def to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  def to_integer(_), do: nil

  def parse_target_param(%{"target" => target}) when is_binary(target) do
    case Integer.parse(target) do
      {id, ""} -> id
      _ -> nil
    end
  end

  def parse_target_param(_params), do: nil

  # -- DM helpers -------------------------------------------------------------

  def dm_other_user_id(dm, current_user_id) do
    if dm.user_a_id == current_user_id, do: dm.user_b_id, else: dm.user_a_id
  end

  def dm_other_user(dm, current_user_id) do
    Accounts.get_user!(dm_other_user_id(dm, current_user_id))
  end

  # -- Socket helpers ---------------------------------------------------------

  def remove_request(requests, request_id) do
    Enum.reject(requests, &(&1.id == request_id))
  end

  def build_profile_form(user) do
    changeset = User.profile_changeset(user, %{})
    to_form(changeset, as: :profile)
  end

  def short_node_name do
    node()
    |> Atom.to_string()
    |> String.split("@")
    |> List.last()
  end

  def dismiss_report_modal(socket) do
    socket
    |> assign(:show_report_modal, false)
    |> assign(:report_message_id, nil)
  end

  def maybe_push_scroll_event(socket, nil), do: socket

  def maybe_push_scroll_event(socket, target_message_id) do
    push_event(socket, "scroll_to_message", %{id: "messages-#{target_message_id}"})
  end

  # -- Messaging --------------------------------------------------------------

  def broadcast_typing(user, {scope, id}) do
    {topic, target} =
      case scope do
        :dm -> {"dm:#{id}", {:dm, id}}
        :channel -> {"channel:#{id}", {:channel, id}}
      end

    envelope = Envelope.wrap("typing", target, %{user_id: user.id, username: user.username})
    Phoenix.PubSub.broadcast(Slackex.PubSub, topic, {:envelope, envelope})
  end

  def send_message_to_channel(channel, user, content, socket) do
    Messaging.send_message(channel.id, user.id, content)
    |> handle_send_result(socket)
  end

  def send_message_to_dm(dm, user, content, socket) do
    Messaging.send_dm(dm.id, user.id, content)
    |> handle_send_result(socket)
  end

  def handle_send_result({:ok, _message}, socket) do
    {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}
  end

  def handle_send_result({:error, :rate_limited}, socket) do
    {:noreply, put_flash(socket, :error, "You're sending messages too fast. Please slow down.")}
  end

  def handle_send_result({:error, :backpressure}, socket) do
    {:noreply, put_flash(socket, :error, "Server is busy. Please try again in a moment.")}
  end

  def handle_send_result({:error, :invalid_content}, socket) do
    {:noreply,
     put_flash(socket, :error, "Message content is invalid (must be 1-4000 characters).")}
  end

  def handle_send_result({:error, _reason}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to send message.")}
  end

  # -- Message enrichment & stream updates ------------------------------------

  def enrich_message(%{sender: %{username: _}} = message), do: message

  def enrich_message(%{sender_id: sender_id} = message) when is_integer(sender_id) do
    sender = Accounts.get_user!(sender_id)
    Map.put(message, :sender, sender)
  end

  def enrich_message(message), do: message

  def maybe_mark_as_read(socket, message) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user
    channel_id = Map.get(message, :channel_id)

    if channel && channel_id == channel.id do
      Chat.mark_as_read(user.id, channel.id)
    end

    socket
  end

  def message_for_active_conversation?(%{target: %{type: :channel, id: id}}, socket) do
    socket.assigns.active_channel != nil and socket.assigns.active_channel.id == id
  end

  def message_for_active_conversation?(%{target: %{type: :dm, id: id}}, socket) do
    socket.assigns.active_dm != nil and socket.assigns.active_dm.id == id
  end

  def message_for_active_conversation?(_envelope, _socket), do: false

  def restore_message_after_edit(socket, nil), do: socket

  def restore_message_after_edit(socket, message_id) do
    case Chat.get_message(message_id) do
      {:ok, message} ->
        message = Slackex.Repo.preload(message, :sender)
        stream_insert(socket, :messages, Map.put(message, :editing, false))

      _ ->
        socket
    end
  end

  def apply_reaction_update(reactions, %{action: :added, emoji: emoji, user_id: user_id}) do
    case Enum.find_index(reactions, &(&1.emoji == emoji)) do
      nil ->
        [%{emoji: emoji, count: 1, user_ids: [user_id]} | reactions]

      idx ->
        List.update_at(reactions, idx, &add_user_to_reaction(&1, user_id))
    end
  end

  def apply_reaction_update(reactions, %{action: :removed, emoji: emoji, user_id: user_id}) do
    reactions
    |> Enum.map(fn r ->
      if r.emoji == emoji and user_id in r.user_ids do
        %{r | count: r.count - 1, user_ids: List.delete(r.user_ids, user_id)}
      else
        r
      end
    end)
    |> Enum.reject(&(&1.count <= 0))
  end

  defp add_user_to_reaction(%{user_ids: user_ids} = reaction, user_id) do
    if user_id in user_ids,
      do: reaction,
      else: %{reaction | count: reaction.count + 1, user_ids: [user_id | user_ids]}
  end

  def apply_edit_to_stream(%{id: id, content: content, edited_at: edited_at}) do
    apply_update_to_stream(id, %{content: content, edited_at: edited_at})
  end

  def apply_delete_to_stream(%{id: id, deleted_at: deleted_at}) do
    apply_update_to_stream(id, %{content: nil, deleted_at: deleted_at})
  end

  def apply_update_to_stream(message_id, updates) do
    case Chat.get_message(message_id) do
      {:ok, message} ->
        message
        |> Slackex.Repo.preload(:sender)
        |> Map.merge(updates)

      {:error, _} ->
        Map.merge(%{id: message_id, sender: %{username: "unknown"}}, updates)
    end
  end

  # -- Profile refresh --------------------------------------------------------

  def maybe_refresh_profile_card(socket, updated_user) do
    case socket.assigns.profile_user do
      %{id: id} when id == updated_user.id ->
        assign(socket, :profile_user, updated_user)

      _ ->
        socket
    end
  end

  def maybe_refresh_current_user(socket, updated_user) do
    if socket.assigns.current_user.id == updated_user.id do
      assign(socket, :current_user, updated_user)
    else
      socket
    end
  end

  def refresh_dm_conversations_for_profile(socket, updated_user) do
    dm_conversations = socket.assigns.dm_conversations

    if Enum.any?(dm_conversations, fn dm -> dm.other_user.id == updated_user.id end) do
      updated_dms = replace_other_user_in_dms(dm_conversations, updated_user)
      assign(socket, :dm_conversations, updated_dms)
    else
      socket
    end
  end

  defp replace_other_user_in_dms(dm_conversations, updated_user) do
    Enum.map(dm_conversations, fn dm ->
      if dm.other_user.id == updated_user.id, do: %{dm | other_user: updated_user}, else: dm
    end)
  end

  # -- Authorization ----------------------------------------------------------

  def authorize_channel(user_id, channel) do
    role = Chat.get_role(user_id, channel.id)

    cond do
      role != nil ->
        {:ok, Chat.Permissions.can?(role, :send_message), role}

      not channel.is_private ->
        {:ok, false, nil}

      true ->
        {:error, :unauthorized}
    end
  end

  # -- Unread counts ----------------------------------------------------------

  def increment_unread_count(socket, %{target: %{type: :channel, id: channel_id}}) do
    update_unread_count(socket, :channel_counts, channel_id, &(&1 + 1))
  end

  def increment_unread_count(socket, %{target: %{type: :dm, id: dm_id}}) do
    update_unread_count(socket, :dm_counts, dm_id, &(&1 + 1))
  end

  def increment_unread_count(socket, _envelope), do: socket

  def reset_unread_count(socket, count_key, conversation_id) do
    update_unread_count(socket, count_key, conversation_id, fn _current -> 0 end)
  end

  def update_unread_count(socket, count_key, conversation_id, update_fn) do
    unread_counts = socket.assigns.unread_counts
    counts_map = Map.fetch!(unread_counts, count_key)
    current = Map.get(counts_map, conversation_id, 0)
    updated_counts = Map.put(counts_map, conversation_id, update_fn.(current))
    updated_unread = Map.put(unread_counts, count_key, updated_counts)
    assign(socket, :unread_counts, updated_unread)
  end

  # -- Error messages ---------------------------------------------------------

  def dm_request_error_message(:account_too_new),
    do: "Your account must be at least 24 hours old to send DM requests."

  def dm_request_error_message(:no_shared_channels),
    do: "You need to share a channel with this user before sending a DM request."

  def dm_request_error_message(:blocked),
    do: "Unable to send a DM request to this user."

  def dm_request_error_message(:dm_restricted),
    do: "Your DM privileges have been restricted."

  def dm_request_error_message(:cooldown_active),
    do: "Please wait before sending another request to this user."

  def dm_request_error_message(:rate_limited),
    do: "You're sending too many DM requests. Please try again later."

  def dm_request_error_message(:too_many_pending),
    do: "You have too many pending DM requests. Wait for some to be accepted or declined."

  def dm_request_error_message(:dm_preference_rejected),
    do: "This user is not accepting DM requests."

  def dm_request_error_message(_),
    do: "Could not send DM request."
end
