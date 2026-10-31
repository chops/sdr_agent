import Config
config :sdr_agent, otel_capture_content: false

config :opentelemetry, :processors,
  otel_simple_processor: %{exporter: {SdrAgent.Telemetry.InMemoryExporter, []}}

config :sdr_agent, :otel_test_exporter, SdrAgent.Telemetry.InMemoryExporter

config :sdr_agent, Oban, testing: :manual

# S13: the browser smoke attestation endpoint (`SdrAgentWeb.SmokeAttestation`)
# exists only in test builds; it answers only under `mix sdr.demo.serve`.
config :sdr_agent, :smoke_attestation_plug, true
# R0-02: compiles the ClaudeCLI test seams in (test builds only): an
# injected pinned-CLI identity and `test_launcher: true` fake launchers that
# may run without a pin and past the staged real-model gate. Dev and prod
# builds contain neither.
config :sdr_agent, :claude_cli_test_seams, true
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

# S12c: tests may pass an explicit per-call method allowlist to the
# reconciler (isolated positive fixtures); never configured elsewhere.
config :sdr_agent, SdrAgent.Agents.Witness,
  store_root: nil,
  reconciled_methods: [],
  allow_method_override: true

# R0-07 slice C: the result gate's bounded wait, lowered for tests (the
# 120 s ceiling may only be lowered) so a gated call whose capture never
# arrives settles quickly.
config :sdr_agent, SdrAgent.Agents.ResultGate, wait_ms: 1_000, poll_ms: 25

# Demo seed fixtures may be written here (ADR-0009: seed actions are
# authorized only for the seeder in :dev/:test; absent elsewhere = refused).
config :sdr_agent, seeding_allowed?: true

# Live console refresh reloads at once in tests (no debounce timer).
config :sdr_agent, SdrAgentWeb.LiveRefresh, debounce_ms: 0

# D-237 (ADR-0005 D-237 amendment item 2 "Development build only"): compiles
# the prototype authority. Only this file and config/dev.exs set it; the
# production build holds the refusal stubs of SdrAgent.Prototype only.
config :sdr_agent, prototype_authority_compiled: true

config :sdr_agent, human_authority_provider: SdrAgent.Operations.HostedOwners

# D-237 (interfaces r6 ruling a): the hermetic, test-build-only prototype seam
# (SdrAgent.Prototype.Authority.TestSeam: a process-scoped runtime and live
# identity override). Never set in dev or prod; the authority flag alone does
# not enable it.
config :sdr_agent, prototype_test_seams: true

# <!-- >>> workflow-factory:workflow-project-config >>> -->
config :sdr_agent, SdrAgent.Repo,
  database: "sdr_agent_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: 5520

# <!-- <<< workflow-factory:workflow-project-config <<< -->
