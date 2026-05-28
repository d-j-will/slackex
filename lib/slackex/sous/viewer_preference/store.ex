defmodule Slackex.Sous.ViewerPreference.Store do
  @moduledoc """
  Behaviour for `Slackex.Sous.ViewerPreference` backends.

  Implementations:
    * `Slackex.Sous.ViewerPreference.LocalStorage` — B1 default, JS-hook backed.
    * `Slackex.Sous.ViewerPreference.InMemoryStore`  — test-only; proves the seam.
    * (Future) a DB-backed `Repo` store.

  The interface is deliberately tiny — invariant #10 keeps it from leaking into
  call sites, so swapping backends never reshuffles LiveView/component code.
  """

  @callback load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @callback save(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
end
