defmodule SdrAgent.Prototype.FinalizeContractTest do
  @moduledoc """
  IF-4 finalize contract (interfaces r6; F1), D-237 slice S2.

  - **Only caller (xref).** `SdrAgent.Prototype.Release` is referenced by
    exactly one module, `SdrAgent.Agents.ResultGate`, whose `finalize/4`
    dispatches to it at its head in prototype runtime. Recovery, the
    stale-run sweeper and every other module never reference it.
  - **The partition is read at the dispatch sites.** The admission gate
    (`gate.ex:128,156`) and the result gate (`result_gate.ex:275`) read
    `SdrAgent.Prototype.runtime/0`.
  - **The prototype gate's own Prelocked context.** `released_unverified`
    is decided only inside the prototype gate's `Prelocked.run/2` context,
    which binds `finalizer: :prototype_gate`; any other finalizer value is
    refused before the decision function runs, and an ordinary context
    carries none.

  - **Prototype runtime (RED-b1).** `{:interrupted, receipt}` never releases
    (`gate_interrupted`, or `witness_mismatch` for a known mismatch);
    `{:timeout, receipt}` keeps its classification (`witness_timeout`,
    `capture_pending`). That no option other than `guard:` reaches the
    decision is shown with S1's provisioned grant (RED-b2).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.PrototypeGateFixtures

  @release SdrAgent.Prototype.Release

  # Every module of the application (lib and test support) whose compiled
  # code calls a function of `target`.
  defp referrers(target) do
    for module <- Application.spec(:sdr_agent, :modules),
        module != target,
        target in Enum.map(imports(module), &elem(&1, 0)),
        do: module
  end

  # The external calls ({module, function, arity}) of `module`'s beam.
  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _no_beam -> []
    end
  end

  defp bindings do
    %{tenant_id: Ecto.UUID.generate(), model_invocation_id: Ecto.UUID.generate()}
  end

  defp in_transaction(fun) do
    {:ok, result} = Repo.transaction(fun)
    result
  end

  describe "only caller (xref)" do
    test "SdrAgent.Prototype.Release is referenced only by ResultGate, which dispatches to it" do
      assert referrers(@release) == [SdrAgent.Agents.ResultGate],
             "the modules referencing #{inspect(@release)} are " <>
               "#{inspect(referrers(@release))}, not exactly [SdrAgent.Agents.ResultGate]"
    end

    test "the admission gate and the result gate read the runtime partition" do
      for module <- [SdrAgent.Agents.Admission.Gate, SdrAgent.Agents.ResultGate] do
        assert {SdrAgent.Prototype, :runtime, 0} in imports(module),
               "#{inspect(module)} does not dispatch on SdrAgent.Prototype.runtime/0"
      end
    end
  end

  describe "the prototype gate's Prelocked finalizer binding" do
    test "finalizer: :prototype_gate is registered with the context and verified" do
      result =
        in_transaction(fn ->
          Prelocked.run(Map.put(bindings(), :finalizer, :prototype_gate), fn context ->
            {Map.get(context, :finalizer), Prelocked.verify(context)}
          end)
        end)

      assert match?({:prototype_gate, {:ok, %{finalizer: :prototype_gate}}}, result),
             "the prototype gate's context did not bind its finalizer: #{inspect(result)}"
    end

    test "any other finalizer value is refused before the decision runs" do
      for finalizer <- [:ordinary_gate, "prototype_gate", true] do
        result =
          in_transaction(fn ->
            Prelocked.run(Map.put(bindings(), :finalizer, finalizer), fn _context -> :ran end)
          end)

        assert result == {:error, :invalid_finalizer},
               "finalizer #{inspect(finalizer)} was not refused: #{inspect(result)}"
      end
    end

    test "an ordinary context carries no finalizer, and a copy claiming one is refused" do
      result =
        in_transaction(fn ->
          Prelocked.run(bindings(), fn context ->
            {Map.get(context, :finalizer),
             Prelocked.verify(Map.put(context, :finalizer, :prototype_gate))}
          end)
        end)

      assert result == {nil, {:error, :prelocked_context_refused}}
    end
  end

  describe "prototype runtime: interrupted and timed-out gates never release" do
    setup do
      # Before provisioning (RED-b1): an invocation completed before
      # prototype runtime (no recorded authority); interrupted and timed-out
      # outcomes are decided before the authority.
      fx = PrototypeGateFixtures.pre_runtime!()
      %{fx: fx, run: fx.run, invocation: fx.invocation}
    end

    defp classification(fx, release) do
      [event] = PrototypeGateFixtures.release_events(fx, "model.result.withheld", release)
      event.payload["arguments"]["gate_classification"]
    end

    test "{:interrupted, receipt} with no known evidence is withheld gate_interrupted", ctx do
      outcome = {:interrupted, PrototypeGateFixtures.absent_receipt()}
      result = PrototypeGateFixtures.finalize(ctx.invocation, ctx.run, outcome)

      assert match?(
               {:withheld, %{reason: :gate_interrupted}, %{status_reason: :witness_unreconciled}},
               result
             ),
             inspect(result)

      {:withheld, release, _run} = result
      assert classification(ctx.fx, release) == "interrupted"
    end

    test "{:interrupted, receipt} with a known mismatch link is withheld witness_mismatch", ctx do
      rec = system_actor(:reconciler, ctx.fx.tenant)
      SdrAgent.AgentsFixtures.reconciled_link!(ctx.invocation, rec, link_status: :mismatch)
      outcome = {:interrupted, PrototypeGateFixtures.absent_receipt()}
      result = PrototypeGateFixtures.finalize(ctx.invocation, ctx.run, outcome)

      assert match?(
               {:withheld, %{reason: :witness_mismatch}, %{status_reason: :witness_mismatch}},
               result
             ),
             inspect(result)
    end

    test "{:timeout, receipt} keeps its classification: witness_timeout, capture_pending", ctx do
      outcome = {:timeout, PrototypeGateFixtures.absent_receipt()}
      result = PrototypeGateFixtures.finalize(ctx.invocation, ctx.run, outcome)

      assert match?({:withheld, %{reason: :witness_timeout}, _}, result), inspect(result)
      {:withheld, release, _run} = result
      assert classification(ctx.fx, release) == "capture_pending"
    end
  end
end
