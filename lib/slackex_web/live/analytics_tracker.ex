defmodule SlackexWeb.AnalyticsTracker do
  @moduledoc "LiveView on_mount hook that tracks navigation events within a LiveView session."

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    if FunWithFlags.enabled?(:website_analytics) and connected?(socket) do
      mount_start = System.monotonic_time(:millisecond)
      session_id = session["analytics_session_id"]
      user = socket.assigns[:current_user]

      socket =
        socket
        |> assign(:analytics_session_id, session_id)
        |> assign(:analytics_mount_start, mount_start)
        |> attach_hook(:analytics_handle_params, :handle_params, fn _params, uri, socket ->
          _ = track_navigation(socket, uri)
          {:cont, socket}
        end)

      _ = track_mount(socket, user, session_id, mount_start)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

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
