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

  scope "/api", SlackexWeb.API do
    pipe_through :api

    scope "/auth" do
      post "/login", AuthController, :login
      post "/refresh", AuthController, :refresh
    end
  end

  scope "/api", SlackexWeb.API do
    pipe_through [:api, SlackexWeb.Plugs.ApiAuthPipeline]

    get "/bootstrap", BootstrapController, :index
  end

  if Application.compile_env(:slackex, :dev_routes) do
    scope "/dev" do
      pipe_through :browser
    end
  end
end
