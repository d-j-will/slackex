defmodule Slackex.Andon.StubServiceClient do
  @moduledoc """
  Deterministic test double for the relay→service seam. Forwards every posted
  event to a configured test pid (`:andon_service_test_pid`) as
  `{:andon_event_posted, event}`, and returns a configured response.

  The response (`:andon_service_stub_response`) is either a literal
  `{:ok, %{status:, body:}}` / `{:error, term}`, or a 1-arity function of the
  event returning the same. The default is a bare `201` with no commands, so a
  test only overrides it when it cares about the commands or an error path.
  """
  @behaviour Slackex.Andon.ServiceClient

  @impl true
  def post_event(event) do
    if pid = Application.get_env(:slackex, :andon_service_test_pid) do
      send(pid, {:andon_event_posted, event})
    end

    case Application.get_env(:slackex, :andon_service_stub_response, :default) do
      :default -> {:ok, %{status: 201, body: %{"data" => %{}, "commands" => []}}}
      fun when is_function(fun, 1) -> fun.(event)
      response -> response
    end
  end
end
