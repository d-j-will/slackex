defmodule SlackexWeb.ChatLive.ChatShell do
  @moduledoc """
  Builds the chat shell for `ChatLive.Index`.

  The shell owns sidebar data, unread state, feature-gated controls, default
  assigns, and reconnect catchup. `mount/3` remains a thin adapter over this
  seam.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 3]

  alias Slackex.Accounts.User
  alias Slackex.Chat
  alias Slackex.Notifications.CatchupServer
  alias Slackex.Notifications.OnlineTracker
  alias Slackex.Notifications.Preference
  alias SlackexWeb.ChatLive.Catchup
  alias SlackexWeb.ChatLive.Helpers

  @catchup_warning "Couldn't fully restore unread state after reconnect."

  @type mode :: :first_mount | :reconnect

  defstruct [
    :user,
    :channels,
    :dm_conversations,
    :dm_requests,
    :unread_counts,
    :online_user_ids,
    :catchup_summary,
    :runtime_plan,
    :loom,
    :search_enabled,
    :summarization_enabled,
    :push_notifications_enabled,
    :notification_level
  ]

  @type t :: %__MODULE__{
          user: User.t(),
          channels: list(),
          dm_conversations: list(),
          dm_requests: list(),
          unread_counts: map(),
          online_user_ids: MapSet.t(),
          catchup_summary: String.t() | nil,
          runtime_plan: %{channel_ids: [integer()], dm_ids: [integer()]},
          loom: boolean(),
          search_enabled: boolean(),
          summarization_enabled: boolean(),
          push_notifications_enabled: boolean(),
          notification_level: String.t()
        }

  @spec seed(User.t()) :: t()
  def seed(%User{} = user) do
    channels = Chat.list_user_channels(user.id)
    dm_conversations = Chat.list_user_dm_conversations(user.id)
    dm_requests = Chat.list_pending_requests_for_user(user.id)
    push_notifications_enabled = FunWithFlags.enabled?(:push_notifications)

    %__MODULE__{
      user: user,
      channels: channels,
      dm_conversations: dm_conversations,
      dm_requests: dm_requests,
      unread_counts: %{channel_counts: %{}, dm_counts: %{}},
      online_user_ids: MapSet.new(),
      catchup_summary: nil,
      runtime_plan: runtime_plan(channels, dm_conversations),
      loom: FunWithFlags.enabled?(:loom_redesign, for: user),
      search_enabled: FunWithFlags.enabled?(:message_search),
      summarization_enabled: FunWithFlags.enabled?(:channel_summarization),
      push_notifications_enabled: push_notifications_enabled,
      notification_level: notification_level(user.id, push_notifications_enabled)
    }
  end

  @spec run(User.t(), keyword()) :: {:ok, t()} | {:degraded, t(), [String.t()]}
  def run(%User{} = user, opts \\ []) do
    seed(user)
    |> hydrate_shell(
      Keyword.get(opts, :connected?, false),
      Keyword.get(opts, :mode, :first_mount),
      reload_lists?: false
    )
  end

  @spec mount_mode(boolean(), map() | nil) :: mode()
  def mount_mode(false, _connect_params), do: :first_mount

  def mount_mode(true, %{"_mounts" => mounts}) when mounts not in [0, "0", nil] do
    :reconnect
  end

  def mount_mode(true, _connect_params), do: :first_mount

  @spec refresh_connected_state(t(), mode()) :: {:ok, t()} | {:degraded, t(), [String.t()]}
  def refresh_connected_state(%__MODULE__{} = shell, mode) do
    hydrate_shell(shell, true, mode, reload_lists?: false)
  end

  @spec assign(Phoenix.LiveView.Socket.t(), t()) :: Phoenix.LiveView.Socket.t()
  def assign(socket, %__MODULE__{} = shell) do
    socket
    |> assign_shell_defaults(shell)
    |> stream(:messages, [])
    |> maybe_put_catchup_flash(shell.catchup_summary)
  end

  @spec put_warnings(Phoenix.LiveView.Socket.t(), [String.t()]) :: Phoenix.LiveView.Socket.t()
  def put_warnings(socket, warnings) do
    Enum.reduce(warnings, socket, fn warning, acc ->
      put_flash(acc, :error, warning)
    end)
  end

  defp build_unread_state(user_id, true, mode, base_unread_counts) do
    case FunWithFlags.enabled?(:catchup_on_reconnect) do
      true -> merge_catchup_unread(user_id, mode, base_unread_counts)
      false -> {base_unread_counts, nil, []}
    end
  end

  defp build_unread_state(_user_id, false, _mode, base_unread_counts) do
    {base_unread_counts, nil, []}
  end

  defp merge_catchup_unread(user_id, mode, base_unread_counts) do
    case CatchupServer.safe_build_catchup(user_id) do
      {:ok, catchup} ->
        {
          Catchup.merge_unread(base_unread_counts, catchup),
          catchup_summary(mode, catchup),
          []
        }

      {:error, _reason} ->
        {base_unread_counts, nil, [@catchup_warning]}
    end
  end

  defp catchup_summary(:reconnect, catchup), do: Catchup.summary(catchup)
  defp catchup_summary(:first_mount, _catchup), do: nil

  defp online_user_ids(dm_conversations, true) do
    dm_conversations
    |> Enum.map(& &1.other_user.id)
    |> OnlineTracker.online_user_ids()
  end

  defp online_user_ids(_dm_conversations, false), do: MapSet.new()

  defp notification_level(user_id, true), do: Preference.resolve_level(user_id, nil)
  defp notification_level(_user_id, false), do: "all"

  defp hydrate_shell(shell, connected?, mode, opts) do
    {channels, dm_conversations, dm_requests} =
      if Keyword.get(opts, :reload_lists?, false) do
        load_shell_lists(shell.user.id)
      else
        {shell.channels, shell.dm_conversations, shell.dm_requests}
      end

    {unread_counts, catchup_summary, warnings} =
      build_unread_state(shell.user.id, connected?, mode, Chat.batch_unread_counts(shell.user.id))

    hydrated_shell = %{
      shell
      | channels: channels,
        dm_conversations: dm_conversations,
        dm_requests: dm_requests,
        unread_counts: unread_counts,
        online_user_ids: online_user_ids(dm_conversations, connected?),
        catchup_summary: catchup_summary,
        runtime_plan: runtime_plan(channels, dm_conversations)
    }

    case warnings do
      [] -> {:ok, hydrated_shell}
      _ -> {:degraded, hydrated_shell, warnings}
    end
  end

  defp load_shell_lists(user_id) do
    {
      Chat.list_user_channels(user_id),
      Chat.list_user_dm_conversations(user_id),
      Chat.list_pending_requests_for_user(user_id)
    }
  end

  defp runtime_plan(channels, dm_conversations) do
    %{
      channel_ids: Enum.map(channels, & &1.id),
      dm_ids: Enum.map(dm_conversations, & &1.id)
    }
  end

  defp assign_shell_defaults(socket, shell) do
    Enum.reduce(initial_assigns(shell), socket, fn {key, value}, acc ->
      assign(acc, key, value)
    end)
  end

  defp initial_assigns(shell) do
    [
      channels: shell.channels,
      dm_conversations: shell.dm_conversations,
      dm_requests: shell.dm_requests,
      dm_request_count: length(shell.dm_requests),
      unread_counts: shell.unread_counts,
      online_user_ids: shell.online_user_ids,
      active_channel: nil,
      active_dm: nil,
      can_send: false,
      user_role: nil,
      typing_users: MapSet.new(),
      message_form: to_form(%{"content" => ""}, as: :message),
      sidebar_open: true,
      oldest_message_id: nil,
      has_more_messages: false,
      show_report_modal: false,
      report_message_id: nil,
      report_form: to_form(%{}, as: :report),
      profile_user: nil,
      show_edit_profile: false,
      show_push_explainer: false,
      edit_profile_form: Helpers.build_profile_form(shell.user),
      editing_message_id: nil,
      reactions: %{},
      thread_parent: nil,
      member_count: 0,
      pin_count: 0,
      show_quick_switcher: false,
      show_appearance: false,
      loom: shell.loom,
      search_open: false,
      search_enabled: shell.search_enabled,
      summarization_enabled: shell.summarization_enabled,
      link_previews: %{},
      show_summary_modal: false,
      show_decide: false,
      card_messages: %{},
      summary_text: "",
      summary_state: :idle,
      summary_error: nil,
      active_summary_task: nil,
      last_message: nil,
      push_notifications_enabled: shell.push_notifications_enabled,
      push_permission: "default",
      push_subscribed: false,
      push_health: :not_set_up,
      notification_level: shell.notification_level,
      channel_notification_level: "all",
      page_visible: true
    ]
  end

  defp maybe_put_catchup_flash(socket, nil), do: socket
  defp maybe_put_catchup_flash(socket, msg), do: put_flash(socket, :info, msg)
end
