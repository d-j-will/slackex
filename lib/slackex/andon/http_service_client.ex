defmodule Slackex.Andon.HTTPServiceClient do
  @moduledoc """
  Req implementation of the relay→service seam: a bearer-authed JSON POST to
  `{ANDON_SERVICE_URL}/relay/v1/events`. `retry: false` — the service is
  idempotent on `event_id`, so retries are the caller's decision, not Req's.

  Missing config is not a crash: the feature is flag-gated and dark-shipped, so
  an unconfigured service just logs and no-ops (`{:error, :not_configured}`).
  """
  @behaviour Slackex.Andon.ServiceClient

  require Logger

  @impl true
  def post_event(event) do
    config = Application.get_env(:slackex, :andon_service, [])

    case Keyword.get(config, :url) do
      nil ->
        Logger.warning(
          "andon relay: no :andon_service url configured; dropping #{event["event"]}"
        )

        {:error, :not_configured}

      url ->
        post(url, event, config)
    end
  end

  defp post(url, event, config) do
    token = Keyword.get(config, :token)
    req_options = Keyword.get(config, :req_options, [])

    endpoint = String.trim_trailing(url, "/") <> "/relay/v1/events"

    case Req.post(
           endpoint,
           [json: event, auth: {:bearer, token}, retry: false, decode_json: [keys: :strings]] ++
             req_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: normalize_body(body)}}

      {:error, reason} ->
        Logger.warning("andon relay: post_event failed: #{inspect(reason)} for #{event["event"]}")
        {:error, reason}
    end
  end

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(_body), do: %{}
end
