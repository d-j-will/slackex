defmodule SlackexWeb.SousLive.FacetDrawerComponent do
  @moduledoc """
  The Facet Drawer — same atom rendered through each viewer's prism.

  B1 contract: 4-pill attention selector; click sets attention via `:triage_attention`.
  B2 additions:
    * Renders one of five pill states per viewer (`:never_generated`, `:generating`,
      `:stale`, `:fresh`, `:failed`) derived from `facet_rows`, `enqueued`, and
      `failed` MapSets (plus `LLMClient.configured?/0` gate).
    * Renders the AI facet text below the attention pills when present.
    * `↻ retry` glyph in `:failed` state — the **only** B2 user gesture that
      enqueues a worker (`phx-click="retry_facet"`). Handled by parent.

  Side effects (subscribe, enqueue) live in the parent LiveView, not here —
  `update/2` is called on every parent re-render. The component is pure render +
  attention/retry click handlers that bubble via `send(self(), ...)`.

  Three dismiss mechanisms (backdrop, Escape, X) preserved per project convention.
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

  # Retry bubbles to the parent's handle_event("retry_facet", ...) via root LV
  # because phx-target={@myself} would keep it here. We forward by pushing the
  # event on self() — the parent has the enqueue helpers + Oban access.
  def handle_event("retry_facet", %{"viewer_id" => viewer_id}, socket) do
    send(self(), {:retry_facet, viewer_id})
    {:noreply, socket}
  end

  defp attention_pill_class(true, _value), do: "btn-primary"
  defp attention_pill_class(false, _value), do: "btn-ghost"

  defp current_attention(facet_rows, viewer_id) do
    case Map.get(facet_rows, viewer_id) do
      nil -> :watch
      %WorkItemFacet{attention: nil} -> :watch
      %WorkItemFacet{attention: a} -> a
    end
  end

  defp pill_state(assigns, viewer_id) do
    cond do
      not assigns.llm_configured? ->
        :not_configured

      MapSet.member?(assigns.failed, viewer_id) ->
        :failed

      MapSet.member?(assigns.enqueued, viewer_id) ->
        :generating

      true ->
        row = Map.get(assigns.facet_rows, viewer_id)
        WorkItemFacet.state(row, MapSet.new(), viewer_id)
    end
  end

  defp facet_text_for(facet_rows, viewer_id) do
    case Map.get(facet_rows, viewer_id) do
      %WorkItemFacet{facet_text: t} when is_binary(t) -> t
      _ -> nil
    end
  end

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
              <% current = current_attention(@facet_rows, v.id) %>
              <% current =
                if Map.has_key?(@facets, v.id), do: Map.get(@facets, v.id, current), else: current %>
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

            <%= case pill_state(assigns, v.id) do %>
              <% :not_configured -> %>
                <p
                  class="mt-2 text-xs text-base-content/50 italic"
                  data-facet-state="not_configured"
                  data-prism-text={v.id}
                >
                  AI text unavailable
                </p>
              <% :never_generated -> %>
                <p
                  class="mt-2 text-xs text-base-content/40 italic"
                  data-facet-state="never_generated"
                  data-prism-text={v.id}
                >
                  …
                </p>
              <% :generating -> %>
                <p
                  class="mt-2 text-xs text-base-content/60 italic"
                  data-facet-state="generating"
                  data-prism-text={v.id}
                >
                  generating…
                </p>
              <% :stale -> %>
                <div
                  class="mt-2 text-xs text-base-content/70 opacity-70"
                  data-facet-state="stale"
                  data-prism-text={v.id}
                >
                  <p>{facet_text_for(@facet_rows, v.id) || "…"}</p>
                  <p class="text-[10px] text-base-content/40 mt-0.5">may be out of date</p>
                </div>
              <% :fresh -> %>
                <p
                  class="mt-2 text-xs text-base-content/80"
                  data-facet-state="fresh"
                  data-prism-text={v.id}
                >
                  {facet_text_for(@facet_rows, v.id)}
                </p>
              <% :failed -> %>
                <div
                  class="mt-2 text-xs text-base-content/60 flex items-center gap-2"
                  data-facet-state="failed"
                  data-prism-text={v.id}
                >
                  <span>generation failed</span>
                  <button
                    type="button"
                    phx-click="retry_facet"
                    phx-value-viewer_id={v.id}
                    phx-target={@myself}
                    class="btn btn-xs btn-ghost"
                    aria-label="Retry"
                  >
                    ↻ retry
                  </button>
                </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
