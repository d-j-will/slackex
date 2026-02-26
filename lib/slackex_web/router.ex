defmodule SlackexWeb.Router do
  use SlackexWeb, :router

  import SlackexWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SlackexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SlackexWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Authentication routes

  scope "/", SlackexWeb do
    pipe_through :browser

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", SlackexWeb do
    pipe_through :browser

    live_session :redirect_if_authenticated,
      on_mount: [{SlackexWeb.UserAuth, :redirect_if_authenticated}] do
      live "/users/register", AuthLive.Register, :new
      live "/users/log-in", AuthLive.Login, :new
    end
  end

  scope "/", SlackexWeb do
    pipe_through :browser

    live_session :chat,
      on_mount: [{SlackexWeb.UserAuth, :ensure_authenticated}],
      layout: {SlackexWeb.Layouts, :chat} do
      live "/chat", ChatLive.Index, :index
      live "/chat/channels/new", ChatLive.Index, :create_channel
      live "/chat/channels/browse", ChatLive.Index, :browse_channels
      live "/chat/dm/new", ChatLive.Index, :new_dm
      live "/chat/dm/:dm_id", ChatLive.Index, :dm
      live "/chat/:slug", ChatLive.Index, :show
    end
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
    post "/device-tokens", DeviceTokenController, :create
    delete "/device-tokens", DeviceTokenController, :delete
  end

  if Application.compile_env(:slackex, :dev_routes) do
    scope "/dev" do
      pipe_through :browser
    end
  end
end
