defmodule SlackexWeb.ChatLive.CreateChannelModal do
  @moduledoc """
  LiveComponent for the Create Channel modal.

  Renders a form with name (auto-formatted to lowercase-hyphens), description,
  and is_private toggle. On successful creation, sends `{:channel_created, channel}`
  to the parent LiveView.
  """
  use SlackexWeb, :live_component

  alias Slackex.Chat
  alias Slackex.Chat.Channel

  @impl true
  def mount(socket) do
    changeset = Channel.changeset(%Channel{}, %{})

    {:ok,
     socket
     |> assign(:form, to_form(changeset, as: :channel))}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", %{"channel" => params}, socket) do
    params = normalize_channel_params(params)

    changeset =
      %Channel{}
      |> Channel.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :channel))}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    params = normalize_channel_params(params)

    case Chat.create_channel(socket.assigns.current_user.id, params) do
      {:ok, channel} ->
        send(self(), {:channel_created, channel})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :channel))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end

  defp normalize_channel_params(params) do
    Map.update(params, "name", "", &format_channel_name/1)
  end

  defp format_channel_name(raw) do
    raw
    |> String.downcase()
    |> String.replace(" ", "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="create-channel-modal"
      phx-window-keydown="close_modal"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        id="create-channel-modal-backdrop"
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_modal"
        phx-target={@myself}
      />

      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full max-w-md">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-bold text-lg">Create Channel</h3>
            <button
              type="button"
              phx-click="close_modal"
              phx-target={@myself}
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-5" />
            </button>
          </div>

          <.form
            id="create-channel-form"
            for={@form}
            phx-change="validate"
            phx-submit="save"
            phx-target={@myself}
            class="p-4 space-y-4"
          >
            <div class="form-control">
              <label class="label" for="channel-name">
                <span class="label-text">Channel name</span>
              </label>
              <input
                type="text"
                id="channel-name"
                name="channel[name]"
                value={@form[:name].value}
                placeholder="e.g. project-updates"
                class={["input input-bordered w-full", @form[:name].errors != [] && "input-error"]}
                phx-debounce="300"
                autocomplete="off"
              />
              <.field_errors field={@form[:name]} />
            </div>

            <div class="form-control">
              <label class="label" for="channel-description">
                <span class="label-text">
                  Description <span class="text-base-content/50">(optional)</span>
                </span>
              </label>
              <textarea
                id="channel-description"
                name="channel[description]"
                placeholder="What is this channel about?"
                class="textarea textarea-bordered w-full"
                rows="3"
              >{@form[:description].value}</textarea>
            </div>

            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input
                  type="hidden"
                  name="channel[is_private]"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="channel[is_private]"
                  value="true"
                  checked={@form[:is_private].value == true}
                  class="toggle toggle-primary toggle-sm"
                />
                <span class="label-text">Make private</span>
              </label>
            </div>

            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                phx-click="close_modal"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">
                Create Channel
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp field_errors(assigns) do
    ~H"""
    <div :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="label">
      <span class="label-text-alt text-error">{msg}</span>
    </div>
    """
  end
end
