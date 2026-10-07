defmodule SdrAgent.Agents.Witness.ReconcilerTest do
  @moduledoc """
  S12c steps 6–7, hermetic end to end: ModelProvider facade → ClaudeCLI
  (child env) → fake CLI playing shim + S12a proxy → stand-in witness store
  → reconciler (bounded reader, audited scoped payload read, projection) →
  WireWitnessLinks, attention Failures and `Agents.witness_status/2`.

  C1 invocation aggregate, C2 missing/incomplete/ambiguous attention without
  fabricated links, C3 mismatch attention, P2 no account id in SDR records,
  P7 count_tokens classification, idempotent replays, and R3: the runtime
  reconciled-method allowlist is empty, so a perfect proof stays `inferred`;
  `reconciled` appears only under an explicit, isolated test allowlist.
  """
  use SdrAgent.AuditCase, async: false

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations
  alias SdrAgent.Telemetry.InMemoryExporter
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @witness SdrAgent.Agents.Witness
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @fake Path.expand("../../../support/fake_claude_cli.exs", __DIR__)
  @test_only_allowlist [:propagated_id]

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    root = Path.join(System.tmp_dir!(), "sdr-witness-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      root: root,
      rec: system_actor(:reconciler, tenant)
    }
  end

  test "the runtime reconciled-method allowlist ships empty (R3)" do
    config = Application.get_env(:sdr_agent, @witness, [])
    assert Keyword.get(config, :reconciled_methods, []) == []
  end

  test "a perfect proof stays inferred at runtime; links carry digests, not content", ctx do
    invocation = call_model!(ctx, "ok")
    assert {:ok, summary} = reconcile(ctx, invocation)
    assert summary.status == :inferred

    assert {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
    assert link.link_status == :inferred
    assert link.method == :propagated_id
    assert link.evidence["classification"] == "primary"
    assert "method_not_enabled" in link.evidence["reason_codes"]
    assert link.evidence["app_request_sha256"] == hex(invocation.request_sha256)

    assert link.evidence["projected_request_sha256"] ==
             link.evidence["observed_request_projection_sha256"]

    assert link.proxy_request_sha256 != nil
    assert link.evidence["projection_version"] =~ "claude-message-json/1"

    assert {:ok, :inferred} = status(invocation, ctx.rec)
    assert attention(ctx) == []

    # P2: the raw request's account id never enters SDR records or telemetry.
    rendered =
      inspect([link, events(ctx.tenant), InMemoryExporter.spans()], limit: :infinity)

    refute rendered =~ Proxy.account_id()
    refute rendered =~ "Synthetic CLI system text"
  end

  test "under an isolated test allowlist the same proof is reconciled", ctx do
    invocation = call_model!(ctx, "ok")
    assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)

    assert {:ok, [%{link_status: :reconciled}]} =
             Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

    assert {:ok, :reconciled} = status(invocation, ctx.rec)
  end

  test "replays add no links, events or failures, and never re-send the model", ctx do
    invocation = call_model!(ctx, "mismatch")
    assert {:ok, _} = reconcile(ctx, invocation)
    links = length(elem(Agents.list_wire_witness_links(invocation.id, actor: ctx.rec), 1))
    linked = length(events_of_type(ctx.tenant, "agents.witness.linked"))
    failures = length(attention(ctx))
    sent = length(events_of_type(ctx.tenant, "model.invocation.sent"))

    assert {:ok, _} = reconcile(ctx, invocation)
    assert {:ok, _} = reconcile(ctx, invocation)

    assert length(elem(Agents.list_wire_witness_links(invocation.id, actor: ctx.rec), 1)) == links
    assert length(events_of_type(ctx.tenant, "agents.witness.linked")) == linked
    assert length(attention(ctx)) == failures
    assert length(events_of_type(ctx.tenant, "model.invocation.sent")) == sent
  end

  test "a mismatch links, opens critical attention and is the invocation status (C3)", ctx do
    for variant <- ["mismatch", "prompt_changed", "tool_use"] do
      invocation = call_model!(ctx, variant)
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, @test_only_allowlist)

      assert {:ok, [%{link_status: :mismatch}]} =
               Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

      assert {:ok, :mismatch} = status(invocation, ctx.rec)
      assert [failure] = attention(ctx, invocation)
      assert {failure.class, failure.severity} == {:reconciliation_required, :critical}
    end
  end

  test "no witness record: no fabricated link, one warning, unwitnessed (C2)", ctx do
    invocation = call_model!(ctx, "none")

    for _ <- 1..2, do: assert({:ok, %{status: :unwitnessed}} = reconcile(ctx, invocation))

    assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    assert {:ok, :unwitnessed} = status(invocation, ctx.rec)
    assert [failure] = attention(ctx, invocation)
    assert {failure.class, failure.severity} == {:reconciliation_required, :warning}
    assert failure.message =~ "witness_missing"
  end

  test "ambiguous, open or unclassified extra traffic downgrades and warns (C1, P7)", ctx do
    for {variant, reason} <- [
          {"double", "multiple_primary_exchanges"},
          {"open", "exchange_open"},
          {"unknown_route", "unclassified_exchange"},
          {"count_tokens_content", "unclassified_exchange"},
          {"no_stop", "response_stream_incomplete"}
        ] do
      invocation = call_model!(ctx, variant)
      assert {:ok, summary} = reconcile(ctx, invocation, @test_only_allowlist)
      assert summary.status == :inferred, variant
      assert {:ok, :inferred} = status(invocation, ctx.rec)
      assert [failure] = attention(ctx, invocation), variant
      assert failure.severity == :warning
      assert failure.message =~ reason, "#{variant}: #{failure.message}"
    end
  end

  test "a content-free count_tokens extra is ancillary and keeps a reconciled primary", ctx do
    invocation = call_model!(ctx, "count_tokens")
    assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)
    assert {:ok, links} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

    assert Enum.sort(Enum.map(links, & &1.evidence["classification"])) ==
             ["ancillary", "primary"]

    assert {:ok, :reconciled} = status(invocation, ctx.rec)
    assert attention(ctx, invocation) == []
  end

  test "an unconfigured store does nothing and opens no attention", ctx do
    invocation = call_model!(ctx, "ok")

    assert {:ok, %{status: :skipped}} =
             call(@witness, :reconcile, [invocation.id, [actor: ctx.rec, store_root: nil]])

    assert attention(ctx) == []
  end

  test "only REC reconciles; the chain stays valid", ctx do
    invocation = call_model!(ctx, "ok")

    for actor <- [ctx.agent, human(:admin, ctx.tenant), human(:auditor, ctx.tenant)] do
      assert {:error, %Ash.Error.Forbidden{}} =
               call(@witness, :reconcile, [invocation.id, [actor: actor, store_root: ctx.root]])
    end

    assert {:ok, _} = reconcile(ctx, invocation)
    assert {:ok, report} = SdrAgent.Audit.verify_chain(actor: human(:admin, ctx.tenant))
    assert report.valid?, inspect(report.issues)
  end

  ## Helpers

  defp call_model!(ctx, variant) do
    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "witness", ctx.root, variant]
      )

    id = "witness-#{variant}-#{System.unique_integer([:positive])}"
    attrs = AgentsFixtures.model_attrs(id)

    audit =
      Map.take(attrs, [
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    {:ok, result} =
      ModelProvider.complete(
        %{
          id: id,
          run: ctx.run,
          actor: ctx.agent,
          operation: "model.complete",
          prompt: "Qualify the fixture lead #{variant}",
          schema: @schema,
          audit: audit
        },
        provider: ClaudeCLI,
        provider_options: [server: server]
      )

    GenServer.stop(server)
    result.invocation
  end

  defp reconcile(ctx, invocation, methods \\ nil) do
    opts = [actor: ctx.rec, store_root: ctx.root]
    opts = if methods, do: Keyword.put(opts, :methods, methods), else: opts
    call(@witness, :reconcile, [invocation.id, opts])
  end

  defp status(invocation, actor),
    do: call(Agents, :witness_status, [invocation.id, [actor: actor]])

  defp attention(ctx, invocation \\ nil) do
    {:ok, failures} = Operations.list_attention(actor: human(:admin, ctx.tenant))

    Enum.filter(failures, fn failure ->
      failure.class == :reconciliation_required and
        (is_nil(invocation) or failure.subject_id == invocation.id)
    end)
  end

  # A missing S12c interface fails the scenario's own assertion.
  defp call(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: {:error, {:not_implemented, function}}
  end
end
