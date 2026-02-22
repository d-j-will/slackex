defmodule SlackexWeb.AuthLive.Login do
  use SlackexWeb, :live_view

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email, "password" => ""}, as: "user")

    socket =
      socket
      |> assign(:page_title, "Log In")
      |> assign(:form, form)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm mt-10">
      <h1 class="text-2xl font-bold mb-6 text-center">Log in to Slackex</h1>

      <.form
        for={@form}
        id="login-form"
        action={~p"/users/log-in"}
        phx-update="ignore"
      >
        <div class="space-y-4">
          <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
          />
        </div>

        <div class="mt-6">
          <.button phx-disable-with="Logging in..." class="w-full">
            Log in
          </.button>
        </div>
      </.form>

      <p class="text-center mt-4 text-sm">
        Don't have an account?
        <.link href={~p"/users/register"} class="font-semibold text-primary hover:underline">
          Register
        </.link>
      </p>
    </div>
    """
  end
end
