defmodule SdrAgentWeb.Router do
  use SdrAgentWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SdrAgentWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", SdrAgentWeb do
    pipe_through :browser

    # The operator console (S10): a signed-in operator is required; the role
    # only shapes the UI — every action is authorized by the domain.
    ash_authentication_live_session :operator_console,
      on_mount: [{SdrAgentWeb.LiveUserAuth, :operator}] do
      live "/", DashboardLive, :index
      live "/leads", LeadLive.Index, :index
      live "/leads/:id", LeadLive.Show, :show
      live "/review", ReviewLive, :index
      live "/drafts/:id", DraftLive, :show
    end
  end

  scope "/", SdrAgentWeb do
    pipe_through :browser

    auth_routes AuthController, SdrAgent.Accounts.User, path: "/auth"

    sign_out_route AuthController, "/sign-out",
      overrides: [SdrAgentWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    # Password sign-in only: registration, reset, confirmation and magic
    # links are not offered (S2 User: operators are created by an admin).
    sign_in_route auth_routes_prefix: "/auth",
                  on_mount: [{SdrAgentWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    SdrAgentWeb.AuthOverrides,
                    AshAuthentication.Phoenix.Overrides.Default
                  ]
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  # S9: the simulated provider webhook — signature-verified, no session.
  scope "/webhooks", SdrAgentWeb do
    pipe_through :webhook

    post "/capture_sim/:event_type", WebhookController, :receive
  end

  # Other scopes may use custom stacks.
  # scope "/api", SdrAgentWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:sdr_agent, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SdrAgentWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
