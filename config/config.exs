# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sdr_agent, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {1, :day}],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", SdrAgent.Audit.AnchorWorker},
       {"*/10 * * * *", SdrAgent.Audit.OtsUpgradeWorker}
     ]}
  ],
  repo: SdrAgent.Repo

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  tracer: [OpentelemetryAsh],
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  default_string_length_count: :codepoints,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

# Upserts as INSERT ... ON CONFLICT, not MERGE: on PostgreSQL 17+ AshPostgres
# would otherwise use MERGE, which raises unique violations when concurrent
# transactions insert the same key. The insert-if-absent paths (Payload,
# ProvenanceSnapshot, Decision idempotency) depend on ON CONFLICT semantics;
# proven by test/sdr_agent/audit/concurrency_test.exs.
config :ash_postgres, upsert_with_merge?: false

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :sdr_agent,
  ecto_repos: [SdrAgent.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    SdrAgent.Audit,
    SdrAgent.Accounts,
    SdrAgent.Operations,
    SdrAgent.Agents,
    SdrAgent.Sales,
    SdrAgent.Research
  ]

# Configure the endpoint
config :sdr_agent, SdrAgentWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SdrAgentWeb.ErrorHTML, json: SdrAgentWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SdrAgent.PubSub,
  live_view: [signing_salt: "JbPDMQz2"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :sdr_agent, SdrAgent.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sdr_agent: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  sdr_agent: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :otel_trace_id, :otel_span_id]

config :sdr_agent,
  model_provider: SdrAgent.AI.ModelProvider.Fake,
  otel_capture_content: false,
  anchor_event_count: 100,
  anchor_interval_seconds: 900,
  ots_upgrade_batch_size: 25,
  anchor_sinks: []

config :opentelemetry, resource: %{service: %{name: "sdr_agent"}}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
