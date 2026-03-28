defmodule SlackexWeb.ChatLive.Index do
  use SlackexWeb, :live_view

  alias Slackex.Accounts
  alias Slackex.Accounts.User
  alias Slackex.AI.Summarizer
  alias Slackex.Chat
  alias Slackex.Chat.Permissions
  alias Slackex.Links
  alias Slackex.Messaging
  alias Slackex.Messaging.Envelope
  alias Slackex.Notifications.OnlineTracker
  alias Slackex.Search
  alias Slackex.Search.HistoryLoader
  alias SlackexWeb.ChatLive.BrowseChannelsModal
  alias SlackexWeb.ChatLive.ChannelMembersModal
  alias SlackexWeb.ChatLive.CreateChannelModal
  alias SlackexWeb.ChatLive.InviteLinkModal
  alias SlackexWeb.ChatLive.NewDmModal
  alias SlackexWeb.ChatLive.PinnedMessagesModal
  alias SlackexWeb.ChatLive.QuickSwitcherModal
  alias SlackexWeb.ChatLive.SearchComponent
  alias SlackexWeb.ChatLive.SidebarComponent
  alias SlackexWeb.ChatLive.SlashCommand
  alias SlackexWeb.ChatLive.SummaryModal
  alias SlackexWeb.ChatLive.ThreadPanelComponent

  import SlackexWeb.ChatComponents

  @message_page_size 50
  @heartbeat_interval_ms 60_000
  @typing_timeout_ms 3_000
  @presence_topic "presence:online"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    channels = Chat.list_user_channels(user.id)
    dm_conversations = Chat.list_user_dm_conversations(user.id)
    dm_requests = Chat.list_pending_requests_for_user(user.id)

    _ =
      if connected?(socket) do
        _ = Messaging.subscribe_user(user.id)
        subscribe_all_conversations(channels, dm_conversations)
        _ = Phoenix.PubSub.subscribe(Slackex.PubSub, @presence_topic)
        _ = Phoenix.PubSub.subscribe(Slackex.PubSub, "profile:updates")
        OnlineTracker.mark_online(user.id)

        _ =
          Phoenix.PubSub.broadcast(Slackex.PubSub, @presence_topic, {:presence, :online, user.id})

        Process.send_after(self(), :online_heartbeat, @heartbeat_interval_ms)
      end

    unread_counts = Chat.batch_unread_counts(user.id)

    online_user_ids =
      if connected?(socket) do
        dm_conversations
        |> Enum.map(& &1.other_user.id)
        |> OnlineTracker.online_user_ids()
      else
        MapSet.new()
      end

    {:ok,
     socket
     |> assign(:channels, channels)
     |> assign(:dm_conversations, dm_conversations)
     |> assign(:dm_requests, dm_requests)
     |> assign(:dm_request_count, length(dm_requests))
     |> assign(:unread_counts, unread_counts)
     |> assign(:online_user_ids, online_user_ids)
     |> assign(:active_channel, nil)
     |> assign(:active_dm, nil)
     |> assign(:can_send, false)
     |> assign(:user_role, nil)
     |> assign(:typing_users, MapSet.new())
     |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
     |> assign(:sidebar_open, true)
     |> assign(:oldest_message_id, nil)
     |> assign(:has_more_messages, false)
     |> assign(:show_report_modal, false)
     |> assign(:report_message_id, nil)
     |> assign(:report_form, to_form(%{}, as: :report))
     |> assign(:profile_user, nil)
     |> assign(:show_edit_profile, false)
     |> assign(:edit_profile_form, build_profile_form(user))
     |> assign(:editing_message_id, nil)
     |> assign(:reactions, %{})
     |> assign(:thread_parent, nil)
     |> assign(:member_count, 0)
     |> assign(:pin_count, 0)
     |> assign(:show_quick_switcher, false)
     |> assign(:show_node, FunWithFlags.enabled?(:show_cluster_node, for: user))
     |> assign(:node_name, short_node_name())
     |> assign(:search_open, false)
     |> assign(:search_enabled, FunWithFlags.enabled?(:message_search))
     |> assign(:summarization_enabled, FunWithFlags.enabled?(:channel_summarization))
     |> assign(:reactions_enabled, FunWithFlags.enabled?(:reactions))
     |> assign(:threads_enabled, FunWithFlags.enabled?(:threads))
     |> assign(:channel_management_enabled, FunWithFlags.enabled?(:channel_management))
     |> assign(:quick_switcher_enabled, FunWithFlags.enabled?(:quick_switcher))
     |> assign(:link_previews_enabled, FunWithFlags.enabled?(:link_previews))
     |> assign(:markdown_enabled, FunWithFlags.enabled?(:markdown_rendering))
     |> assign(:link_previews, %{})
     |> assign(:show_summary_modal, false)
     |> assign(:summary_text, "")
     |> assign(:summary_state, :idle)
     |> assign(:summary_error, nil)
     |> assign(:active_summary_task, nil)
     |> assign(:last_message, nil)
     |> stream(:messages, [])}
  end

  # ---------------------------------------------------------------------------
  # Handle params
  # ---------------------------------------------------------------------------

  @impl true
  def handle_params(%{"dm_id" => dm_id} = params, _uri, socket) do
    user = socket.assigns.current_user
    dm = Chat.get_dm_conversation!(dm_id)

    if user.id in [dm.user_a_id, dm.user_b_id] do
      target_message_id = parse_target_param(params)

      socket =
        socket
        |> enter_dm(dm, target_message_id)
        |> maybe_push_scroll_event(target_message_id)

      {:noreply, socket}
    else
      {:noreply, socket |> put_flash(:error, "Not found.") |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(
        %{"slug" => slug, "message_id" => message_id},
        _uri,
        %{assigns: %{live_action: :thread}} = socket
      ) do
    user = socket.assigns.current_user
    channel = Chat.get_channel_by_slug!(slug)

    case authorize_channel(user.id, channel) do
      {:ok, can_send, role} ->
        parent =
          Chat.get_message!(String.to_integer(message_id))
          |> Slackex.Repo.preload(:sender)

        _ =
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Slackex.PubSub, "thread:#{parent.id}")
          end

        socket =
          if socket.assigns.active_channel == nil ||
               socket.assigns.active_channel.id != channel.id do
            enter_channel(socket, channel, can_send, role, nil)
          else
            socket
          end

        {:noreply, assign(socket, :thread_parent, parent)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have access to that channel.")
         |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _uri, socket) do
    user = socket.assigns.current_user
    channel = Chat.get_channel_by_slug!(slug)

    case authorize_channel(user.id, channel) do
      {:ok, can_send, role} ->
        target_message_id = parse_target_param(params)

        socket =
          socket
          |> enter_channel(channel, can_send, role, target_message_id)
          |> maybe_push_scroll_event(target_message_id)

        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have access to that channel.")
         |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :create_channel}} = socket) do
    {:noreply, enter_modal(socket, "Create Channel")}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :browse_channels}} = socket) do
    {:noreply, enter_modal(socket, "Browse Channels")}
  end

  def handle_params(%{"code" => code}, _uri, %{assigns: %{live_action: :redeem_invite}} = socket) do
    user = socket.assigns.current_user

    case Chat.Invites.redeem_invite(code, user.id) do
      {:ok, invite} ->
        channel = Chat.get_channel!(invite.channel_id)

        {:noreply,
         socket
         |> put_flash(:info, "You joined ##{channel.name}!")
         |> push_navigate(to: ~p"/chat/#{channel.slug}")}

      {:error, :already_member} ->
        invite = Slackex.Repo.get_by!(Chat.InviteLink, code: code)
        channel = Chat.get_channel!(invite.channel_id)

        {:noreply,
         socket
         |> put_flash(:info, "You're already a member of ##{channel.name}.")
         |> push_navigate(to: ~p"/chat/#{channel.slug}")}

      {:error, reason} ->
        message =
          case reason do
            :not_found -> "This invite link is invalid."
            :expired -> "This invite link has expired."
            :max_uses_reached -> "This invite link has reached its usage limit."
            _ -> "Could not join channel."
          end

        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new_dm}} = socket) do
    {:noreply, enter_modal(socket, "New Message")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> leave_conversation()
     |> assign(:page_title, "Chat")
     |> assign(:oldest_message_id, nil)
     |> assign(:has_more_messages, false)
     |> stream(:messages, [], reset: true)}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    user = socket.assigns.current_user

    case SlashCommand.parse(content) do
      {:summarize, range} when socket.assigns.summarization_enabled ->
        send(self(), {:start_summary, range})

        {:noreply,
         socket
         |> assign(:show_summary_modal, true)
         |> assign(:message_form, to_form(%{"content" => ""}, as: :message))}

      {:unknown_command, cmd} ->
        {:noreply, put_flash(socket, :error, "Unknown command: /#{cmd}")}

      _ ->
        cond do
          socket.assigns.active_dm != nil ->
            send_message_to_dm(socket.assigns.active_dm, user, content, socket)

          socket.assigns.active_channel != nil and socket.assigns.can_send ->
            send_message_to_channel(socket.assigns.active_channel, user, content, socket)

          socket.assigns.active_channel != nil ->
            {:noreply, put_flash(socket, :error, "You don't have permission to send messages.")}

          true ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("typing", _params, socket) do
    user = socket.assigns.current_user

    _ =
      cond do
        socket.assigns.active_dm != nil ->
          broadcast_typing(user, {:dm, socket.assigns.active_dm.id})

        socket.assigns.active_channel != nil and socket.assigns.can_send ->
          broadcast_typing(user, {:channel, socket.assigns.active_channel.id})

        true ->
          :ok
      end

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    oldest_id = socket.assigns.oldest_message_id

    cond do
      socket.assigns.active_dm != nil and oldest_id != nil and socket.assigns.has_more_messages ->
        load_older_messages(
          socket,
          &Chat.list_dm_messages/2,
          socket.assigns.active_dm.id,
          oldest_id
        )

      socket.assigns.active_channel != nil and oldest_id != nil and
          socket.assigns.has_more_messages ->
        load_older_messages(
          socket,
          &Chat.list_messages/2,
          socket.assigns.active_channel.id,
          oldest_id
        )

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_search", _params, socket) do
    {:noreply, assign(socket, :search_open, !socket.assigns.search_open)}
  end

  def handle_event("open_summary_modal", _params, socket) do
    {:noreply, assign(socket, show_summary_modal: true, summary_state: :idle, summary_text: "")}
  end

  def handle_event("close_summary_modal", _params, socket) do
    socket = cancel_summary_task(socket)

    {:noreply, assign(socket, show_summary_modal: false, summary_state: :idle, summary_text: "")}
  end

  def handle_event("join_channel", _params, socket) do
    user = socket.assigns.current_user
    channel = socket.assigns.active_channel

    case Chat.join_channel(user.id, channel.id) do
      {:ok, _subscription} ->
        channels = Chat.list_user_channels(user.id)

        {:noreply,
         socket
         |> assign(:channels, channels)
         |> assign(:can_send, true)
         |> assign(:user_role, "member")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not join channel.")}
    end
  end

  def handle_event("leave_channel", _params, socket) do
    user = socket.assigns.current_user
    channel = socket.assigns.active_channel
    role = socket.assigns.user_role

    if role == "owner" do
      {:noreply, put_flash(socket, :error, "Channel owners cannot leave.")}
    else
      Chat.leave_channel(user.id, channel.id)
      channels = Chat.list_user_channels(user.id)

      {:noreply,
       socket
       |> assign(:channels, channels)
       |> push_patch(to: ~p"/chat")}
    end
  end

  def handle_event("accept_request", %{"id" => request_id}, socket) do
    user = socket.assigns.current_user
    request_id = safe_to_integer(request_id)

    case Chat.accept_dm_request(request_id, user.id) do
      {:ok, %{dm_conversation: dm}} ->
        dm_requests = remove_request(socket.assigns.dm_requests, request_id)
        dm_conversations = Chat.list_user_dm_conversations(user.id)

        {:noreply,
         socket
         |> assign(:dm_requests, dm_requests)
         |> assign(:dm_request_count, length(dm_requests))
         |> assign(:dm_conversations, dm_conversations)
         |> push_patch(to: ~p"/chat/dm/#{dm.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not accept request.")}
    end
  end

  def handle_event("decline_request", %{"id" => request_id}, socket) do
    user = socket.assigns.current_user
    request_id = safe_to_integer(request_id)

    case Chat.decline_dm_request(request_id, user.id) do
      {:ok, _request} ->
        dm_requests = remove_request(socket.assigns.dm_requests, request_id)

        {:noreply,
         socket
         |> assign(:dm_requests, dm_requests)
         |> assign(:dm_request_count, length(dm_requests))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not decline request.")}
    end
  end

  def handle_event("block_request_sender", %{"id" => request_id}, socket) do
    user = socket.assigns.current_user
    request_id = safe_to_integer(request_id)

    request = Enum.find(socket.assigns.dm_requests, &(&1.id == request_id))

    if request do
      _ = Chat.decline_dm_request(request_id, user.id)
      _ = Chat.block_user(user.id, request.sender_id)

      dm_requests = remove_request(socket.assigns.dm_requests, request_id)

      {:noreply,
       socket
       |> assign(:dm_requests, dm_requests)
       |> assign(:dm_request_count, length(dm_requests))}
    else
      {:noreply, put_flash(socket, :error, "Request not found.")}
    end
  end

  def handle_event("block_user", _params, socket) do
    user = socket.assigns.current_user
    dm = socket.assigns.active_dm
    other_id = dm_other_user_id(dm, user.id)

    case Chat.block_user(user.id, other_id) do
      {:ok, _block} ->
        dm_conversations =
          Chat.list_user_dm_conversations(user.id)
          |> Enum.reject(fn conv -> conv.other_user.id == other_id end)

        {:noreply,
         socket
         |> assign(:dm_conversations, dm_conversations)
         |> put_flash(:info, "User has been blocked")
         |> push_patch(to: ~p"/chat")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not block user.")}
    end
  end

  def handle_event("open_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, true)
     |> assign(:report_message_id, nil)}
  end

  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_message_id, nil)}
  end

  def handle_event("report_message", %{"message-id" => message_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, true)
     |> assign(:report_message_id, safe_to_integer(message_id))}
  end

  def handle_event("submit_report", %{"report" => report_params}, socket) do
    user = socket.assigns.current_user
    dm = socket.assigns.active_dm
    other_id = dm_other_user_id(dm, user.id)

    attrs = %{
      category: report_params["category"],
      description: report_params["description"],
      dm_conversation_id: dm.id,
      message_id: parse_message_id(report_params["message_id"])
    }

    case Chat.create_abuse_report(user.id, other_id, attrs) do
      {:ok, _report} ->
        {:noreply,
         socket
         |> dismiss_report_modal()
         |> put_flash(:info, "Report submitted. Thank you for helping keep the community safe.")}

      {:error, %Ecto.Changeset{} = _changeset} ->
        {:noreply,
         socket
         |> dismiss_report_modal()
         |> put_flash(:error, "You already have an open report for this user.")}

      {:error, :account_too_new} ->
        {:noreply,
         socket
         |> dismiss_report_modal()
         |> put_flash(:error, "Your account must be at least 7 days old to report users.")}

      {:error, :dm_restricted} ->
        {:noreply,
         socket
         |> dismiss_report_modal()
         |> put_flash(:error, "You are unable to submit reports at this time.")}
    end
  end

  def handle_event("show_profile", %{"user-id" => user_id}, socket) do
    user_id = safe_to_integer(user_id)

    if is_nil(user_id) do
      {:noreply, socket}
    else
      user = Accounts.get_user!(user_id)
      {:noreply, assign(socket, :profile_user, user)}
    end
  end

  def handle_event("close_profile", _params, socket) do
    {:noreply, assign(socket, :profile_user, nil)}
  end

  def handle_event("send_message_to_profile_user", _params, socket) do
    profile_user = socket.assigns.profile_user
    socket = assign(socket, :profile_user, nil)
    send(self(), {:start_dm, profile_user.id})
    {:noreply, socket}
  end

  def handle_event("edit_profile", _params, socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:show_edit_profile, true)
     |> assign(:edit_profile_form, build_profile_form(user))}
  end

  def handle_event("close_edit_profile", _params, socket) do
    {:noreply, assign(socket, :show_edit_profile, false)}
  end

  def handle_event("validate_profile", %{"profile" => profile_params}, socket) do
    user = socket.assigns.current_user

    changeset =
      user
      |> User.profile_changeset(profile_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_profile_form, to_form(changeset, as: :profile))}
  end

  def handle_event("save_profile", %{"profile" => profile_params}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_user_profile(user, profile_params) do
      {:ok, updated_user} ->
        _ =
          Phoenix.PubSub.broadcast(
            Slackex.PubSub,
            "profile:updates",
            {:profile_updated, updated_user}
          )

        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:show_edit_profile, false)}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_profile_form, to_form(changeset, as: :profile))}
    end
  end

  def handle_event("edit_message", %{"msg-id" => message_id}, socket) do
    message_id = safe_to_integer(message_id)
    user = socket.assigns.current_user

    # Only allow editing own messages
    case Chat.get_message(message_id) do
      {:ok, message} when message.sender_id == user.id ->
        message = Slackex.Repo.preload(message, :sender)

        {:noreply,
         socket
         |> assign(:editing_message_id, message_id)
         |> stream_insert(:messages, Map.put(message, :editing, true))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    socket =
      socket
      |> assign(:editing_message_id, nil)
      |> restore_message_after_edit(socket.assigns.editing_message_id)

    {:noreply, socket}
  end

  def handle_event("save_edit", %{"content" => content} = params, socket) do
    message_id = extract_message_id(params, socket.assigns.editing_message_id)
    user = socket.assigns.current_user

    socket = assign(socket, :editing_message_id, nil)

    case Messaging.edit_message(message_id, user.id, content) do
      {:ok, message} ->
        {:noreply, stream_insert(socket, :messages, enrich_message(message))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not edit message.")}
    end
  end

  def handle_event("delete_message", %{"msg-id" => message_id}, socket) do
    message_id = safe_to_integer(message_id)
    user = socket.assigns.current_user

    case Messaging.delete_message(message_id, user.id) do
      {:ok, message} ->
        message = enrich_message(message)

        {:noreply, stream_insert(socket, :messages, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete message.")}
    end
  end

  def handle_event("toggle_reaction", %{"message-id" => msg_id, "emoji" => emoji}, socket) do
    message_id = safe_to_integer(msg_id)
    user_id = socket.assigns.current_user.id

    case Messaging.toggle_reaction(message_id, user_id, emoji) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not react.")}
    end
  end

  def handle_event("toggle_quick_switcher", _params, socket) do
    {:noreply, assign(socket, :show_quick_switcher, !socket.assigns.show_quick_switcher)}
  end

  def handle_event("pin_message", %{"message-id" => msg_id}, socket) do
    message_id = safe_to_integer(msg_id)
    channel = socket.assigns.active_channel

    case Chat.Pins.pin_message(channel.id, socket.assigns.current_user.id, message_id) do
      {:ok, _} -> {:noreply, assign(socket, :pin_count, socket.assigns.pin_count + 1)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not pin message.")}
    end
  end

  def handle_event("unpin_message", %{"message-id" => msg_id}, socket) do
    message_id = safe_to_integer(msg_id)
    channel = socket.assigns.active_channel

    case Chat.Pins.unpin_message(channel.id, socket.assigns.current_user.id, message_id) do
      :ok -> {:noreply, assign(socket, :pin_count, max(socket.assigns.pin_count - 1, 0))}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unpin message.")}
    end
  end

  def handle_event("open_thread", %{"message-id" => msg_id}, socket) do
    slug = socket.assigns.active_channel.slug
    {:noreply, push_patch(socket, to: ~p"/chat/#{slug}/thread/#{msg_id}")}
  end

  def handle_event("close_thread", _params, socket) do
    if socket.assigns.thread_parent do
      _ =
        Phoenix.PubSub.unsubscribe(
          Slackex.PubSub,
          "thread:#{socket.assigns.thread_parent.id}"
        )
    end

    slug = socket.assigns.active_channel.slug
    {:noreply, socket |> assign(:thread_parent, nil) |> push_patch(to: ~p"/chat/#{slug}")}
  end

  defp extract_message_id(%{"msg-id" => id}, _fallback), do: safe_to_integer(id)
  defp extract_message_id(_params, fallback), do: fallback

  defp parse_message_id(nil), do: nil
  defp parse_message_id(""), do: nil
  defp parse_message_id(id) when is_binary(id), do: safe_to_integer(id)

  defp safe_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp safe_to_integer(value) when is_integer(value), do: value
  defp safe_to_integer(_), do: nil

  # ---------------------------------------------------------------------------
  # PubSub / Info handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:envelope, %{event: "message.new", payload: message} = envelope}, socket) do
    if message_for_active_conversation?(envelope, socket) do
      message = enrich_message(message)
      last = socket.assigns.last_message

      grouped = Slackex.Chat.MessageGrouping.should_group?(message, last)
      {show_divider, divider_label} = Slackex.Chat.MessageGrouping.divider_info(message, last)

      message =
        Map.merge(message, %{
          grouped: grouped,
          show_divider: show_divider,
          divider_label: divider_label
        })

      _ =
        if socket.assigns.link_previews_enabled do
          Phoenix.PubSub.subscribe(Slackex.PubSub, "link_previews:#{message.id}")
        end

      socket =
        socket
        |> assign(:last_message, message)
        |> stream_insert(:messages, message)
        |> maybe_mark_as_read(message)

      {:noreply, socket}
    else
      {:noreply, increment_unread_count(socket, envelope)}
    end
  end

  @impl true
  def handle_info({:envelope, %{event: "message.edited", payload: payload} = envelope}, socket) do
    if message_for_active_conversation?(envelope, socket) do
      updated_message = apply_edit_to_stream(payload)
      {:noreply, stream_insert(socket, :messages, updated_message)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:envelope, %{event: "message.deleted", payload: payload} = envelope},
        socket
      ) do
    if message_for_active_conversation?(envelope, socket) do
      deleted_message = apply_delete_to_stream(payload)

      socket =
        if socket.assigns.last_message && socket.assigns.last_message.id == deleted_message.id do
          assign(socket, :last_message, deleted_message)
        else
          socket
        end

      {:noreply, stream_insert(socket, :messages, deleted_message)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:envelope, %{event: "reaction.toggled", payload: payload} = envelope},
        socket
      ) do
    if message_for_active_conversation?(envelope, socket) do
      reactions = socket.assigns.reactions
      msg_id = payload.message_id
      current = Map.get(reactions, msg_id, [])
      updated = apply_reaction_update(current, payload)
      updated_reactions = Map.put(reactions, msg_id, updated)

      # Re-insert the message into the stream to trigger re-render
      socket =
        case Chat.get_message(msg_id) do
          {:ok, message} ->
            message = Slackex.Repo.preload(message, :sender)
            stream_insert(socket, :messages, message)

          _ ->
            socket
        end

      {:noreply, assign(socket, :reactions, updated_reactions)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:close_quick_switcher, socket) do
    {:noreply, assign(socket, :show_quick_switcher, false)}
  end

  @impl true
  def handle_info({:pin_count_updated, count}, socket) do
    {:noreply, assign(socket, :pin_count, count)}
  end

  @impl true
  def handle_info({:send_thread_reply, parent_id, content}, socket) do
    user = socket.assigns.current_user
    channel = socket.assigns.active_channel

    if channel do
      case Messaging.send_reply(channel.id, :channel, user.id, parent_id, content) do
        {:ok, _reply} -> {:noreply, socket}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Could not send reply.")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:envelope, %{event: "thread.reply", payload: payload}}, socket) do
    if socket.assigns.thread_parent &&
         socket.assigns.thread_parent.id == payload.parent_message_id do
      send_update(ThreadPanelComponent,
        id: "thread-panel",
        new_reply: payload
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:envelope, %{event: "message.reply_count_updated", payload: payload}},
        socket
      ) do
    msg_id = payload.message_id
    reply_count = payload.reply_count

    case Chat.get_message(msg_id) do
      {:ok, message} ->
        updated = message |> Slackex.Repo.preload(:sender) |> Map.put(:reply_count, reply_count)
        {:noreply, stream_insert(socket, :messages, updated)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:envelope, %{event: "typing", payload: payload}}, socket) do
    user = socket.assigns.current_user

    if payload.user_id != user.id do
      typing_users = MapSet.put(socket.assigns.typing_users, payload.username)
      _ = Process.send_after(self(), {:clear_typing, payload.username}, @typing_timeout_ms)
      {:noreply, assign(socket, :typing_users, typing_users)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:clear_typing, username}, socket) do
    typing_users = MapSet.delete(socket.assigns.typing_users, username)
    {:noreply, assign(socket, :typing_users, typing_users)}
  end

  @impl true
  def handle_info(:online_heartbeat, socket) do
    OnlineTracker.refresh(socket.assigns.current_user.id)
    _ = Process.send_after(self(), :online_heartbeat, @heartbeat_interval_ms)
    {:noreply, socket}
  end

  # -- Summary streaming --

  @impl true
  def handle_info(:close_summary_modal, socket) do
    socket = cancel_summary_task(socket)

    {:noreply, assign(socket, show_summary_modal: false, summary_state: :idle, summary_text: "")}
  end

  @impl true
  def handle_info({:start_summary, range}, socket) do
    user = socket.assigns.current_user
    socket = cancel_summary_task(socket)

    since = time_range_to_datetime(range)
    live_view_pid = self()

    summary_target =
      cond do
        socket.assigns.active_channel -> {:channel, socket.assigns.active_channel.id}
        socket.assigns.active_dm -> {:dm, socket.assigns.active_dm.id}
        true -> nil
      end

    if summary_target do
      task =
        Task.Supervisor.async_nolink(Slackex.TaskSupervisor, fn ->
          stream_summary(summary_target, since, user.id, live_view_pid)
        end)

      {:noreply,
       assign(socket,
         active_summary_task: task,
         summary_state: :loading,
         summary_text: "",
         show_summary_modal: true
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:summary_token, chunk}, socket) do
    new_text = socket.assigns.summary_text <> chunk
    {:noreply, assign(socket, summary_text: new_text)}
  end

  @impl true
  def handle_info(:summary_complete, socket) do
    {:noreply, assign(socket, summary_state: :complete, active_summary_task: nil)}
  end

  @impl true
  def handle_info({:summary_error, reason}, socket) do
    {:noreply,
     assign(socket, summary_state: :error, summary_error: reason, active_summary_task: nil)}
  end

  @impl true
  def handle_info({:link_previews_ready, message_id, previews}, socket) do
    updated = Map.put(socket.assigns.link_previews, message_id, previews)
    socket = assign(socket, :link_previews, updated)

    # Stream items don't re-render when surrounding assigns change —
    # re-insert the message to trigger a re-render with preview data.
    socket =
      case Chat.get_message(message_id) do
        {:ok, message} ->
          message = Slackex.Repo.preload(message, :sender)
          stream_insert(socket, :messages, message)

        {:error, _} ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    if socket.assigns.summary_state == :loading do
      require Logger
      Logger.error("Summary task crashed: #{inspect(reason)}")

      {:noreply,
       assign(socket,
         summary_state: :error,
         summary_error: :task_crashed,
         active_summary_task: nil
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:start_dm, user_id}, socket) do
    current_user = socket.assigns.current_user

    case Chat.find_or_create_dm(current_user.id, user_id) do
      {:ok, dm} ->
        dm_conversations = Chat.list_user_dm_conversations(current_user.id)

        {:noreply,
         socket
         |> assign(:dm_conversations, dm_conversations)
         |> push_patch(to: ~p"/chat/dm/#{dm.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start conversation.")}
    end
  end

  @impl true
  def handle_info({:channel_created, channel}, socket) do
    {:noreply, refresh_channels_and_navigate(socket, channel)}
  end

  @impl true
  def handle_info({:channel_joined, channel}, socket) do
    {:noreply, refresh_channels_and_navigate(socket, channel)}
  end

  @impl true
  def handle_info({:dm_conversation_new, _dm}, socket) do
    user = socket.assigns.current_user
    dm_conversations = Chat.list_user_dm_conversations(user.id)
    {:noreply, assign(socket, :dm_conversations, dm_conversations)}
  end

  @impl true
  def handle_info({:dm_request_new, request}, socket) do
    request = Slackex.Repo.preload(request, :sender)
    dm_requests = [request | socket.assigns.dm_requests]
    dm_request_count = socket.assigns.dm_request_count + 1

    {:noreply,
     socket
     |> assign(:dm_requests, dm_requests)
     |> assign(:dm_request_count, dm_request_count)}
  end

  @impl true
  def handle_info({:dm_request_accepted, _request}, socket) do
    user = socket.assigns.current_user
    dm_conversations = Chat.list_user_dm_conversations(user.id)

    {:noreply,
     socket
     |> assign(:dm_conversations, dm_conversations)
     |> put_flash(:info, "Your DM request was accepted")}
  end

  @impl true
  def handle_info({:start_dm_request, user_id}, socket) do
    current_user = socket.assigns.current_user

    case Chat.create_dm_request(current_user.id, user_id, "") do
      {:ok, %Slackex.Chat.DMRequest{}} ->
        {:noreply,
         socket
         |> put_flash(:info, "DM request sent")
         |> push_patch(to: ~p"/chat")}

      {:ok, %Slackex.Chat.DMConversation{} = dm} ->
        dm_conversations = Chat.list_user_dm_conversations(current_user.id)

        {:noreply,
         socket
         |> assign(:dm_conversations, dm_conversations)
         |> push_patch(to: ~p"/chat/dm/#{dm.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, dm_request_error_message(reason))}
    end
  end

  @impl true
  def handle_info({:presence, :online, user_id}, socket) do
    online_user_ids = MapSet.put(socket.assigns.online_user_ids, user_id)
    {:noreply, assign(socket, :online_user_ids, online_user_ids)}
  end

  @impl true
  def handle_info({:presence, :offline, user_id}, socket) do
    online_user_ids = MapSet.delete(socket.assigns.online_user_ids, user_id)
    {:noreply, assign(socket, :online_user_ids, online_user_ids)}
  end

  @impl true
  def handle_info({:show_profile, user_id}, socket) do
    user = Accounts.get_user!(user_id)
    {:noreply, assign(socket, :profile_user, user)}
  end

  @impl true
  def handle_info({:profile_updated, updated_user}, socket) do
    socket =
      socket
      |> maybe_refresh_profile_card(updated_user)
      |> maybe_refresh_current_user(updated_user)
      |> refresh_dm_conversations_for_profile(updated_user)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:perform_search, query, mode, component_id}, socket) do
    user = socket.assigns.current_user

    case Search.search_messages(user.id, query, mode: mode) do
      {:ok, results} ->
        send_update(SearchComponent, id: component_id, results: results, searching: false)
        {:noreply, socket}

      {:error, _reason} ->
        send_update(SearchComponent, id: component_id, results: [], searching: false)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:search_results, _query, results}, socket) do
    send_update(SearchComponent, id: "search", results: results, searching: false)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:search_started}, socket) do
    send_update(SearchComponent, id: "search", searching: true)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:close_search, socket) do
    {:noreply, assign(socket, :search_open, false)}
  end

  @impl true
  def handle_info({:jump_to_message, message_id, channel_id, dm_id}, socket) do
    case {to_integer(channel_id), to_integer(dm_id)} do
      {cid, _} when is_integer(cid) ->
        channel = Chat.get_channel!(cid)

        {:noreply,
         socket
         |> assign(:search_open, false)
         |> push_patch(to: ~p"/chat/#{channel.slug}?target=#{message_id}")}

      {_, did} when is_integer(did) ->
        {:noreply,
         socket
         |> assign(:search_open, false)
         |> push_patch(to: ~p"/chat/dm/#{did}?target=#{message_id}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    _ =
      if socket.assigns[:current_user] do
        user_id = socket.assigns.current_user.id
        OnlineTracker.mark_offline(user_id)
        Phoenix.PubSub.broadcast(Slackex.PubSub, @presence_topic, {:presence, :offline, user_id})
      end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp remove_request(requests, request_id) do
    Enum.reject(requests, &(&1.id == request_id))
  end

  defp build_profile_form(user) do
    changeset = User.profile_changeset(user, %{})
    to_form(changeset, as: :profile)
  end

  defp short_node_name do
    node()
    |> Atom.to_string()
    |> String.split("@")
    |> List.last()
  end

  defp dismiss_report_modal(socket) do
    socket
    |> assign(:show_report_modal, false)
    |> assign(:report_message_id, nil)
  end

  defp dm_other_user_id(dm, current_user_id) do
    if dm.user_a_id == current_user_id, do: dm.user_b_id, else: dm.user_a_id
  end

  defp enter_modal(socket, page_title) do
    socket
    |> leave_conversation()
    |> assign(:page_title, page_title)
  end

  defp refresh_channels_and_navigate(socket, channel) do
    channels = Chat.list_user_channels(socket.assigns.current_user.id)

    socket
    |> assign(:channels, channels)
    |> push_patch(to: ~p"/chat/#{channel.slug}")
  end

  defp load_older_messages(socket, list_fn, conversation_id, oldest_id) do
    conversation_id
    |> list_fn.(before: oldest_id, limit: @message_page_size)
    |> Enum.reverse()
    |> prepend_older_messages(socket)
  end

  defp prepend_older_messages([], socket) do
    {:noreply, assign(socket, :has_more_messages, false)}
  end

  defp prepend_older_messages(messages, socket) do
    messages = Slackex.Chat.MessageGrouping.annotate(messages)
    new_oldest = List.first(messages).id

    socket =
      messages
      |> Enum.reverse()
      |> Enum.reduce(socket, fn msg, acc ->
        stream_insert(acc, :messages, msg, at: 0)
      end)
      |> assign(:oldest_message_id, new_oldest)
      |> assign(:has_more_messages, length(messages) >= @message_page_size)

    {:noreply, socket}
  end

  defp leave_conversation(socket) do
    if connected?(socket) do
      case socket.assigns do
        %{active_channel: %{id: id}} when not is_nil(id) ->
          Messaging.unsubscribe_channel(id)

        %{active_dm: %{id: id}} when not is_nil(id) ->
          Messaging.unsubscribe_dm(id)

        _ ->
          :ok
      end
    end

    socket
    |> assign(:active_channel, nil)
    |> assign(:active_dm, nil)
  end

  defp enter_channel(socket, channel, can_send, user_role, target_message_id) do
    user = socket.assigns.current_user
    socket = leave_conversation(socket)

    # Unsubscribe first to prevent double subscription — mount's
    # subscribe_all_conversations already subscribes to all channels for
    # unread count tracking. Without this, the LiveView receives each
    # PubSub message twice, causing the second delivery to overwrite the
    # first with incorrect grouping (grouped: true against itself).
    if connected?(socket) do
      Messaging.unsubscribe_channel(channel.id)
      Messaging.subscribe_channel(channel.id)
    end

    messages = fetch_messages_for_entry({:channel, channel.id}, target_message_id)
    reactions = messages |> Enum.map(& &1.id) |> Chat.list_reactions()
    Chat.mark_as_read(user.id, channel.id)

    socket
    |> assign(:active_channel, channel)
    |> assign(:can_send, can_send)
    |> assign(:user_role, user_role)
    |> assign(:page_title, "##{channel.name}")
    |> assign(:reactions, reactions)
    |> assign(:member_count, length(Chat.Members.list_members(channel.id)))
    |> assign(:pin_count, Chat.Pins.pin_count(channel.id))
    |> reset_unread_count(:channel_counts, channel.id)
    |> assign_conversation_state(messages)
    |> assign(:sidebar_open, true)
  end

  defp enter_dm(socket, dm, target_message_id) do
    user = socket.assigns.current_user
    socket = leave_conversation(socket)

    if connected?(socket) do
      Messaging.unsubscribe_dm(dm.id)
      Messaging.subscribe_dm(dm.id)
    end

    other_user = dm_other_user(dm, user.id)
    messages = fetch_messages_for_entry({:dm, dm.id}, target_message_id)
    reactions = messages |> Enum.map(& &1.id) |> Chat.list_reactions()
    Chat.mark_dm_as_read(user.id, dm.id)

    socket
    |> assign(:active_dm, dm)
    |> assign(:active_channel, nil)
    |> assign(:can_send, true)
    |> assign(:page_title, other_user.display_name || other_user.username)
    |> assign(:reactions, reactions)
    |> reset_unread_count(:dm_counts, dm.id)
    |> assign_conversation_state(messages)
  end

  defp fetch_initial_messages(list_fn, conversation_id) do
    conversation_id
    |> list_fn.(limit: @message_page_size)
    |> Enum.reverse()
  end

  defp fetch_messages_for_entry(target, nil) do
    {list_fn, conversation_id} =
      case target do
        {:channel, id} -> {&Chat.list_messages/2, id}
        {:dm, id} -> {&Chat.list_dm_messages/2, id}
      end

    fetch_initial_messages(list_fn, conversation_id)
  end

  defp fetch_messages_for_entry(target, target_message_id) do
    {:ok, messages} = HistoryLoader.around(target, target_message_id, limit: @message_page_size)
    messages
  end

  defp parse_target_param(%{"target" => target}) when is_binary(target) do
    case Integer.parse(target) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_target_param(_params), do: nil

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp to_integer(_), do: nil

  defp maybe_push_scroll_event(socket, nil), do: socket

  defp maybe_push_scroll_event(socket, target_message_id) do
    push_event(socket, "scroll_to_message", %{id: "messages-#{target_message_id}"})
  end

  defp oldest_message_id([first | _]), do: first.id
  defp oldest_message_id([]), do: nil

  defp assign_conversation_state(socket, messages) do
    messages = Slackex.Chat.MessageGrouping.annotate(messages)

    previews =
      if socket.assigns.link_previews_enabled do
        message_ids = Enum.map(messages, & &1.id)
        Links.list_previews_for_messages(message_ids)
      else
        %{}
      end

    socket
    |> assign(:typing_users, MapSet.new())
    |> assign(:oldest_message_id, oldest_message_id(messages))
    |> assign(:has_more_messages, length(messages) >= @message_page_size)
    |> assign(:link_previews, previews)
    |> assign(:last_message, List.last(messages))
    |> stream(:messages, messages, reset: true)
  end

  defp dm_other_user(dm, current_user_id) do
    Accounts.get_user!(dm_other_user_id(dm, current_user_id))
  end

  defp broadcast_typing(user, {scope, id}) do
    {topic, target} =
      case scope do
        :dm -> {"dm:#{id}", {:dm, id}}
        :channel -> {"channel:#{id}", {:channel, id}}
      end

    envelope = Envelope.wrap("typing", target, %{user_id: user.id, username: user.username})
    Phoenix.PubSub.broadcast(Slackex.PubSub, topic, {:envelope, envelope})
  end

  defp send_message_to_channel(channel, user, content, socket) do
    Messaging.send_message(channel.id, user.id, content)
    |> handle_send_result(socket)
  end

  defp send_message_to_dm(dm, user, content, socket) do
    Messaging.send_dm(dm.id, user.id, content)
    |> handle_send_result(socket)
  end

  defp handle_send_result({:ok, _message}, socket) do
    {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}
  end

  defp handle_send_result({:error, :rate_limited}, socket) do
    {:noreply, put_flash(socket, :error, "You're sending messages too fast. Please slow down.")}
  end

  defp handle_send_result({:error, :backpressure}, socket) do
    {:noreply, put_flash(socket, :error, "Server is busy. Please try again in a moment.")}
  end

  defp handle_send_result({:error, :invalid_content}, socket) do
    {:noreply,
     put_flash(socket, :error, "Message content is invalid (must be 1-4000 characters).")}
  end

  defp handle_send_result({:error, _reason}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to send message.")}
  end

  defp authorize_channel(user_id, channel) do
    role = Chat.get_role(user_id, channel.id)

    cond do
      role != nil ->
        {:ok, Permissions.can?(role, :send_message), role}

      not channel.is_private ->
        {:ok, false, nil}

      true ->
        {:error, :unauthorized}
    end
  end

  defp enrich_message(%{sender: %{username: _}} = message), do: message

  defp enrich_message(%{sender_id: sender_id} = message) when is_integer(sender_id) do
    sender = Accounts.get_user!(sender_id)
    Map.put(message, :sender, sender)
  end

  defp enrich_message(message), do: message

  defp maybe_mark_as_read(socket, message) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user
    channel_id = Map.get(message, :channel_id)

    if channel && channel_id == channel.id do
      Chat.mark_as_read(user.id, channel.id)
    end

    socket
  end

  defp subscribe_all_conversations(channels, dm_conversations) do
    Enum.each(channels, fn channel -> Messaging.subscribe_channel(channel.id) end)
    Enum.each(dm_conversations, fn dm -> Messaging.subscribe_dm(dm.id) end)
  end

  defp message_for_active_conversation?(%{target: %{type: :channel, id: id}}, socket) do
    socket.assigns.active_channel != nil and socket.assigns.active_channel.id == id
  end

  defp message_for_active_conversation?(%{target: %{type: :dm, id: id}}, socket) do
    socket.assigns.active_dm != nil and socket.assigns.active_dm.id == id
  end

  defp message_for_active_conversation?(_envelope, _socket), do: false

  defp maybe_refresh_profile_card(socket, updated_user) do
    case socket.assigns.profile_user do
      %{id: id} when id == updated_user.id ->
        assign(socket, :profile_user, updated_user)

      _ ->
        socket
    end
  end

  defp maybe_refresh_current_user(socket, updated_user) do
    if socket.assigns.current_user.id == updated_user.id do
      assign(socket, :current_user, updated_user)
    else
      socket
    end
  end

  defp refresh_dm_conversations_for_profile(socket, updated_user) do
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

  defp restore_message_after_edit(socket, nil), do: socket

  defp restore_message_after_edit(socket, message_id) do
    case Chat.get_message(message_id) do
      {:ok, message} ->
        message = Slackex.Repo.preload(message, :sender)
        stream_insert(socket, :messages, Map.put(message, :editing, false))

      _ ->
        socket
    end
  end

  defp apply_reaction_update(reactions, %{action: :added, emoji: emoji, user_id: user_id}) do
    case Enum.find_index(reactions, &(&1.emoji == emoji)) do
      nil ->
        [%{emoji: emoji, count: 1, user_ids: [user_id]} | reactions]

      idx ->
        List.update_at(reactions, idx, &add_user_to_reaction(&1, user_id))
    end
  end

  defp apply_reaction_update(reactions, %{action: :removed, emoji: emoji, user_id: user_id}) do
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

  defp apply_edit_to_stream(%{id: id, content: content, edited_at: edited_at}) do
    apply_update_to_stream(id, %{content: content, edited_at: edited_at})
  end

  defp apply_delete_to_stream(%{id: id, deleted_at: deleted_at}) do
    apply_update_to_stream(id, %{content: nil, deleted_at: deleted_at})
  end

  defp apply_update_to_stream(message_id, updates) do
    case Chat.get_message(message_id) do
      {:ok, message} ->
        message
        |> Slackex.Repo.preload(:sender)
        |> Map.merge(updates)

      {:error, _} ->
        Map.merge(%{id: message_id, sender: %{username: "unknown"}}, updates)
    end
  end

  defp increment_unread_count(socket, %{target: %{type: :channel, id: channel_id}}) do
    update_unread_count(socket, :channel_counts, channel_id, &(&1 + 1))
  end

  defp increment_unread_count(socket, %{target: %{type: :dm, id: dm_id}}) do
    update_unread_count(socket, :dm_counts, dm_id, &(&1 + 1))
  end

  defp increment_unread_count(socket, _envelope), do: socket

  defp reset_unread_count(socket, count_key, conversation_id) do
    update_unread_count(socket, count_key, conversation_id, fn _current -> 0 end)
  end

  defp update_unread_count(socket, count_key, conversation_id, update_fn) do
    unread_counts = socket.assigns.unread_counts
    counts_map = Map.fetch!(unread_counts, count_key)
    current = Map.get(counts_map, conversation_id, 0)
    updated_counts = Map.put(counts_map, conversation_id, update_fn.(current))
    updated_unread = Map.put(unread_counts, count_key, updated_counts)
    assign(socket, :unread_counts, updated_unread)
  end

  # ---------------------------------------------------------------------------
  # Summary helpers
  # ---------------------------------------------------------------------------

  defp stream_summary({:channel, channel_id}, since, user_id, live_view_pid) do
    stream_summary_result(Summarizer.summarize_channel(channel_id, since, user_id), live_view_pid)
  end

  defp stream_summary({:dm, dm_id}, since, user_id, live_view_pid) do
    stream_summary_result(Summarizer.summarize_dm(dm_id, since, user_id), live_view_pid)
  end

  defp stream_summary_result(result, live_view_pid) do
    case result do
      {:ok, stream} ->
        try do
          token_count =
            Enum.reduce(stream, 0, fn chunk, count ->
              send(live_view_pid, {:summary_token, chunk})
              count + 1
            end)

          if token_count > 0 do
            send(live_view_pid, :summary_complete)
          else
            send(live_view_pid, {:summary_error, :empty_response})
          end
        rescue
          e ->
            require Logger
            Logger.error("Stream enumeration failed: #{inspect(e)}")
            send(live_view_pid, {:summary_error, {:stream_error, Exception.message(e)}})
        end

      {:error, reason} ->
        require Logger
        Logger.error("Summarization failed: #{inspect(reason)}")
        send(live_view_pid, {:summary_error, reason})
    end
  end

  defp cancel_summary_task(socket) do
    case socket.assigns[:active_summary_task] do
      %Task{pid: pid} ->
        Process.exit(pid, :kill)
        assign(socket, active_summary_task: nil)

      _ ->
        socket
    end
  end

  defp time_range_to_datetime("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
  defp time_range_to_datetime("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp time_range_to_datetime("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp time_range_to_datetime(_), do: DateTime.add(DateTime.utc_now(), -1, :day)

  # Template is in co-located index.html.heex

  defp dm_request_error_message(:account_too_new),
    do: "Your account must be at least 24 hours old to send DM requests."

  defp dm_request_error_message(:no_shared_channels),
    do: "You need to share a channel with this user before sending a DM request."

  defp dm_request_error_message(:blocked),
    do: "Unable to send a DM request to this user."

  defp dm_request_error_message(:dm_restricted),
    do: "Your DM privileges have been restricted."

  defp dm_request_error_message(:cooldown_active),
    do: "Please wait before sending another request to this user."

  defp dm_request_error_message(:rate_limited),
    do: "You're sending too many DM requests. Please try again later."

  defp dm_request_error_message(:too_many_pending),
    do: "You have too many pending DM requests. Wait for some to be accepted or declined."

  defp dm_request_error_message(:dm_preference_rejected),
    do: "This user is not accepting DM requests."

  defp dm_request_error_message(_),
    do: "Could not send DM request."
end
