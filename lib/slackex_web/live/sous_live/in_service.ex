defmodule SlackexWeb.SousLive.InService do
  @moduledoc """
  The In Service board (Slice A): four columns (Order/Mise/Pass/Walked) rendering
  work items for a single hard-coded viewer = the current user. Attention
  treatments per spec §7. Visual reference: handoff/design/src/in-service.jsx.
  """
  use SlackexWeb, :live_view

  alias Slackex.Sous

  @columns [
    {:order, "Order"},
    {:mise, "Mise"},
    {:pass, "Pass"},
    {:walked, "Walked"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if FunWithFlags.enabled?(:sous, for: user) do
      _ =
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      {:ok,
       socket
       |> assign(:loom, true)
       |> assign(:columns, @columns)
       |> assign(:grouped, Sous.list_in_flight())}
    else
      {:ok, socket |> put_flash(:error, "Not available.") |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_event("move_work_item", %{"id" => id, "to" => to}, socket) do
    _ =
      Sous.move(
        String.to_integer(id),
        String.to_existing_atom(to),
        socket.assigns.current_user.id
      )

    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  @impl true
  def handle_info({:work_item_event, _type, _work_item}, socket) do
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  # Attention → CSS treatment (spec §7).
  defp attention_class(:act), do: "border-l-4 border-primary"
  defp attention_class(:watch), do: "border border-base-300"
  defp attention_class(:know), do: "border border-dashed border-base-300 opacity-60"
  defp attention_class(:hidden), do: "hidden"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loom fixed inset-0 z-50 bg-base-200 overflow-auto p-6">
      <div class="flex items-center justify-between mb-4">
        <h1 class="loom-modal-title text-2xl font-bold">In Service</h1>
        <.link navigate={~p"/chat"} class="btn btn-ghost btn-sm">Close</.link>
      </div>
      <div class="grid grid-cols-4 gap-4">
        <div :for={{state, label} <- @columns} class="flex flex-col gap-2">
          <h2 class="text-sm uppercase tracking-wide text-base-content/60">{label}</h2>
          <div
            :for={wi <- @grouped[state]}
            class={["rounded-lg bg-base-100 p-3", attention_class(wi.attention)]}
            data-work-item={wi.id}
          >
            <p class="font-semibold">{wi.title}</p>
            <p :if={wi.attention == :act} class="text-xs text-primary">behind</p>
            <p class="text-xs text-base-content/60">{wi.facet_text}</p>
            <div class="mt-2 flex flex-wrap gap-1">
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
          <p :if={@grouped[state] == []} class="text-xs text-base-content/40">—</p>
        </div>
      </div>
    </div>
    """
  end
end
