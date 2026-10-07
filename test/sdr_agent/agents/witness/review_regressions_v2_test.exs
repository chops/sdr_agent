defmodule SdrAgent.Agents.Witness.ReviewRegressionsV2Test do
  @moduledoc """
  Codex review regressions for PR #24 @ff7e97e (verdict 41c2aedf), adopted
  as RED. The four reviewer cases are kept verbatim in substance and widened
  with the requested neighbours:

    1. Malformed wire data outside the v2 grammar is `:unsupported`. It is
       never an exception, at the projection and at reconcile level.
    2. A v2 proof requires exactly the complete approved context group.
       Legacy-only or legacy-overwriting extras are `evidence_contract_invalid`.
       The link action refuses a persisted v2 claim without its complete group.
       Singleton-field validation and v1 evidence stay backward compatible.
  """
  use SdrAgent.AuditCase, async: false

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @version "claude-message-json/2+prompt-builder/1"
  @schema %{"type" => "object"}
  @answer ~s({"answer":"yes"})

  @malformed_trailing [
    {"non-object", [42]},
    {"null block", [nil]},
    {"list block", [["text"]]},
    {"string block", ["text"]},
    {"non-string text", [%{"type" => "text", "text" => 42}]},
    {"null text", [%{"type" => "text", "text" => nil}]},
    {"missing text", [%{"type" => "text"}]},
    {"missing type", [%{"text" => "x"}]},
    {"non-map cache_control", [%{"type" => "text", "text" => "x", "cache_control" => "x"}]},
    {"list cache_control", [%{"type" => "text", "text" => "x", "cache_control" => []}]},
    {"valid then non-object", [%{"type" => "text", "text" => "x"}, 42]}
  ]

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, max_model_calls: 100)
    root = Path.join(System.tmp_dir!(), "sdr-v2-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{tenant: tenant, run: run, agent: agent, root: root, rec: system_actor(:reconciler, tenant)}
  end

  describe "malformed wire data is unsupported, never an exception" do
    for {label, blocks} <- @malformed_trailing do
      test "trailing #{label}" do
        {invocation, app, stdin} = projection_inputs("Synthetic review")
        request = Proxy.cli_request(stdin, trailing_content: unquote(Macro.escape(blocks)))

        result =
          captured(fn ->
            Projection.compare_v2(invocation, app, request, Proxy.sse_response(@answer))
          end)

        assert match?({:unsupported, _}, result), inspect(result)
      end
    end

    test "malformed user, system and message containers" do
      {invocation, app, stdin} = projection_inputs("Synthetic containers")

      for {label, request} <- [
            {"user block non-object", Proxy.cli_request(stdin, user_blocks_extra: [42])},
            {"system non-object", Proxy.cli_request(stdin, top: %{"system" => [42]})},
            {"system non-string text",
             Proxy.cli_request(stdin, top: %{"system" => [%{"type" => "text", "text" => 42}]})},
            {"trailing content string", Proxy.cli_request(stdin, trailing_content: "x")},
            {"trailing content null", Proxy.cli_request(stdin, trailing_content: nil)},
            {"message non-object", Proxy.cli_request(stdin, trailing: 0, extra_messages: [42])},
            {"messages not a list", Proxy.cli_request(stdin, top: %{"messages" => %{}})}
          ] do
        result =
          captured(fn ->
            Projection.compare_v2(invocation, app, request, Proxy.sse_response(@answer))
          end)

        assert match?({:unsupported, _}, result), "#{label}: #{inspect(result)}"
      end
    end

    test "reconcile of a malformed trailing request is conservative, not a crash", ctx do
      for {label, blocks} <- Enum.take(@malformed_trailing, 5) do
        {invocation, stdin} = completed_invocation!(ctx, "Synthetic malformed #{label}")

        Proxy.exchange!(ctx.root, invocation.id,
          request: Proxy.cli_request(stdin, trailing_content: blocks),
          response: Proxy.sse_response(@answer)
        )

        result = captured(fn -> reconcile(ctx, invocation) end)
        assert match?({:ok, %{status: :inferred}}, result), "#{label}: #{inspect(result)}"

        {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        refute link.evidence["projection_version"] == @version, label
        refute Map.has_key?(link.evidence, "reminder_count"), label
      end
    end
  end

  describe "a v2 claim requires exactly the complete context group" do
    test "legal legacy fields are not a complete derived v2 context group", ctx do
      {invocation, stdin} = completed_invocation!(ctx, "Synthetic group review")
      exchange!(ctx, invocation, stdin)

      result = reconcile(ctx, invocation, fn _ -> %{"outcome" => "complete"} end)
      assert {:ok, %{status: :inferred}} = result

      assert {:ok, [%{link_status: :inferred} = link]} =
               Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

      assert "evidence_contract_invalid" in link.evidence["reason_codes"]
      refute link.evidence["projection_version"] == @version
    end

    test "a complete group plus a legacy key cannot overwrite base evidence", ctx do
      for {label, extra} <- [
            {"outcome", %{"outcome" => "complete"}},
            {"classification", %{"classification" => "primary"}},
            {"reason_codes", %{"reason_codes" => []}}
          ] do
        {invocation, stdin} = completed_invocation!(ctx, "Synthetic overwrite #{label}")
        exchange!(ctx, invocation, stdin)

        result = reconcile(ctx, invocation, &Map.merge(&1, extra))
        assert match?({:ok, %{status: :inferred}}, result), "#{label}: #{inspect(result)}"
        {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        assert "evidence_contract_invalid" in link.evidence["reason_codes"], label
      end
    end

    test "persisted reconciled v2 claims require their complete context group", ctx do
      {invocation, stdin} = completed_invocation!(ctx, "Synthetic persisted claim")
      ref = exchange!(ctx, invocation, stdin)
      base = %{"projection_version" => @version, "classification" => "primary"}

      for {label, status, evidence} <- [
            {"reconciled, no group", :reconciled, base},
            {"mismatch, no group", :mismatch, base},
            {"inferred, no group", :inferred, base},
            {"reconciled, partial group", :reconciled,
             Map.merge(base, Map.delete(group(), "request_extras_sha256"))}
          ] do
        result = link(invocation, ref, status, evidence, ctx)
        assert match?({:error, _}, result), "#{label}: #{inspect(result)}"
      end

      assert {:ok, %{link_status: :reconciled}} =
               link(invocation, ref, :reconciled, Map.merge(base, group()), ctx)
    end

    test "v1 evidence and singleton fields stay backward compatible", ctx do
      {invocation, stdin} = completed_invocation!(ctx, "Synthetic v1 compat")
      ref = exchange!(ctx, invocation, stdin)

      evidence = %{"projection_version" => Projection.version(), "classification" => "primary"}
      assert {:ok, _} = link(invocation, ref, :inferred, evidence, ctx)
      # Per-key filtering of untrusted proxy metadata still validates singletons.
      assert {:ok, _} = WitnessEvidence.validate(%{"outcome" => "complete"})
    end
  end

  ## Helpers

  # An exception is captured as a value so that the retained assertion (not
  # the raise) is what fails; this is neither assert_raise nor a success path.
  defp captured(fun) do
    fun.()
  rescue
    exception -> {:raised, exception.__struct__}
  end

  defp projection_inputs(prompt) do
    app = %{
      request: Jason.encode!(%{prompt: prompt, schema: @schema}),
      response: Jason.encode!([%{type: "result", result: @answer}])
    }

    invocation = %{
      model_id: "claude-opus-5-5",
      model_catalog_entry: ClaudeCLI.provenance().model_catalog_entry
    }

    {invocation, app, ClaudeCLI.render_prompt(prompt, @schema)}
  end

  defp completed_invocation!(ctx, prompt) do
    attrs =
      AgentsFixtures.model_attrs("v2-review-#{System.unique_integer([:positive])}")
      |> Map.merge(%{
        provider: :claude_cli,
        provider_version: ClaudeCLI.provenance().provider_version,
        model_id: "claude-opus-5-5",
        model_catalog_entry: ClaudeCLI.provenance().model_catalog_entry,
        request: Jason.encode!(%{prompt: prompt, schema: @schema})
      })

    {:ok, invocation} = Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.agent)
    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: ctx.agent)

    completion =
      AgentsFixtures.completion()
      |> Map.merge(%{
        response: Jason.encode!([%{type: "result", result: @answer}]),
        parsed_output: %{"answer" => "yes"}
      })

    {:ok, invocation} = Agents.complete_model_invocation(invocation, completion, actor: ctx.agent)
    {invocation, ClaudeCLI.render_prompt(prompt, @schema)}
  end

  defp exchange!(ctx, invocation, stdin) do
    Proxy.exchange!(ctx.root, invocation.id,
      request: Proxy.cli_request(stdin),
      response: Proxy.sse_response(@answer)
    )
  end

  defp entry(invocation) do
    %{
      provider: :claude_cli,
      cli_version: invocation.provider_version,
      projection_version: @version,
      method: :propagated_id
    }
  end

  defp reconcile(ctx, invocation, tamper \\ nil) do
    opts = [actor: ctx.rec, store_root: ctx.root, methods: [entry(invocation)]]
    opts = if tamper, do: Keyword.put(opts, :evidence_tamper, tamper), else: opts
    Witness.reconcile(invocation.id, opts)
  end

  defp link(invocation, ref, status, evidence, ctx) do
    Agents.link_wire_witness(
      %{
        model_invocation_id: invocation.id,
        proxy_record_ref: ref,
        link_status: status,
        method: :propagated_id,
        evidence: evidence
      },
      actor: ctx.rec
    )
  end

  defp group do
    %{
      "reminder_count" => 0,
      "reminder_sha256s" => [],
      "reminder_bytes" => [],
      "trailing_system_count" => 1,
      "trailing_system_sha256s" => [String.duplicate("a1", 32)],
      "trailing_system_bytes" => [10],
      "request_extras_sha256" => String.duplicate("b2", 32),
      "request_fields" => ["thinking_present"]
    }
  end
end
