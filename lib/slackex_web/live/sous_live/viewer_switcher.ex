defmodule SlackexWeb.SousLive.ViewerSwitcher do
  @moduledoc """
  Top-bar "Reading as" switcher. Function component; the parent LiveView
  handles the `select_viewer` events and routes them through
  `Slackex.Sous.ViewerPreference.put/2`.

  A null option ("All / no lens") is the default until the user picks — the
  honest default per spec §3 + §7.1. With the null option active every card
  resolves to `:watch` and the board shows shared shape (identical to Slice A).
  """

  use Phoenix.Component

  attr :viewers, :list, required: true
  attr :active_viewer_id, :string, default: nil

  def viewer_switcher(assigns) do
    ~H"""
    <div class="flex items-center gap-2" aria-label="Reading as">
      <span class="text-sm text-base-content/60">Reading as:</span>

      <button
        type="button"
        phx-click="select_viewer"
        phx-value-id=""
        class={[
          "btn btn-xs",
          (@active_viewer_id == nil && "btn-primary") || "btn-ghost"
        ]}
        aria-pressed={@active_viewer_id == nil}
      >
        All
      </button>

      <button
        :for={v <- @viewers}
        type="button"
        phx-click="select_viewer"
        phx-value-id={v.id}
        class={[
          "btn btn-xs",
          (@active_viewer_id == v.id && "btn-primary") || "btn-ghost"
        ]}
        aria-pressed={@active_viewer_id == v.id}
      >
        <span style={"color: #{v.color}"} aria-hidden="true">●</span>
        {v.name}
      </button>
    </div>
    """
  end
end
