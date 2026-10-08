defmodule SdrAgent.SDR.SchemaProvenanceTest do
  @moduledoc """
  Deterministic schema generation on the production `SDR.Model` path (Codex
  RED verdict 513d153c). An SDR model call records `output_schema_version`
  "2" and an `output_schema_sha256` equal to `Canonical.sha256` of the
  stored request schema. Through the ClaudeCLI fake, the stdin it sent is
  the re-rendering of that stored schema, so all three generation sites
  agree.
  """
  use SdrAgent.SDRCase, async: false

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.Test.WitnessRoot

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  test "SDR.Model records version 2 and the hash of the stored (and sent) schema", ctx do
    root = WitnessRoot.mkdir!("sdr-schema")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "witness", root, "ok"]
      )

    %{run: run} = assign!(ctx, "01")
    [job] = all_enqueued(worker: AgentWorker)

    AgentWorker.run(job,
      model: [provider: ClaudeCLI, provider_options: [server: server]]
    )

    GenServer.stop(server)
    rec = system_actor(:reconciler, ctx.tenant)
    [invocation | _] = invocations!(ctx, run)
    assert invocation.provider == :claude_cli

    {:ok, %{request: request}} = Agents.read_reconciliation_payloads(invocation, actor: rec)
    stored = request |> JSON.decode!() |> Map.fetch!("schema")

    assert invocation.output_schema_version == "2"
    assert invocation.output_schema_sha256 == Canonical.sha256(stored)

    # The stdin the CLI received is the re-rendering of the stored schema.
    assert {:ok, _} =
             Witness.reconcile(invocation.id,
               actor: rec,
               store_root: root,
               methods: [:propagated_id]
             )

    {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: rec)

    assert link.evidence["projected_request_sha256"] ==
             link.evidence["observed_request_projection_sha256"]
  end
end
