import Config
config :sdr_agent, otel_capture_content: false

config :opentelemetry, :processors,
  otel_simple_processor: %{exporter: {SdrAgent.Telemetry.InMemoryExporter, []}}

config :sdr_agent, :otel_test_exporter, SdrAgent.Telemetry.InMemoryExporter

config :sdr_agent, Oban, testing: :manual
config :sdr_agent, token_signing_secret: "x0lKSRtwFS5BaFNguZ0LCt7JYjNRZ4pi"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :sdr_agent, SdrAgent.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "sdr_agent_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sdr_agent, SdrAgentWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FfXK1KFz8SsP7GkikpVI3e6qHgNGASkdkdteWR7UtyQGugWXjgwgHOqBoUmqDffN",
  server: false

# In test we don't send emails
config :sdr_agent, SdrAgent.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Demo seed fixtures may be written here (ADR-0009: seed actions are
# authorized only for the seeder in :dev/:test; absent elsewhere = refused).
config :sdr_agent, seeding_allowed?: true

# <!-- >>> workflow-factory:workflow-project-config >>> -->
config :sdr_agent, SdrAgent.Repo,
  database: "sdr_agent_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: 5520

# <!-- <<< workflow-factory:workflow-project-config <<< -->
