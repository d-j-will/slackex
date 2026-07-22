defmodule SlackexWeb.AndonController do
  @moduledoc """
  Inbound half of the relay contract's outbound-push seam: the andon service
  POSTs presentation commands (`notify_backup`, `update_mirror`) here when a
  clock breaches or channel state changes.

  Authentication deviates from the token-in-URL webhook convention, and does so
  deliberately: the service's `Outbound.HTTP` sends `authorization: Bearer
  <token>` (`auth: {:bearer, token}`), so this endpoint authenticates by
  comparing that header against `ANDON_RELAY_TOKEN` with a constant-time
  compare. It fails closed when the token is unconfigured — dark-ship means no
  ambient open door.
  """
  use SlackexWeb, :controller

  alias Slackex.Andon

  require Logger

  def command(conn, params) do
    with :ok <- check_feature_flag(),
         :ok <- authenticate(conn) do
      _ = Andon.apply_command(params)
      json(conn, %{ok: true})
    else
      {:error, :feature_disabled} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  defp check_feature_flag do
    if FunWithFlags.enabled?(:andon_relay), do: :ok, else: {:error, :feature_disabled}
  end

  defp authenticate(conn) do
    with token when is_binary(token) and token != "" <- configured_token(),
         [presented] <- get_req_header(conn, "authorization"),
         "Bearer " <> presented_token <- presented,
         true <- Plug.Crypto.secure_compare(presented_token, token) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp configured_token do
    Application.get_env(:slackex, :andon_service, [])[:token]
  end
end
