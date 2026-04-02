defmodule Slackex.Notifications.SubscriptionCleanupWorker do
  @moduledoc "Monthly Oban cron that probes web_push tokens and removes expired ones."

  use Oban.Worker, queue: :notifications, max_attempts: 1

  import Ecto.Query
  require Logger

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Notifications.WebPushAdapter
  alias Slackex.Repo

  @sample_percentage 0.1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if FunWithFlags.enabled?(:push_notifications) do
      probe_sampled_tokens()
    end

    :ok
  end

  defp probe_sampled_tokens do
    tokens =
      DeviceToken
      |> where([t], t.platform == "web_push")
      |> Repo.all()

    sample_size = max(1, round(length(tokens) * @sample_percentage))
    sampled = Enum.take_random(tokens, sample_size)
    expired_count = Enum.count(sampled, &token_expired?/1)

    if expired_count > 0 do
      Logger.info(
        "SubscriptionCleanup: #{expired_count}/#{length(sampled)} sampled tokens were expired"
      )
    end
  end

  defp token_expired?(token) do
    case WebPushAdapter.send_push(token.token, "web_push", %{
           "title" => "",
           "body" => "",
           "tag" => "cleanup-probe",
           "url" => "/",
           "type" => "probe"
         }) do
      :ok -> false
      {:error, _} -> true
    end
  end
end
