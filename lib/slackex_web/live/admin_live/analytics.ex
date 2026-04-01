defmodule SlackexWeb.AdminLive.Analytics do
  use SlackexWeb, :live_view

  alias Slackex.Analytics

  @tabs [
    {:overview, "Overview", "/admin/analytics"},
    {:hotspots, "Hotspots", "/admin/analytics/hotspots"},
    {:errors, "Errors", "/admin/analytics/errors"},
    {:features, "Features", "/admin/analytics/features"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    enabled = FunWithFlags.enabled?(:website_analytics)

    socket =
      socket
      |> assign(:enabled, enabled)
      |> assign(:tabs, @tabs)
      |> assign(:period, :last_7_days)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_tab_data(socket)}
  end

  @impl true
  def handle_event("change_period", %{"period" => period}, socket) do
    period = String.to_existing_atom(period)
    socket = socket |> assign(:period, period) |> load_tab_data()
    {:noreply, socket}
  end

  defp load_tab_data(%{assigns: %{enabled: false}} = socket) do
    socket
  end

  defp load_tab_data(%{assigns: %{live_action: :overview, period: period}} = socket) do
    socket
    |> assign(:active_today, Analytics.active_user_count(period: :last_24_hours))
    |> assign(:active_7d, Analytics.active_user_count(period: :last_7_days))
    |> assign(:active_30d, Analytics.active_user_count(period: :last_30_days))
    |> assign(:page_views, Analytics.page_views(period: period) |> Enum.take(10))
    |> assign(
      :error_count,
      Analytics.errors(period: period) |> Enum.map(& &1.count) |> Enum.sum()
    )
    |> assign(:top_features, Analytics.feature_usage(period: period) |> Enum.take(10))
  end

  defp load_tab_data(%{assigns: %{live_action: :hotspots, period: period}} = socket) do
    assign(socket, :hotspots, Analytics.hotspots(period: period))
  end

  defp load_tab_data(%{assigns: %{live_action: :errors, period: period}} = socket) do
    assign(socket, :errors_list, Analytics.errors(period: period))
  end

  defp load_tab_data(%{assigns: %{live_action: :features, period: period}} = socket) do
    assign(socket, :features, Analytics.feature_usage(period: period))
  end
end
