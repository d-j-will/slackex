defmodule Slackex.Analytics.MetricsBridge do
  @moduledoc """
  Oban cron job that queries analytics aggregates and emits them as
  telemetry events for Prometheus scraping. Uses Oban unique constraint
  to ensure single-node execution in multi-node deploys.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 1, unique: [period: 55]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if FunWithFlags.enabled?(:website_analytics) do
      emit_page_view_metrics()
      emit_error_metrics()
      emit_feature_usage_metrics()
      emit_active_user_metrics()
    end

    :ok
  end

  defp emit_page_view_metrics do
    Slackex.Analytics.page_views(period: :last_24_hours)
    |> Enum.each(fn %{path: path, count: count} ->
      :telemetry.execute([:tenun, :analytics, :page_views], %{count: count}, %{path: path})
    end)
  end

  defp emit_error_metrics do
    Enum.each(~w(js_error server_error oban_error), fn category ->
      count =
        Slackex.Analytics.errors(period: :last_24_hours, category: category)
        |> Enum.map(& &1.count)
        |> Enum.sum()

      :telemetry.execute([:tenun, :analytics, :errors], %{count: count}, %{category: category})
    end)
  end

  defp emit_feature_usage_metrics do
    Slackex.Analytics.feature_usage(period: :last_24_hours)
    |> Enum.each(fn %{feature: feature, count: count} ->
      :telemetry.execute([:tenun, :analytics, :feature_usage], %{count: count}, %{
        feature: feature
      })
    end)
  end

  defp emit_active_user_metrics do
    count = Slackex.Analytics.active_user_count(period: :last_24_hours)
    :telemetry.execute([:tenun, :analytics, :active_users], %{count: count}, %{})
  end
end
