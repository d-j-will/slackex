defmodule SlackexWeb.Router do
  use SlackexWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SlackexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SlackexWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", SlackexWeb do
  #   pipe_through :api
  # end

  if Application.compile_env(:slackex, :dev_routes) do
    scope "/dev" do
      pipe_through :browser
    end
  end
end
