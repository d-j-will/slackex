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
    if is_nil(Application.get_env(:web_push_elixir, :vapid_public_key)) do
      Logger.warning("[WebPush] VAPID keys not configured — skipping push")
      {:error, :vapid_not_configured}
    else
      do_send_push(token, payload)
    end
  end

  defp pusher, do: Application.get_env(:slackex, :web_push_elixir_module, WebPushElixir)

  defp do_send_push(token, payload) do
    json_payload = build_payload(payload)

    case pusher().send_notification(token, json_payload) do
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
