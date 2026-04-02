defmodule SlackexWeb.ChatLive.Index do
  use SlackexWeb, :live_view

  alias Slackex.Accounts
  alias Slackex.Accounts.User
  alias Slackex.Chat
  alias Slackex.Chat.MessageGrouping
  alias Slackex.Messaging
  alias Slackex.Notifications.OnlineTracker
  alias Slackex.Notifications.Preference
  alias Slackex.Search
  alias SlackexWeb.ChatLive.BrowseChannelsModal
  alias SlackexWeb.ChatLive.ChannelMembersModal
  alias SlackexWeb.ChatLive.Conversations
  alias SlackexWeb.ChatLive.CreateChannelModal
  alias SlackexWeb.ChatLive.Helpers
  alias SlackexWeb.ChatLive.InviteLinkModal
  alias SlackexWeb.ChatLive.NewDmModal
  alias SlackexWeb.ChatLive.PinnedMessagesModal
  alias SlackexWeb.ChatLive.QuickSwitcherModal
  alias SlackexWeb.ChatLive.SearchComponent
  alias SlackexWeb.ChatLive.SidebarComponent
  alias SlackexWeb.ChatLive.SlashCommand
  alias SlackexWeb.ChatLive.Summary
  alias SlackexWeb.ChatLive.SummaryModal
  alias SlackexWeb.ChatLive.ThreadPanelComponent

  import SlackexWeb.ChatComponents

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
        Conversations.subscribe_all_conversations(channels, dm_conversations)
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
     |> assign(:edit_profile_form, Helpers.build_profile_form(user))
     |> assign(:editing_message_id, nil)
     |> assign(:reactions, %{})
     |> assign(:thread_parent, nil)
     |> assign(:member_count, 0)
     |> assign(:pin_count, 0)
     |> assign(:show_quick_switcher, false)
     |> assign(:show_node, FunWithFlags.enabled?(:show_cluster_node, for: user))
     |> assign(:node_name, Helpers.short_node_name())
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
     |> assign(:push_notifications_enabled, FunWithFlags.enabled?(:push_notifications))
     |> assign(:push_permission, "default")
     |> assign(:push_subscribed, false)
     |> assign(
       :notification_level,
       if FunWithFlags.enabled?(:push_notifications) do
         Preference.resolve_level(user.id, nil)
       else
         "all"
       end
     )
     |> assign(:channel_notification_level, "all")
     |> stream(:messages, [])}
  end

  # ---------------------------------------------------------------------------
  # Handle params
  # ---------------------------------------------------------------------------

  @impl true
  def handle_params(%{"dm_id" => dm_id} = params, _uri, %{assigns: %{live_action: :dm}} = socket) do
    user = socket.assigns.current_user
    dm = Chat.get_dm_conversation!(dm_id)

    if user.id in [dm.user_a_id, dm.user_b_id] do
      target_message_id = Helpers.parse_target_param(params)

      socket =
        socket
        |> Conversations.enter_dm(dm, target_message_id)
        |> Helpers.maybe_push_scroll_event(target_message_id)

      {:noreply, socket}
    else
      {:noreply, socket |> put_flash(:error, "Not found.") |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(
        %{"dm_id" => dm_id, "message_id" => message_id},
        _uri,
        %{assigns: %{live_action: :dm_thread}} = socket
      ) do
    user = socket.assigns.current_user
    dm = Chat.get_dm_conversation!(dm_id)

    if user.id in [dm.user_a_id, dm.user_b_id] do
      parent =
        Chat.get_message!(String.to_integer(message_id))
        |> Slackex.Repo.preload(:sender)

      _ =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Slackex.PubSub, "thread:#{parent.id}")
        end

      socket =
        if socket.assigns.active_dm == nil || socket.assigns.active_dm.id != dm.id do
          Conversations.enter_dm(socket, dm, nil)
        else
          socket
        end

      {:noreply, assign(socket, :thread_parent, parent)}
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

    case Helpers.authorize_channel(user.id, channel) do
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
            Conversations.enter_channel(socket, channel, can_send, role, nil)
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

    case Helpers.authorize_channel(user.id, channel) do
      {:ok, can_send, role} ->
        target_message_id = Helpers.parse_target_param(params)

        socket =
          socket
          |> Conversations.enter_channel(channel, can_send, role, target_message_id)
          |> Helpers.maybe_push_scroll_event(target_message_id)

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
    {:noreply, Conversations.enter_modal(socket, "Create Channel")}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :browse_channels}} = socket) do
    {:noreply, Conversations.enter_modal(socket, "Browse Channels")}
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
    {:noreply, Conversations.enter_modal(socket, "New Message")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> Conversations.leave_conversation()
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
            Helpers.send_message_to_dm(socket.assigns.active_dm, user, content, socket)

          socket.assigns.active_channel != nil and socket.assigns.can_send ->
            Helpers.send_message_to_channel(socket.assigns.active_channel, user, content, socket)

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
          Helpers.broadcast_typing(user, {:dm, socket.assigns.active_dm.id})

        socket.assigns.active_channel != nil and socket.assigns.can_send ->
          Helpers.broadcast_typing(user, {:channel, socket.assigns.active_channel.id})

        true ->
          :ok
      end

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    oldest_id = socket.assigns.oldest_message_id

    cond do
      socket.assigns.active_dm != nil and oldest_id != nil and socket.assigns.has_more_messages ->
        Conversations.load_older_messages(
          socket,
          &Chat.list_dm_messages/2,
          socket.assigns.active_dm.id,
          oldest_id
        )

      socket.assigns.active_channel != nil and oldest_id != nil and
          socket.assigns.has_more_messages ->
        Conversations.load_older_messages(
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
    socket = assign(socket, :search_open, !socket.assigns.search_open)
    _ = if socket.assigns.search_open, do: track_feature(socket, "search", %{action: "open"})
    {:noreply, socket}
  end

  def handle_event("open_summary_modal", _params, socket) do
    socket = assign(socket, show_summary_modal: true, summary_state: :idle, summary_text: "")
    _ = track_feature(socket, "summarization", %{action: "open"})
    {:noreply, socket}
  end

  def handle_event("close_summary_modal", _params, socket) do
    socket = Summary.cancel_summary_task(socket)

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
    request_id = Helpers.safe_to_integer(request_id)

    case Chat.accept_dm_request(request_id, user.id) do
      {:ok, %{dm_conversation: dm}} ->
        dm_requests = Helpers.remove_request(socket.assigns.dm_requests, request_id)
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
    request_id = Helpers.safe_to_integer(request_id)

    case Chat.decline_dm_request(request_id, user.id) do
      {:ok, _request} ->
        dm_requests = Helpers.remove_request(socket.assigns.dm_requests, request_id)

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
    request_id = Helpers.safe_to_integer(request_id)

    request = Enum.find(socket.assigns.dm_requests, &(&1.id == request_id))

    if request do
      _ = Chat.decline_dm_request(request_id, user.id)
      _ = Chat.block_user(user.id, request.sender_id)

      dm_requests = Helpers.remove_request(socket.assigns.dm_requests, request_id)

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
    other_id = Helpers.dm_other_user_id(dm, user.id)

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
     |> assign(:report_message_id, Helpers.safe_to_integer(message_id))}
  end

  def handle_event("submit_report", %{"report" => report_params}, socket) do
    user = socket.assigns.current_user
    dm = socket.assigns.active_dm
    other_id = Helpers.dm_other_user_id(dm, user.id)

    attrs = %{
      category: report_params["category"],
      description: report_params["description"],
      dm_conversation_id: dm.id,
      message_id: Helpers.parse_message_id(report_params["message_id"])
    }

    case Chat.create_abuse_report(user.id, other_id, attrs) do
      {:ok, _report} ->
        {:noreply,
         socket
         |> Helpers.dismiss_report_modal()
         |> put_flash(:info, "Report submitted. Thank you for helping keep the community safe.")}

      {:error, %Ecto.Changeset{} = _changeset} ->
        {:noreply,
         socket
         |> Helpers.dismiss_report_modal()
         |> put_flash(:error, "You already have an open report for this user.")}

      {:error, :account_too_new} ->
        {:noreply,
         socket
         |> Helpers.dismiss_report_modal()
         |> put_flash(:error, "Your account must be at least 7 days old to report users.")}

      {:error, :dm_restricted} ->
        {:noreply,
         socket
         |> Helpers.dismiss_report_modal()
         |> put_flash(:error, "You are unable to submit reports at this time.")}
    end
  end

  def handle_event("show_profile", %{"user-id" => user_id}, socket) do
    user_id = Helpers.safe_to_integer(user_id)

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

    socket = push_event(socket, "push:check_status", %{})

    {:noreply,
     socket
     |> assign(:show_edit_profile, true)
     |> assign(:edit_profile_form, Helpers.build_profile_form(user))}
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
    message_id = Helpers.safe_to_integer(message_id)
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
      |> Helpers.restore_message_after_edit(socket.assigns.editing_message_id)

    {:noreply, socket}
  end

  def handle_event("save_edit", %{"content" => content} = params, socket) do
    message_id = Helpers.extract_message_id(params, socket.assigns.editing_message_id)
    user = socket.assigns.current_user

    socket = assign(socket, :editing_message_id, nil)

    case Messaging.edit_message(message_id, user.id, content) do
      {:ok, message} ->
        {:noreply, stream_insert(socket, :messages, Helpers.enrich_message(message))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not edit message.")}
    end
  end

  def handle_event("delete_message", %{"msg-id" => message_id}, socket) do
    message_id = Helpers.safe_to_integer(message_id)
    user = socket.assigns.current_user

    case Messaging.delete_message(message_id, user.id) do
      {:ok, message} ->
        message = Helpers.enrich_message(message)

        {:noreply, stream_insert(socket, :messages, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete message.")}
    end
  end

  def handle_event("toggle_reaction", %{"message-id" => msg_id, "emoji" => emoji}, socket) do
    message_id = Helpers.safe_to_integer(msg_id)
    user_id = socket.assigns.current_user.id

    case Messaging.toggle_reaction(message_id, user_id, emoji) do
      {:ok, _} ->
        _ = track_feature(socket, "reactions", %{action: "toggle", emoji: emoji})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not react.")}
    end
  end

  def handle_event("toggle_quick_switcher", _params, socket) do
    socket = assign(socket, :show_quick_switcher, !socket.assigns.show_quick_switcher)

    _ =
      if socket.assigns.show_quick_switcher,
        do: track_feature(socket, "quick_switcher", %{action: "open"})

    {:noreply, socket}
  end

  def handle_event("pin_message", %{"message-id" => msg_id}, socket) do
    channel = socket.assigns.active_channel

    if channel do
      message_id = Helpers.safe_to_integer(msg_id)

      case Chat.Pins.pin_message(channel.id, socket.assigns.current_user.id, message_id) do
        {:ok, _} ->
          socket = assign(socket, :pin_count, socket.assigns.pin_count + 1)
          _ = track_feature(socket, "pins", %{action: "pin"})
          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not pin message.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("unpin_message", %{"message-id" => msg_id}, socket) do
    channel = socket.assigns.active_channel

    if channel do
      message_id = Helpers.safe_to_integer(msg_id)

      case Chat.Pins.unpin_message(channel.id, socket.assigns.current_user.id, message_id) do
        :ok -> {:noreply, assign(socket, :pin_count, max(socket.assigns.pin_count - 1, 0))}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unpin message.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_thread", %{"message-id" => msg_id}, socket) do
    path =
      if socket.assigns.active_dm do
        dm_id = socket.assigns.active_dm.id
        ~p"/chat/dm/#{dm_id}/thread/#{msg_id}"
      else
        slug = socket.assigns.active_channel.slug
        ~p"/chat/#{slug}/thread/#{msg_id}"
      end

    _ = track_feature(socket, "threads", %{action: "open"})
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("analytics:" <> event_type, params, socket) do
    user = socket.assigns.current_user

    context = %{
      user_id: user.id,
      session_id: socket.assigns[:analytics_session_id],
      is_bot: Map.get(user, :is_bot, false),
      user: user
    }

    metadata = Map.drop(params, ["_target"])
    _ = Slackex.Analytics.track(context, event_type, metadata)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_thread", _params, socket) do
    if socket.assigns.thread_parent do
      _ =
        Phoenix.PubSub.unsubscribe(
          Slackex.PubSub,
          "thread:#{socket.assigns.thread_parent.id}"
        )
    end

    path =
      if socket.assigns.active_dm do
        dm_id = socket.assigns.active_dm.id
        ~p"/chat/dm/#{dm_id}"
      else
        slug = socket.assigns.active_channel.slug
        ~p"/chat/#{slug}"
      end

    {:noreply, socket |> assign(:thread_parent, nil) |> push_patch(to: path)}
  end

  # ---------------------------------------------------------------------------
  # Push notification handlers
  # ---------------------------------------------------------------------------

  def handle_event(
        "push:status",
        %{"permission" => permission, "subscribed" => subscribed},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:push_permission, permission)
     |> assign(:push_subscribed, subscribed)}
  end

  def handle_event("enable_push", _params, socket) do
    {:noreply, push_event(socket, "push:subscribe", %{})}
  end

  def handle_event("disable_push", _params, socket) do
    {:noreply, push_event(socket, "push:unsubscribe", %{})}
  end

  def handle_event("push:register_subscription", %{"subscription" => subscription_json}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      "user_id" => user.id,
      "token" => subscription_json,
      "platform" => "web_push",
      "device_name" => "PWA"
    }

    alias Slackex.Notifications.DeviceToken
    alias Slackex.Repo

    existing = Repo.get_by(DeviceToken, token: subscription_json, user_id: user.id)
    base = existing || %DeviceToken{}

    case DeviceToken.changeset(base, attrs) |> Repo.insert_or_update() do
      {:ok, _token} ->
        {:noreply, assign(socket, :push_subscribed, true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to register push subscription")}
    end
  end

  def handle_event("push:remove_subscription", %{"subscription" => subscription_json}, socket) do
    user = socket.assigns.current_user
    alias Slackex.Notifications.DeviceToken
    alias Slackex.Repo

    case Repo.get_by(DeviceToken, token: subscription_json, user_id: user.id) do
      nil -> :ok
      token -> Repo.delete(token)
    end

    {:noreply, assign(socket, :push_subscribed, false)}
  end

  def handle_event("push:unsubscribed", _params, socket) do
    {:noreply, assign(socket, :push_subscribed, false)}
  end

  def handle_event("push:error", %{"reason" => reason}, socket) do
    {:noreply, put_flash(socket, :error, "Notification error: #{reason}")}
  end

  def handle_event("update_notification_level", %{"level" => level}, socket) do
    user = socket.assigns.current_user
    _ = Preference.set_global_default(user.id, level)
    {:noreply, assign(socket, :notification_level, level)}
  end

  def handle_event("set_channel_notification", %{"level" => level}, socket) do
    user = socket.assigns.current_user
    channel = socket.assigns[:active_channel]

    if channel do
      _ = Preference.set_preference(user.id, channel.id, level)
      {:noreply, assign(socket, :channel_notification_level, level)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub / Info handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:envelope, %{event: "message.new", payload: message} = envelope}, socket) do
    if Helpers.message_for_active_conversation?(envelope, socket) do
      message = Helpers.enrich_message(message)
      last = socket.assigns.last_message

      grouped = MessageGrouping.should_group?(message, last)
      {show_divider, divider_label} = MessageGrouping.divider_info(message, last)

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
        |> Helpers.maybe_mark_as_read(message)

      {:noreply, socket}
    else
      {:noreply, Helpers.increment_unread_count(socket, envelope)}
    end
  end

  @impl true
  def handle_info({:envelope, %{event: "message.edited", payload: payload} = envelope}, socket) do
    if Helpers.message_for_active_conversation?(envelope, socket) do
      updated_message = Helpers.apply_edit_to_stream(payload)
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
    if Helpers.message_for_active_conversation?(envelope, socket) do
      deleted_message = Helpers.apply_delete_to_stream(payload)

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
    if Helpers.message_for_active_conversation?(envelope, socket) do
      reactions = socket.assigns.reactions
      msg_id = payload.message_id
      current = Map.get(reactions, msg_id, [])
      updated = Helpers.apply_reaction_update(current, payload)
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

    {target_id, target_type} =
      cond do
        socket.assigns.active_channel -> {socket.assigns.active_channel.id, :channel}
        socket.assigns.active_dm -> {socket.assigns.active_dm.id, :dm}
        true -> {nil, nil}
      end

    if target_id do
      case Messaging.send_reply(target_id, target_type, user.id, parent_id, content) do
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
    socket = Summary.cancel_summary_task(socket)

    {:noreply, assign(socket, show_summary_modal: false, summary_state: :idle, summary_text: "")}
  end

  @impl true
  def handle_info({:start_summary, range}, socket) do
    user = socket.assigns.current_user
    socket = Summary.cancel_summary_task(socket)

    since = Summary.time_range_to_datetime(range)
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
          Summary.stream_summary(summary_target, since, user.id, live_view_pid)
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
    {:noreply, Conversations.refresh_channels_and_navigate(socket, channel)}
  end

  @impl true
  def handle_info({:channel_joined, channel}, socket) do
    {:noreply, Conversations.refresh_channels_and_navigate(socket, channel)}
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
        {:noreply, put_flash(socket, :error, Helpers.dm_request_error_message(reason))}
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
      |> Helpers.maybe_refresh_profile_card(updated_user)
      |> Helpers.maybe_refresh_current_user(updated_user)
      |> Helpers.refresh_dm_conversations_for_profile(updated_user)

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
    case {Helpers.to_integer(channel_id), Helpers.to_integer(dm_id)} do
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

  defp track_feature(socket, feature, metadata) do
    user = socket.assigns.current_user

    _ =
      Slackex.Analytics.track(
        %{
          user_id: user.id,
          session_id: socket.assigns[:analytics_session_id],
          user: user
        },
        "feature_used",
        Map.put(metadata, :feature, feature)
      )
  end
end
