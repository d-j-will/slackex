defmodule SlackexWeb.SousLive.FacetDrawerComponent do
  @moduledoc """
  The Facet Drawer — same atom rendered through each viewer's prism. Triage
  in-place via a 4-pill selector (Slice B1 spec §7.3). The parent LiveView
  (`SlackexWeb.SousLive.InService`) controls visibility (open/close) and
  receives `triage_attention` events via `send(self(), {:triage_attention, params})`
  from this component, OR via `render_hook` from tests.

  Three dismiss mechanisms per project UI convention: backdrop click, Escape,
  and an explicit X button.
  """

  use SlackexWeb, :live_component

  alias Slackex.Sous.WorkItemFacet

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    send(self(), :close_facet_drawer)
    {:noreply, socket}
  end

  def handle_event("triage_attention", params, socket) do
    send(self(), {:triage_attention, params})
    {:noreply, socket}
  end

  defp attention_pill_class(true, _value), do: "btn-primary"
  defp attention_pill_class(false, _value), do: "btn-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="facet-drawer"
      phx-window-keydown="close_drawer"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_drawer"
        phx-target={@myself}
      />

      <div class="fixed inset-y-0 right-0 z-50 w-full sm:max-w-xl bg-base-100 shadow-xl flex flex-col">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h3 class="loom-modal-title font-bold text-lg">{@work_item.title}</h3>
          <button
            type="button"
            phx-click="close_drawer"
            phx-target={@myself}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Close"
          >
            <span class="hero-x-mark size-5" />
          </button>
        </div>

        <div class="p-4 space-y-2 border-b border-base-300 text-sm">
          <p>
            DRI: {@work_item.people["lead_name"] || "—"} · State: {@work_item.state}
          </p>
          <p :if={@work_item.decision}>
            <span class="font-medium">What:</span> {@work_item.decision.what}
          </p>
          <p :if={@work_item.decision && @work_item.decision.why not in [nil, ""]}>
            <span class="font-medium">Why:</span> {@work_item.decision.why}
          </p>
          <p :if={@work_item.decision && @work_item.decision.next not in [nil, ""]}>
            <span class="font-medium">Next:</span> {@work_item.decision.next}
          </p>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-3">
          <h4 class="text-sm uppercase tracking-wide text-base-content/60">Prisms</h4>
          <div
            :for={v <- @viewers}
            class="rounded-lg border border-base-300 p-3"
            data-prism={v.id}
          >
            <div class="flex items-center gap-2 mb-2">
              <span style={"color: #{v.color}"} aria-hidden="true">●</span>
              <span class="font-medium">{v.name}</span>
            </div>
            <div class="flex flex-wrap gap-1">
              <% current = Map.get(@facets, v.id, :watch) %>
              <button
                :for={a <- WorkItemFacet.attentions()}
                type="button"
                phx-click="triage_attention"
                phx-value-work_item_id={@work_item.id}
                phx-value-viewer_id={v.id}
                phx-value-attention={Atom.to_string(a)}
                phx-target={@myself}
                class={["btn btn-xs", attention_pill_class(current == a, a)]}
                aria-pressed={current == a}
              >
                {Atom.to_string(a)}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
