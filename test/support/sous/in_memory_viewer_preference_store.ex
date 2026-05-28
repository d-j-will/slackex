defmodule Slackex.Sous.ViewerPreference.InMemoryStore do
  @moduledoc """
  Test-only `ViewerPreference.Store` — assigns only, no JS hook, no DB.
  Used by `viewer_preference_seam_test.exs` to prove the encapsulation seam
  (Slice B1 invariant #10).
  """

  @behaviour Slackex.Sous.ViewerPreference.Store

  import Phoenix.Component, only: [assign: 3]

  @impl true
  def load(socket) do
    assign(socket, :active_viewer_id, Slackex.Sous.ViewerPreference.default_viewer_id())
  end

  @impl true
  def save(socket, viewer_id), do: assign(socket, :active_viewer_id, viewer_id)
end
