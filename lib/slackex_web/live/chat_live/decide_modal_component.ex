defmodule SlackexWeb.ChatLive.DecideModalComponent do
  @moduledoc """
  Modal for `/decide`: captures a decision (Title/What/Why/Next/Stakeholders)
  and creates a Sous work item + posts the decision card. Three dismiss
  mechanisms per project UI convention.
  """
  use SlackexWeb, :live_component

  alias Slackex.Sous
  require Logger

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(%{"title" => "", "what" => "", "why" => "", "next" => ""}, as: :decision)
     end)}
  end

  @impl true
  def handle_event("close_decide", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.return_to)}
  end

  def handle_event("save_decide", %{"decision" => params}, socket) do
    actor = socket.assigns.current_user
    channel = socket.assigns.channel

    attrs = %{
      channel_id: channel.id,
      thread_root_message_id: socket.assigns[:thread_root_message_id],
      actor_id: actor.id,
      actor_username: actor.username,
      title: params["title"],
      what: params["what"],
      why: params["why"],
      next: params["next"],
      stakeholders: socket.assigns[:stakeholder_ids] || []
    }

    case Sous.open_decision(attrs) do
      {:ok, work_item} ->
        case Sous.post_decision_card(work_item, actor.id) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.warning("Sous decision card post failed: #{inspect(reason)}")
        end

        {:noreply, push_patch(socket, to: socket.assigns.return_to)}

      {:error, _step, _changeset, _} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :decision))
         |> assign(:error, "Title and What are required.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="decide-modal" phx-window-keydown="close_decide" phx-key="Escape" phx-target={@myself}>
      <div class="fixed inset-0 z-40 bg-black/50" phx-click="close_decide" phx-target={@myself} />
      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="loom bg-base-100 rounded-xl shadow-xl w-full sm:max-w-lg max-h-[80vh] flex flex-col">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="loom-modal-title font-bold text-lg">Capture a decision</h3>
            <button
              type="button"
              phx-click="close_decide"
              phx-target={@myself}
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-5" />
            </button>
          </div>
          <.form
            for={@form}
            phx-submit="save_decide"
            phx-target={@myself}
            id="decide-form"
            class="p-4 space-y-3 overflow-y-auto"
          >
            <p :if={assigns[:error]} class="text-error text-sm">{@error}</p>
            <.input field={@form[:title]} label="Title" required />
            <.input field={@form[:what]} type="textarea" label="What" required />
            <.input field={@form[:why]} type="textarea" label="Why" />
            <.input field={@form[:next]} type="textarea" label="Next" />
            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                phx-click="close_decide"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary loom-send">Create decision</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
