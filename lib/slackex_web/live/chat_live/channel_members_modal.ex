defmodule SlackexWeb.ChatLive.ChannelMembersModal do
  @moduledoc """
  LiveComponent for the channel members modal.
  Lists all members with role badges. Admin+ users can promote, demote, and kick members.
  """
  use SlackexWeb, :live_component

  alias Slackex.Chat
  alias Slackex.Chat.Members
  alias Slackex.Chat.Permissions

  @impl true
  def update(assigns, socket) do
    members = Members.list_members(assigns.channel.id)
    actor_role = Chat.get_role(assigns.current_user.id, assigns.channel.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:members, members)
     |> assign(:can_manage, Permissions.can?(actor_role, :manage_members))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{socket.assigns.channel.slug}")}
  end

  def handle_event("promote", %{"user-id" => raw_id}, socket) do
    with {user_id, ""} <- Integer.parse(raw_id) do
      Members.update_member_role(
        socket.assigns.channel.id,
        socket.assigns.current_user.id,
        user_id,
        "admin"
      )
    end

    {:noreply, reload_members(socket)}
  end

  def handle_event("demote", %{"user-id" => raw_id}, socket) do
    with {user_id, ""} <- Integer.parse(raw_id) do
      Members.update_member_role(
        socket.assigns.channel.id,
        socket.assigns.current_user.id,
        user_id,
        "member"
      )
    end

    {:noreply, reload_members(socket)}
  end

  def handle_event("kick", %{"user-id" => raw_id}, socket) do
    with {user_id, ""} <- Integer.parse(raw_id) do
      Members.kick_member(
        socket.assigns.channel.id,
        socket.assigns.current_user.id,
        user_id
      )
    end

    {:noreply, reload_members(socket)}
  end

  defp reload_members(socket) do
    members = Members.list_members(socket.assigns.channel.id)
    assign(socket, :members, members)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="channel-members-modal"
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
        <div class="bg-base-100 rounded-xl shadow-xl w-full sm:max-w-md max-h-[70vh] flex flex-col">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-bold text-lg">
              Members ({length(@members)})
            </h3>
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

          <div class="overflow-y-auto flex-1 divide-y divide-base-200">
            <div :for={member <- @members} class="flex items-center gap-3 px-4 py-3">
              <div class="avatar placeholder">
                <div class="bg-neutral text-neutral-content w-8 rounded-full">
                  <span class="text-sm">
                    {String.first(member.user.display_name || member.user.username)}
                  </span>
                </div>
              </div>
              <div class="flex-1 min-w-0">
                <p class="font-medium text-sm truncate">
                  {member.user.display_name || member.user.username}
                </p>
                <p class="text-xs text-base-content/50">@{member.user.username}</p>
              </div>
              <.role_badge role={member.role} />
              <div :if={@can_manage and member.role != "owner"} class="flex gap-1">
                <button
                  :if={member.role == "member"}
                  phx-click="promote"
                  phx-value-user-id={member.user.id}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                  title="Promote to admin"
                >
                  <span class="hero-arrow-up size-3" />
                </button>
                <button
                  :if={member.role == "admin"}
                  phx-click="demote"
                  phx-value-user-id={member.user.id}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                  title="Demote to member"
                >
                  <span class="hero-arrow-down size-3" />
                </button>
                <button
                  phx-click="kick"
                  phx-value-user-id={member.user.id}
                  phx-target={@myself}
                  data-confirm="Remove this member from the channel?"
                  class="btn btn-ghost btn-xs text-error"
                  title="Remove from channel"
                >
                  <span class="hero-x-mark size-3" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp role_badge(%{role: "owner"} = assigns) do
    ~H"""
    <span class="badge badge-primary badge-sm">Owner</span>
    """
  end

  defp role_badge(%{role: "admin"} = assigns) do
    ~H"""
    <span class="badge badge-secondary badge-sm">Admin</span>
    """
  end

  defp role_badge(assigns) do
    ~H"""
    """
  end
end
