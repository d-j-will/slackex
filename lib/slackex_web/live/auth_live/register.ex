defmodule SlackexWeb.AuthLive.Register do
  use SlackexWeb, :live_view

  alias Slackex.Accounts
  alias Slackex.Accounts.User

  def mount(_params, _session, socket) do
    changeset = User.registration_changeset(%User{}, %{})

    socket =
      socket
      |> assign(:page_title, "Register")
      |> assign(:form, to_form(changeset))

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm mt-10">
      <h1 class="text-2xl font-bold mb-6 text-center">Create an account</h1>

      <.form for={@form} id="registration-form" phx-submit="save" phx-change="validate">
        <div class="space-y-4">
          <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
          <.input field={@form[:email]} type="email" label="Email" autocomplete="email" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
          />
        </div>

        <div class="mt-6">
          <.button phx-disable-with="Creating account..." class="w-full">
            Create account
          </.button>
        </div>
      </.form>

      <p class="text-center mt-4 text-sm">
        Already have an account?
        <.link href={~p"/users/log-in"} class="font-semibold text-primary hover:underline">
          Log in
        </.link>
      </p>
    </div>
    """
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> User.registration_changeset(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully! Please log in.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
