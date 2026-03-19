defmodule SlackexWeb.WebhookController do
  @moduledoc """
  Handles incoming webhook deliveries. External services POST JSON payloads
  with a `text` field to `/api/webhooks/:token`, which are delivered as
  messages to the webhook's target channel via the Messaging pipeline.

  Authentication is token-in-URL (no session/Guardian). The raw token is
  hashed and looked up against stored webhook records.
  """

  use SlackexWeb, :controller

  alias Slackex.Chat
  alias Slackex.Integrations.Webhooks
  alias Slackex.Messaging

  require Logger

  @max_payload_bytes 16_384

  def deliver(conn, %{"token" => token}) do
    with :ok <- check_feature_flag(),
         :ok <- check_payload_size(conn),
         {:ok, text} <- validate_payload(conn.body_params),
         {:ok, webhook} <- lookup_webhook(token),
         :ok <- check_channel_exists(webhook),
         {:ok, _message} <- deliver_message(webhook, text) do
      json(conn, %{ok: true})
    else
      {:error, :feature_disabled} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :payload_too_large} ->
        conn
        |> put_status(413)
        |> json(%{error: "payload_too_large", message: "payload must be under 16KB"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "invalid_payload",
          message: "text field is required and must be non-empty"
        })

      {:error, :not_found} ->
        conn |> put_status(401) |> json(%{error: "invalid_token"})

      {:error, :channel_deleted} ->
        conn |> put_status(404) |> json(%{error: "channel_not_found"})

      {:error, reason} ->
        Logger.error("Webhook delivery failed: #{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: "internal_error"})
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp check_feature_flag do
    if FunWithFlags.enabled?(:incoming_webhooks) do
      :ok
    else
      {:error, :feature_disabled}
    end
  end

  defp check_payload_size(conn) do
    case get_req_header(conn, "content-length") do
      [length_str] when byte_size(length_str) > 0 ->
        if String.to_integer(length_str) > @max_payload_bytes do
          {:error, :payload_too_large}
        else
          :ok
        end

      _ ->
        # No content-length header -- rely on Plug.Parsers global limit
        :ok
    end
  end

  defp validate_payload(%{"text" => text}) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, :invalid_payload}
    else
      {:ok, trimmed}
    end
  end

  defp validate_payload(_body_params), do: {:error, :invalid_payload}

  defp lookup_webhook(token) do
    token_hash = Webhooks.hash_token(token)

    case Webhooks.get_by_token_hash(token_hash) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  defp check_channel_exists(%{channel_id: channel_id}) do
    case Slackex.Repo.get(Chat.Channel, channel_id) do
      nil -> {:error, :channel_deleted}
      _channel -> :ok
    end
  end

  defp deliver_message(webhook, text) do
    Messaging.send_message(webhook.channel_id, webhook.bot_user_id, text)
  end
end
