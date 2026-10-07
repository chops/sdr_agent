defmodule Mix.Tasks.Sdr.Audit.Export do
  @shortdoc "Create a signed, anchored audit export bundle"
  @moduledoc """
  Creates a signed export for `--lead ID`, `--run ID`, `--draft ID`, or
  `--sequence-range FROM:TO`. Run through `bin/with-secrets` so the Ed25519
  private key exists only in the task environment.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(argv,
        strict: [
          lead: :string,
          run: :string,
          draft: :string,
          sequence_range: :string,
          output: :string
        ]
      )

    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")
    {scope, ref} = scope!(opts)
    output = Keyword.get(opts, :output, "audit-export-#{scope}-#{ref}.json")
    private_key = private_key!()
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()
    actor = SdrAgent.Actor.system(:auditor_cli, tenant_id)
    anchorer = SdrAgent.Actor.system(:anchorer, tenant_id)

    case SdrAgent.Audit.Export.build(
           %{scope: scope, scope_ref: ref},
           actor: actor,
           anchor_actor: anchorer,
           private_key: private_key,
           sinks: Application.get_env(:sdr_agent, :anchor_sinks, []),
           output: output
         ) do
      {:ok, %{export: export}} ->
        Mix.shell().info("wrote #{output} assurance=#{export.assurance_level}")

      {:error, reason} ->
        Mix.raise("export failed: #{inspect(reason)}")
    end
  end

  defp scope!(opts) do
    [{key, value}] =
      Enum.filter(opts, fn {key, _} -> key in [:lead, :run, :draft, :sequence_range] end)

    {Map.fetch!(
       %{lead: :lead, run: :agent_run, draft: :draft, sequence_range: :sequence_range},
       key
     ), value}
  rescue
    _ -> Mix.raise("specify exactly one of --lead, --run, --draft, --sequence-range")
  end

  defp private_key! do
    with {:ok, value} <- System.fetch_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY"),
         {:ok, key} <- SdrAgent.Audit.Signing.decode_private_key(value) do
      key
    else
      _ -> Mix.raise("SDR_AUDIT_ANCHOR_PRIVATE_KEY is missing or invalid; use bin/with-secrets")
    end
  end
end
