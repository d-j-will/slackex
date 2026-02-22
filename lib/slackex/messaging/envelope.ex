defmodule Slackex.Messaging.Envelope do
  @moduledoc """
  Versioned envelope for all client-visible realtime payloads.

  Ensures web and mobile clients share a single wire protocol. All PubSub
  broadcasts for user-facing events must be wrapped using this module.
  """

  @version 1

  @doc """
  Wraps an event into a versioned envelope.

  ## Parameters

  - `event` — event name string (e.g. `"message.new"`, `"typing"`, `"presence.diff"`)
  - `target` — `{:channel, id}` or `{:dm, id}` tuple
  - `payload` — event-specific data map
  - `opts` — optional keyword list; supports `correlation_id: String.t()`
  """
  @spec wrap(String.t(), {:channel | :dm, integer()}, map(), keyword()) :: map()
  def wrap(event, {type, id}, payload, opts \\ []) do
    %{
      v: @version,
      event: event,
      target: %{type: type, id: id},
      payload: payload,
      meta: %{
        sent_at: DateTime.utc_now(),
        correlation_id: Keyword.get(opts, :correlation_id)
      }
    }
  end

  @doc """
  Extracts event, target, and payload from an envelope for pattern matching.

  Returns `{event, target, payload}`.
  """
  @spec unwrap(map()) :: {String.t(), map(), map()}
  def unwrap(%{event: event, target: target, payload: payload}) do
    {event, target, payload}
  end
end
