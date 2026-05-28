defmodule Slackex.Sous.ViewerPreference do
  @moduledoc """
  The encapsulated viewer-preference seam (Slice B1 invariant #10).

  ALL viewer-preference reads/writes go through this module; LiveViews and
  components never call the underlying store directly. A future swap to a
  DB-backed store is a one-line config change — the LocalStorage default and
  the InMemoryStore (test-only) both implement
  `Slackex.Sous.ViewerPreference.Store`.

  Config:

      config :slackex, :viewer_preference_store,
        Slackex.Sous.ViewerPreference.LocalStorage
  """

  @doc "The viewer assigned to the socket before the client has loaded a preference."
  def default_viewer_id, do: nil

  @doc "Backend-specific load (called from LiveView mount)."
  def load(socket), do: store().load(socket)

  @doc "Set the active viewer; persists via the configured store. `viewer_id` may be nil (the null lens)."
  def put(socket, viewer_id) when is_binary(viewer_id) or is_nil(viewer_id) do
    store().save(socket, viewer_id)
  end

  defp store do
    Application.get_env(
      :slackex,
      :viewer_preference_store,
      Slackex.Sous.ViewerPreference.LocalStorage
    )
  end
end
