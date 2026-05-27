defmodule SlackexWeb.AnalyticsTracker do
  @moduledoc "LiveView on_mount hook that tracks navigation events within a LiveView session."

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Slackex.Notifications.ActiveTracker

  def on_mount(:default, _params, session, socket) do
    socket =
      if FunWithFlags.enabled?(:website_analytics) and connected?(socket) do
        mount_start = System.monotonic_time(:millisecond)
        session_id = session["analytics_session_id"]
        user = socket.assigns[:current_user]

        socket =
          socket
          |> assign(:analytics_session_id, session_id)
          |> assign(:analytics_mount_start, mount_start)
          |> attach_hook(:analytics_handle_params, :handle_params, fn _params, uri, socket ->
            _ =
              try do
                track_navigation(socket, uri)
              rescue
                _ -> :ok
              end

            {:cont, socket}
          end)

        _ =
          try do
            track_mount(socket, user, session_id, mount_start)
          rescue
            _ -> :ok
          end

        socket
      else
        socket
      end

    # The :chat layout mounts shared JS hooks (Analytics, AppBadge) that push
    # `analytics:*` and `page:*` events to EVERY LiveView in this session. Handle
    # them once here so individual LiveViews don't each reimplement them. Events
    # this hook doesn't recognize fall through with `:cont` and still reach (and
    # raise in) the target LiveView — no silent swallow.
    socket =
      if connected?(socket) do
        attach_hook(socket, :chrome_handle_event, :handle_event, &handle_chrome_event/3)
      else
        socket
      end

    {:cont, socket}
  end

  defp handle_chrome_event("analytics:" <> event_type, params, socket) do
    user = socket.assigns.current_user

    context = %{
      user_id: user.id,
      session_id: socket.assigns[:analytics_session_id],
      is_bot: Map.get(user, :is_bot, false),
      user: user
    }

    metadata = Map.drop(params, ["_target"])
    _ = Slackex.Analytics.track(context, event_type, metadata)

    {:halt, socket}
  end

  defp handle_chrome_event("page:visible", _params, socket) do
    ActiveTracker.mark_active(socket.assigns.current_user.id)
    {:halt, assign(socket, :page_visible, true)}
  end

  defp handle_chrome_event("page:hidden", _params, socket) do
    ActiveTracker.mark_inactive(socket.assigns.current_user.id)
    {:halt, assign(socket, :page_visible, false)}
  end

  defp handle_chrome_event(_event, _params, socket), do: {:cont, socket}

  defp track_mount(socket, user, session_id, mount_start) do
    duration_ms = System.monotonic_time(:millisecond) - mount_start
    is_bot = if user, do: Map.get(user, :is_bot, false), else: false

    context = %{
      user_id: if(user, do: user.id),
      session_id: session_id,
      is_bot: is_bot,
      user: user
    }

    Slackex.Analytics.track(context, "page_view", %{
      path: socket.assigns[:current_path] || "/",
      live_action: to_string(socket.assigns[:live_action] || :index),
      duration_ms: duration_ms,
      is_reconnect: false
    })
  end

  defp track_navigation(socket, uri) do
    user = socket.assigns[:current_user]
    is_bot = if user, do: Map.get(user, :is_bot, false), else: false
    path = URI.parse(uri).path

    context = %{
      user_id: if(user, do: user.id),
      session_id: socket.assigns[:analytics_session_id],
      is_bot: is_bot,
      user: user
    }

    Slackex.Analytics.track(context, "page_view", %{
      path: path,
      live_action: to_string(socket.assigns[:live_action] || :unknown),
      is_reconnect: false
    })
  end
end
