defmodule SlackexWeb.ChatLive.InviteLinkModal do
  @moduledoc """
  LiveComponent for managing channel invite links.
  Lists existing invites, generates new ones, and supports revoking.
  """
  use SlackexWeb, :live_component

  alias Slackex.Chat.Invites

  @impl true
  def update(assigns, socket) do
    links = Invites.list_invite_links(assigns.channel.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:links, links)
     |> assign(:generated_url, nil)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{socket.assigns.channel.slug}")}
  end

  def handle_event("generate", _params, socket) do
    channel = socket.assigns.channel
    user = socket.assigns.current_user

    case Invites.create_invite_link(channel.id, user.id) do
      {:ok, invite} ->
        links = Invites.list_invite_links(channel.id)
        url = url(~p"/chat/invite/#{invite.code}")

        {:noreply,
         socket
         |> assign(:links, links)
         |> assign(:generated_url, url)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"invite-id" => raw_id}, socket) do
    with {invite_id, ""} <- Integer.parse(raw_id) do
      Invites.revoke_invite_link(invite_id, socket.assigns.current_user.id)
    end

    links = Invites.list_invite_links(socket.assigns.channel.id)
    {:noreply, assign(socket, :links, links)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="invite-link-modal"
      phx-window-keydown="close_modal"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_modal"
        phx-target={@myself}
      />

      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="bg-base-100 rounded-xl shadow-xl w-full sm:max-w-lg max-h-[70vh] flex flex-col">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="loom-modal-title font-bold text-lg">Invite Links</h3>
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

          <div class="p-4 border-b border-base-300">
            <button
              phx-click="generate"
              phx-target={@myself}
              class="btn btn-primary btn-sm w-full"
            >
              Generate Invite Link
            </button>
            <div
              :if={@generated_url}
              class="mt-3 flex items-center gap-2 bg-base-200 rounded-lg px-3 py-2"
            >
              <code class="text-sm flex-1 truncate">{@generated_url}</code>
              <button
                phx-click={JS.dispatch("phx:copy", detail: %{text: @generated_url})}
                class="btn btn-ghost btn-xs"
                title="Copy link"
              >
                <span class="hero-clipboard size-4" />
              </button>
            </div>
          </div>

          <div class="overflow-y-auto flex-1">
            <div
              :if={@links == []}
              class="text-center text-base-content/50 py-8 text-sm"
            >
              No invite links yet.
            </div>
            <div
              :for={link <- @links}
              class="px-4 py-3 border-b border-base-200 last:border-b-0 flex items-center gap-3"
            >
              <div class="flex-1 min-w-0">
                <code class="text-sm text-primary">{link.code}</code>
                <div class="flex gap-3 text-xs text-base-content/50 mt-0.5">
                  <span>{link.use_count} uses</span>
                  <span :if={link.max_uses}>/ {link.max_uses} max</span>
                  <span :if={link.expires_at}>
                    expires {Calendar.strftime(link.expires_at, "%b %d")}
                  </span>
                </div>
              </div>
              <button
                phx-click="revoke"
                phx-value-invite-id={link.id}
                phx-target={@myself}
                data-confirm="Revoke this invite link?"
                class="btn btn-ghost btn-xs text-error"
              >
                Revoke
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
