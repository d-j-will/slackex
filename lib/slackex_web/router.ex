defmodule SlackexWeb.Router do
  use SlackexWeb, :router

  import SlackexWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SlackexWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' wss:; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'"
    }

    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :rate_limit_auth do
    plug SlackexWeb.Plugs.RateLimit, max_requests: 10, window_seconds: 60
  end

  pipeline :rate_limit_api_auth do
    plug SlackexWeb.Plugs.RateLimit, max_requests: 10, window_seconds: 60
  end

  # Health/readiness endpoints — outside auth pipelines
  get "/health", SlackexWeb.HealthController, :index
  get "/ready", SlackexWeb.HealthController, :ready
  get "/offline", SlackexWeb.OfflineController, :index

  # Webhook delivery — token-in-URL authentication, no session/auth pipeline
  scope "/api/webhooks", SlackexWeb do
    pipe_through :api

    post "/:token", WebhookController, :deliver
  end

  scope "/", SlackexWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Authentication routes

  scope "/", SlackexWeb do
    pipe_through [:browser, :rate_limit_auth]

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
      live "/chat/:slug/thread/:message_id", ChatLive.Index, :thread
      live "/chat/:slug/members", ChatLive.Index, :members
      live "/chat/:slug/pins", ChatLive.Index, :pinned
      live "/chat/:slug/invite", ChatLive.Index, :invite
      live "/chat/invite/:code", ChatLive.Index, :redeem_invite
      live "/chat/:slug", ChatLive.Index, :show
    end
  end

  scope "/api", SlackexWeb.API do
    pipe_through [:api, :rate_limit_api_auth]

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

  pipeline :admin_flags_auth do
    plug :flags_basic_auth
  end

  scope "/admin/flags" do
    pipe_through [:browser, :admin_flags_auth]

    forward "/", FunWithFlags.UI.Router, namespace: "admin/flags"
  end

  defp flags_basic_auth(conn, _opts) do
    config = Application.fetch_env!(:slackex, :flags_admin_auth)
    Plug.BasicAuth.basic_auth(conn, username: config[:username], password: config[:password])
  end

  if Application.compile_env(:slackex, :dev_routes) do
    scope "/", SlackexWeb do
      pipe_through :browser

      live_session :mockups, layout: false do
        live "/ui-mockups", MockupLive.Index, :index
      end
    end

    scope "/dev" do
      pipe_through :browser
    end
  end
end
