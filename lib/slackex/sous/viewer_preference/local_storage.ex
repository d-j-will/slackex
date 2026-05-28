defmodule Slackex.Sous.ViewerPreference.LocalStorage do
  @moduledoc """
  B1 default `ViewerPreference.Store` — state lives in the browser's
  localStorage via the `assets/js/hooks/viewer_prefs.js` hook.

    * `load/1` — assigns the default viewer (`nil`). The JS hook fires
      `"viewer_pref:loaded"` with the stored slug shortly after connect;
      `SlackexWeb.SousLive.InService` handles that event.
    * `save/2` — updates the assign AND pushes `"viewer_pref:save"` to the JS
      hook so localStorage is updated.
  """

  @behaviour Slackex.Sous.ViewerPreference.Store

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @impl true
  def load(socket) do
    assign(socket, :active_viewer_id, Slackex.Sous.ViewerPreference.default_viewer_id())
  end

  @impl true
  def save(socket, viewer_id) do
    socket
    |> assign(:active_viewer_id, viewer_id)
    |> push_event("viewer_pref:save", %{viewer_id: viewer_id})
  end
end
