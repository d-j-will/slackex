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

  alias Slackex.AI.LLMClient
  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{FacetPrompt, FacetWorker, Viewer, WorkItemFacet}

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
        |> assign(:drawer_facet_rows, %{})
        |> assign(:drawer_enqueued, MapSet.new())
        |> assign(:drawer_failed, MapSet.new())
        |> assign(:drawer_facets_topic, nil)
        |> assign(:stale_map, MapSet.new())
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
      |> assign(:stale_map, Sous.stale_facets_for_viewer(viewer_id))

    {:noreply, socket}
  end

  def handle_event("viewer_pref:loaded", %{"viewer_id" => viewer_id}, socket) do
    # Bridge from the JS hook — same effect as a user click on the switcher.
    viewer_id = if viewer_id in [nil, ""], do: nil, else: viewer_id

    socket =
      socket
      |> Slackex.Sous.ViewerPreference.put(viewer_id)
      |> assign(:facet_map, Sous.facets_for_viewer(viewer_id))
      |> assign(:stale_map, Sous.stale_facets_for_viewer(viewer_id))

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

    # Subscribe to per-work-item facet topic so :facet_generated broadcasts arrive.
    topic = Sous.facets_topic(wi_id)

    _ =
      if connected?(socket),
        do: Phoenix.PubSub.subscribe(Slackex.PubSub, topic)

    facet_rows = facet_rows_for(wi_id)
    failed = discarded_viewer_ids(wi_id)

    # Lazy-on-open: enqueue a FacetWorker for every viewer whose pill state is
    # :never_generated or :stale, when LLM is configured. Compute state_version
    # ONCE here (invariant: never re-query inside the worker).
    {enqueued, _} =
      if LLMClient.configured?() do
        enqueue_missing_facets(wi_id, socket.assigns.viewers, facet_rows, failed)
      else
        {MapSet.new(), :ok}
      end

    {:noreply,
     socket
     |> assign(:drawer_work_item, wi)
     |> assign(:drawer_facets, attention_map(facet_rows))
     |> assign(:drawer_facet_rows, facet_rows)
     |> assign(:drawer_enqueued, enqueued)
     |> assign(:drawer_failed, failed)
     |> assign(:drawer_facets_topic, topic)}
  end

  # Manual retry of a :failed facet (the only user gesture that enqueues; B2 §7.2).
  def handle_event("retry_facet", %{"viewer_id" => viewer_id}, socket) do
    case socket.assigns.drawer_work_item do
      nil ->
        {:noreply, socket}

      wi ->
        _ = enqueue_one(wi.id, viewer_id)

        enqueued = MapSet.put(socket.assigns.drawer_enqueued, viewer_id)
        failed = MapSet.delete(socket.assigns.drawer_failed, viewer_id)

        {:noreply, socket |> assign(:drawer_enqueued, enqueued) |> assign(:drawer_failed, failed)}
    end
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
        refresh_drawer_rows(socket, drawer.id)
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
        refresh_drawer_rows(socket, drawer.id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:work_item_event, :state_changed, wi}, socket) do
    # :state_changed marks every existing facet row for this work item as stale
    # (Sous.move/3 + invariant #14). Refresh the stale_map if there's an active
    # viewer so the board card's subtle dot indicator appears.
    socket = assign(socket, :grouped, Sous.list_in_flight())

    socket =
      cond do
        is_nil(socket.assigns.active_viewer_id) ->
          socket

        # Only re-query if the active viewer had a row for this work item
        # (cheap: one Map lookup against existing facets_for_viewer keys).
        Map.has_key?(socket.assigns.facet_map, wi.id) ->
          assign(socket, :stale_map, MapSet.put(socket.assigns.stale_map, wi.id))

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:work_item_event, _type, _wi}, socket) do
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  def handle_info({:retry_facet, viewer_id}, socket) do
    case socket.assigns.drawer_work_item do
      nil ->
        {:noreply, socket}

      wi ->
        _ = enqueue_one(wi.id, viewer_id)

        enqueued = MapSet.put(socket.assigns.drawer_enqueued, viewer_id)
        failed = MapSet.delete(socket.assigns.drawer_failed, viewer_id)

        {:noreply, socket |> assign(:drawer_enqueued, enqueued) |> assign(:drawer_failed, failed)}
    end
  end

  def handle_info({:sous, :facet_generated, wi_id, viewer_id}, socket) do
    socket =
      case socket.assigns.drawer_work_item do
        %{id: ^wi_id} ->
          facet_rows = facet_rows_for(wi_id)

          socket
          |> assign(:drawer_facet_rows, facet_rows)
          |> assign(:drawer_facets, attention_map(facet_rows))
          |> assign(:drawer_enqueued, MapSet.delete(socket.assigns.drawer_enqueued, viewer_id))
          |> assign(:drawer_failed, MapSet.delete(socket.assigns.drawer_failed, viewer_id))

        _ ->
          socket
      end

    # If the active viewer matches, the row no longer has facet_stale_at
    # (generation always clears stale), so remove from the indicator set.
    socket =
      if socket.assigns.active_viewer_id == viewer_id do
        assign(socket, :stale_map, MapSet.delete(socket.assigns.stale_map, wi_id))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:close_facet_drawer, socket) do
    _ =
      if topic = socket.assigns.drawer_facets_topic,
        do: Phoenix.PubSub.unsubscribe(Slackex.PubSub, topic)

    {:noreply,
     socket
     |> assign(:drawer_work_item, nil)
     |> assign(:drawer_facets, %{})
     |> assign(:drawer_facet_rows, %{})
     |> assign(:drawer_enqueued, MapSet.new())
     |> assign(:drawer_failed, MapSet.new())
     |> assign(:drawer_facets_topic, nil)}
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
        refresh_drawer_rows(socket, drawer.id)
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
        # Spec §7.2: attention rank ascending, then `inserted_at desc` within rank.
        # Snowflake IDs are time-ordered, so `-wi.id` reverses to newest-first.
        {Map.fetch!(@attention_rank, attention_for(wi, fm)), -wi.id}
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

  # B2: returns %{viewer_id => %WorkItemFacet{}} for the work item. The Drawer
  # derives attention (Map.get(...).attention || :watch) AND pill state via
  # WorkItemFacet.state/3 from the row, so we keep the row map authoritative.
  defp facet_rows_for(wi_id) do
    Repo.all(from f in WorkItemFacet, where: f.work_item_id == ^wi_id)
    |> Map.new(fn f -> {f.viewer_id, f} end)
  end

  defp attention_map(facet_rows) do
    facet_rows
    |> Enum.map(fn {vid, row} -> {vid, row.attention || :watch} end)
    |> Map.new()
  end

  defp refresh_drawer_rows(socket, wi_id) do
    rows = facet_rows_for(wi_id)

    socket
    |> assign(:drawer_facet_rows, rows)
    |> assign(:drawer_facets, attention_map(rows))
  end

  # Lazy-on-open enqueue (B2 spec §5 step 3): one FacetWorker per viewer whose
  # pill state derives to :never_generated or :stale.
  defp enqueue_missing_facets(wi_id, viewers, facet_rows, failed) do
    state_version = Sous.state_version(wi_id)
    prompt_version = FacetPrompt.prompt_version()

    enqueued =
      Enum.reduce(viewers, MapSet.new(), fn v, acc ->
        enqueue_if_missing(v, wi_id, facet_rows, failed, prompt_version, state_version, acc)
      end)

    {enqueued, :ok}
  end

  # Single-viewer enqueue decision: skip if :failed (user must click retry);
  # enqueue if the pill state is :never_generated or :stale.
  defp enqueue_if_missing(v, wi_id, facet_rows, failed, prompt_v, state_v, acc) do
    cond do
      MapSet.member?(failed, v.id) ->
        acc

      WorkItemFacet.state(Map.get(facet_rows, v.id), MapSet.new(), v.id) in [
        :never_generated,
        :stale
      ] ->
        _ = enqueue_one(wi_id, v.id, prompt_v, state_v)
        MapSet.put(acc, v.id)

      true ->
        acc
    end
  end

  defp enqueue_one(wi_id, viewer_id, prompt_v \\ nil, state_v \\ nil) do
    prompt_version = prompt_v || FacetPrompt.prompt_version()
    state_version = state_v || Sous.state_version(wi_id)

    %{
      "work_item_id" => wi_id,
      "viewer_id" => viewer_id,
      "prompt_version" => prompt_version,
      "state_version" => state_version
    }
    |> FacetWorker.new()
    |> Oban.insert()
  end

  # B2: viewer_ids of jobs that exhausted retries (`:discarded` in oban_jobs).
  # Used to render the :failed pill + retry glyph. One query at open_drawer;
  # the alternative (PubSub from the worker) is deferred.
  defp discarded_viewer_ids(wi_id) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "Slackex.Sous.FacetWorker" and
            j.state == "discarded" and
            fragment("?->>'work_item_id' = ?", j.args, ^to_string(wi_id)),
        select: fragment("?->>'viewer_id'", j.args)
    )
    |> MapSet.new()
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
            <div class="flex items-start justify-between gap-2">
              <p class="font-semibold">{wi.title}</p>
              <span
                :if={MapSet.member?(@stale_map, wi.id)}
                data-stale-indicator={wi.id}
                aria-label="facet stale"
                class="mt-1 inline-block w-1.5 h-1.5 rounded-full bg-warning shrink-0"
              />
            </div>
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
        facet_rows={@drawer_facet_rows}
        enqueued={@drawer_enqueued}
        failed={@drawer_failed}
        llm_configured?={LLMClient.configured?()}
      />
    </div>
    """
  end
end
