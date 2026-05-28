defmodule SlackexWeb.SousLive.InService do
  @moduledoc """
  In Service board (Slice B1).

  Behaviour change from Slice A (named explicitly per spec §7.2): per-column
  sort is `act > watch > know` then `inserted_at desc`. With the null default
  lens (no viewer picked) every card resolves to `:watch` and the sort falls
  back to pure recency — identical to Slice A. Reshaping is opt-in by picking
  a lens via the "Reading as" switcher.
  """
  use SlackexWeb, :live_view

  import Ecto.Query
  import SlackexWeb.SousLive.ViewerSwitcher

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{Viewer, WorkItemFacet}

  @columns [
    {:order, "Order"},
    {:mise, "Mise"},
    {:pass, "Pass"},
    {:walked, "Walked"}
  ]

  @attention_rank %{act: 0, watch: 1, know: 2, hidden: 3}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if FunWithFlags.enabled?(:sous, for: user) do
      _ =
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      viewers = Repo.all(Viewer.order_by_position())

      socket =
        socket
        |> assign(:loom, true)
        |> assign(:columns, @columns)
        |> assign(:viewers, viewers)
        |> assign(:grouped, Sous.list_in_flight())
        |> assign(:facet_map, %{})
        |> assign(:show_hidden, %{order: false, mise: false, pass: false, walked: false})
        |> assign(:drawer_work_item, nil)
        |> assign(:drawer_facets, %{})
        |> Slackex.Sous.ViewerPreference.load()

      {:ok, socket}
    else
      {:ok, socket |> put_flash(:error, "Not available.") |> redirect(to: ~p"/chat")}
    end
  end

  # ---------------------------------------------------------------------------
  # Switcher / hidden toggle
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_viewer", %{"id" => raw_id}, socket) do
    viewer_id = if raw_id == "", do: nil, else: raw_id

    socket =
      socket
      |> Slackex.Sous.ViewerPreference.put(viewer_id)
      |> assign(:facet_map, Sous.facets_for_viewer(viewer_id))

    {:noreply, socket}
  end

  def handle_event("viewer_pref:loaded", %{"viewer_id" => viewer_id}, socket) do
    # Bridge from the JS hook — same effect as a user click on the switcher.
    viewer_id = if viewer_id in [nil, ""], do: nil, else: viewer_id

    socket =
      socket
      |> Slackex.Sous.ViewerPreference.put(viewer_id)
      |> assign(:facet_map, Sous.facets_for_viewer(viewer_id))

    {:noreply, socket}
  end

  def handle_event("toggle_hidden", %{"column" => column}, socket) do
    col = String.to_existing_atom(column)

    {:noreply,
     Phoenix.Component.update(
       socket,
       :show_hidden,
       &Map.put(&1, col, not Map.get(&1, col, false))
     )}
  end

  # ---------------------------------------------------------------------------
  # Card moves (unchanged from Slice A) and drawer
  # ---------------------------------------------------------------------------

  def handle_event("move_work_item", %{"id" => id, "to" => to}, socket) do
    _ =
      Sous.move(
        String.to_integer(id),
        String.to_existing_atom(to),
        socket.assigns.current_user.id
      )

    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  def handle_event("open_drawer", %{"id" => id}, socket) do
    wi_id = String.to_integer(id)
    wi = find_work_item(socket, wi_id) |> Repo.preload(:decision)

    {:noreply,
     socket |> assign(:drawer_work_item, wi) |> assign(:drawer_facets, drawer_facets_for(wi_id))}
  end

  # Bridge for tests / future JS that push triage_attention to the LV root rather
  # than to the LiveComponent (mirror of the handle_info clause below).
  def handle_event(
        "triage_attention",
        %{"work_item_id" => wi_id, "viewer_id" => vid, "attention" => att},
        socket
      ) do
    _ =
      Sous.set_attention(
        String.to_integer(wi_id),
        vid,
        String.to_existing_atom(att),
        socket.assigns.current_user.id
      )

    socket =
      if drawer = socket.assigns.drawer_work_item do
        assign(socket, :drawer_facets, drawer_facets_for(drawer.id))
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Broadcasts
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:work_item_event, :attention_set, %{viewer_id: vid}}, socket) do
    socket =
      if socket.assigns.active_viewer_id == vid do
        assign(socket, :facet_map, Sous.facets_for_viewer(vid))
      else
        socket
      end

    socket =
      if drawer = socket.assigns.drawer_work_item do
        assign(socket, :drawer_facets, drawer_facets_for(drawer.id))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:work_item_event, _type, _wi}, socket) do
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  def handle_info(:close_facet_drawer, socket) do
    {:noreply, socket |> assign(:drawer_work_item, nil) |> assign(:drawer_facets, %{})}
  end

  def handle_info(
        {:triage_attention, %{"work_item_id" => wi_id, "viewer_id" => vid, "attention" => att}},
        socket
      ) do
    _ =
      Sous.set_attention(
        String.to_integer(wi_id),
        vid,
        String.to_existing_atom(att),
        socket.assigns.current_user.id
      )

    # Optimistic local refresh; the broadcast will arrive too.
    socket =
      if drawer = socket.assigns.drawer_work_item do
        assign(socket, :drawer_facets, drawer_facets_for(drawer.id))
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Helpers (sort / classify / lookup)
  # ---------------------------------------------------------------------------

  defp attention_for(wi, %{} = facet_map), do: Map.get(facet_map, wi.id, :watch)

  defp sorted_for(state, %{grouped: grouped, facet_map: fm, show_hidden: sh}) do
    items = Map.get(grouped, state, [])

    visible =
      items
      |> Enum.reject(fn wi ->
        attention_for(wi, fm) == :hidden and not Map.get(sh, state, false)
      end)
      |> Enum.sort_by(fn wi ->
        {Map.fetch!(@attention_rank, attention_for(wi, fm)), wi.id}
      end)

    hidden_count =
      Enum.count(items, fn wi -> attention_for(wi, fm) == :hidden end)

    {visible, hidden_count}
  end

  defp attention_class(:act), do: "border-l-4 border-primary"
  defp attention_class(:watch), do: "border border-base-300"
  defp attention_class(:know), do: "border border-dashed border-base-300 opacity-60"
  defp attention_class(:hidden), do: "border border-dashed border-base-300 opacity-40 italic"

  defp find_work_item(%{assigns: %{grouped: grouped}}, wi_id) do
    grouped
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == wi_id))
  end

  defp drawer_facets_for(wi_id) do
    # The drawer needs `%{viewer_id => attention}` for all viewers; default :watch
    # is applied by the caller (the WorkItemFacet rows are lazy — invariant #8).
    Repo.all(from f in WorkItemFacet, where: f.work_item_id == ^wi_id)
    |> Map.new(fn f -> {f.viewer_id, f.attention} end)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="loom fixed inset-0 z-50 bg-base-200 overflow-auto p-6"
      id="in-service-board"
      phx-hook="ViewerPrefs"
    >
      <div class="flex items-center justify-between mb-4 gap-4">
        <h1 class="loom-modal-title text-2xl font-bold">In Service</h1>
        <.viewer_switcher viewers={@viewers} active_viewer_id={@active_viewer_id} />
        <.link navigate={~p"/chat"} class="btn btn-ghost btn-sm">Close</.link>
      </div>

      <div class="grid grid-cols-4 gap-4">
        <div :for={{state, label} <- @columns} class="flex flex-col gap-2">
          <h2 class="text-sm uppercase tracking-wide text-base-content/60">{label}</h2>

          <% {visible, hidden_count} = sorted_for(state, assigns) %>

          <div
            :for={wi <- visible}
            class={[
              "rounded-lg bg-base-100 p-3 cursor-pointer",
              attention_class(attention_for(wi, @facet_map))
            ]}
            data-work-item={wi.id}
            phx-click="open_drawer"
            phx-value-id={wi.id}
          >
            <p class="font-semibold">{wi.title}</p>
            <p :if={attention_for(wi, @facet_map) == :act} class="text-xs text-primary">behind</p>

            <div :if={attention_for(wi, @facet_map) != :know} class="mt-2 flex flex-wrap gap-1">
              <button
                :for={{target, target_label} <- @columns}
                :if={target != state}
                phx-click="move_work_item"
                phx-value-id={wi.id}
                phx-value-to={target}
                class="btn btn-xs btn-ghost"
              >
                → {target_label}
              </button>
            </div>
          </div>

          <p :if={visible == []} class="text-xs text-base-content/40">—</p>

          <button
            :if={hidden_count > 0 and not Map.get(@show_hidden, state, false)}
            type="button"
            phx-click="toggle_hidden"
            phx-value-column={Atom.to_string(state)}
            class="btn btn-xs btn-ghost text-base-content/60"
          >
            +{hidden_count} not at your altitude
          </button>
        </div>
      </div>

      <.live_component
        :if={@drawer_work_item}
        module={SlackexWeb.SousLive.FacetDrawerComponent}
        id="facet-drawer"
        work_item={@drawer_work_item}
        viewers={@viewers}
        facets={@drawer_facets}
      />
    </div>
    """
  end
end
