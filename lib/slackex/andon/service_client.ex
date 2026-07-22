defmodule Slackex.Andon.ServiceClient do
  @moduledoc """
  Behaviour + delegator for the relay→service seam (the outbound half of the
  relay contract, C1/C5). The relay POSTs domain events; the service replies
  with the minted identity/binding and any presentation `commands`.

  The seam is synchronous in the skeleton: `post_event/1` returns the full
  response (status + decoded body) so the caller can (a) execute `commands`
  only on `201 Created` — a `200` is an idempotent replay whose commands were
  already handled — and (b) surface a `4xx` error's message as an in-thread
  note. Network failure returns `{:error, reason}`; the listener logs and does
  not crash.

  The implementation is config-swapped, like `Slackex.AI.LLMClient`:

      config :slackex, :andon_service_client, Slackex.Andon.HTTPServiceClient
  """

  @type event :: map()
  @type response :: %{status: non_neg_integer(), body: map()}

  @callback post_event(event()) :: {:ok, response()} | {:error, term()}

  @doc "POSTs a domain event to the service. See the moduledoc for the contract."
  @spec post_event(event()) :: {:ok, response()} | {:error, term()}
  def post_event(event), do: client().post_event(event)

  defp client do
    Application.get_env(:slackex, :andon_service_client, Slackex.Andon.HTTPServiceClient)
  end
end
