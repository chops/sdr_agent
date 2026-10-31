import Config

# ADR-0024/D-270: a separate hosted build, not ordinary production with a
# prototype switch smuggled in at runtime. Keep prod's TLS/static/capture
# baseline; the only model execution is the remote subscription worker.
import_config "prod.exs"

config :sdr_agent,
  prototype_authority_compiled: true,
  human_authority_provider: SdrAgent.Operations.HostedOwners,
  model_provider: SdrAgent.AI.ModelProvider.ClaudeCLI,
  model_transport: :remote,
  dev_routes: false,
  seeding_allowed?: false,
  prototype_test_seams: false,
  claude_cli_test_seams: false,
  smoke_attestation_plug: false,
  otel_capture_content: false

config :sdr_agent, SdrAgentWeb.Endpoint,
  code_reloader: false,
  debug_errors: false,
  watchers: [],
  live_reload: false

# Match the prototype's content-free witness mode, without a host-side
# wire-witness store or exporter. Runtime rejects attempts to configure one.
config :opentelemetry,
  traces_exporter: :none,
  span_processor: :undefined,
  processors: [],
  sampler: :always_off
