defmodule Slackex.Notifications.WebPushAdapter do
  @moduledoc """
  Web Push adapter using web_push_elixir and VAPID.
  Implements send_push/3 matching the push adapter interface.
  """

  require Logger

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  @spec send_push(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def send_push(token, _platform, payload) do
    json_payload = build_payload(payload)

    case WebPushElixir.send_notification(token, json_payload) do
      {:ok, _response} ->
        :ok

      {:error, :expired} ->
        Logger.info("[WebPush] Subscription expired, cleaning up token")
        cleanup_expired_token(token)
        :ok

      {:error, {:http_error, status, body}} ->
        Logger.warning("[WebPush] Push failed with HTTP #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}
    end
  end

  @doc "Build the JSON payload string from a map."
  def build_payload(payload) do
    Jason.encode!(%{
      "title" => payload["title"],
      "body" => payload["body"],
      "tag" => payload["tag"],
      "url" => payload["url"],
      "type" => payload["type"]
    })
  end

  defp cleanup_expired_token(token) do
    case Repo.get_by(DeviceToken, token: token) do
      nil -> :ok
      device_token -> Repo.delete(device_token)
    end
  rescue
    e ->
      Logger.warning("[WebPush] Failed to cleanup expired token: #{inspect(e)}")
      :ok
  end
end
