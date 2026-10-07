defmodule SdrAgent.Agents.Witness.ReviewRegressionsTest do
  @moduledoc """
  Codex review regressions for PR #21 @225af68 (verdict 013232c0), adopted
  verbatim as RED: mismatch erasure, vanished primary, unsupported
  ancillary, out-of-order SSE, scan starvation, interrupted Operation,
  unaudited auditor enqueue.
  """
  use SdrAgent.AuditCase, async: false
  use Oban.Testing, repo: SdrAgent.Repo

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.Witness.ScanWorker
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  unless Code.ensure_loaded?(Proxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  @schema %{"type" => "object"}
  @prompt "Review synthetic qualification"
  @answer ~s({"answer":"yes"})

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, max_model_calls: 100)

    root =
      Path.join(System.tmp_dir!(), "sdr-witness-review-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:sdr_agent, Witness)

    Application.put_env(:sdr_agent, Witness,
      store_root: root,
      reconciled_methods: [],
      allow_method_override: true
    )

    on_exit(fn ->
      Application.put_env(:sdr_agent, Witness, previous)
      File.rm_rf!(root)
    end)

    %{tenant: tenant, run: run, agent: agent, root: root, rec: system_actor(:reconciler, tenant)}
  end

  defp invocation!(ctx, key) do
    attrs =
      AgentsFixtures.model_attrs(key)
      |> Map.merge(%{
        provider: :claude_cli,
        model_id: "claude-opus-5-5",
        model_catalog_entry: ClaudeCLI.provenance().model_catalog_entry,
        request:
          Jason.encode!(%{id: key, operation: "model.complete", prompt: @prompt, schema: @schema})
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
    invocation
  end

  defp exchange!(ctx, invocation, answer \\ @answer) do
    Proxy.exchange!(ctx.root, invocation.id,
      request: Proxy.messages_request(ClaudeCLI.render_prompt(@prompt, @schema)),
      response: Proxy.sse_response(answer)
    )
  end

  defp reconcile(ctx, invocation),
    do: Witness.reconcile(invocation.id, actor: ctx.rec, methods: [:propagated_id])

  test "a missing blob cannot erase an established mismatch under the same projector", ctx do
    invocation = invocation!(ctx, "review-mismatch")
    ref = exchange!(ctx, invocation, ~s({"answer":"no"}))
    assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation)
    path = Path.join([ctx.root, "witnesses", invocation.id, ref <> ".json"])
    digest = path |> File.read!() |> Jason.decode!() |> Map.fetch!("response_sha256")

    File.rm!(
      Path.join([ctx.root, "witness", "sha256", binary_part(digest, 0, 2), digest <> ".json"])
    )

    assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation)
    assert {:ok, :mismatch} = Agents.witness_status(invocation.id, actor: ctx.rec)
  end

  test "a deleted primary in otherwise valid inventory cannot retain reconciled assurance", ctx do
    invocation = invocation!(ctx, "review-deleted")
    ref = exchange!(ctx, invocation)

    Proxy.exchange!(ctx.root, invocation.id,
      route: "/anthropic/v1/messages/count_tokens",
      request: "{}",
      response: ~s({"input_tokens":12})
    )

    assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation)
    dir = Path.join([ctx.root, "witnesses", invocation.id])
    File.rm!(Path.join(dir, ref <> ".json"))
    File.rm!(Path.join(dir, ref <> ".started.json"))
    assert {:ok, %{status: :inferred}} = reconcile(ctx, invocation)
    assert {:ok, :inferred} = Agents.witness_status(invocation.id, actor: ctx.rec)
  end

  test "an unsupported ancillary proxy version cannot preserve reconciled assurance", ctx do
    invocation = invocation!(ctx, "review-version")
    exchange!(ctx, invocation)

    Proxy.exchange!(ctx.root, invocation.id,
      route: "/anthropic/v1/messages/count_tokens",
      extra: %{"proxy_version" => "future-unsupported"},
      request: "{}",
      response: ~s({"input_tokens":12})
    )

    assert {:ok, %{status: :inferred}} = reconcile(ctx, invocation)
  end

  test "successive bounded scans advance beyond the same first fifty invocations", ctx do
    for n <- 1..51, do: invocation!(ctx, "review-scan-#{n}")
    assert :ok = ScanWorker.perform(%Oban.Job{})
    assert length(all_enqueued(worker: SdrAgent.Agents.Witness.ReconcileWorker)) == 50
    assert :ok = ScanWorker.perform(%Oban.Job{})
    assert length(all_enqueued(worker: SdrAgent.Agents.Witness.ReconcileWorker)) == 51
  end

  test "an auditor's enqueue mutation is denied and audited once", ctx do
    invocation = invocation!(ctx, "review-denial")
    auditor = human(:auditor, ctx.tenant)
    assert {:error, %Ash.Error.Forbidden{}} = Witness.enqueue(invocation.id, actor: auditor)
    assert [_denial] = events_of_type(ctx.tenant, "authz.denied")
  end

  test "a resumed running Operation reflects the third Oban attempt and discards on failure",
       ctx do
    invocation = invocation!(ctx, "review-interrupted")
    exchange!(ctx, invocation)
    {:ok, operation} = Witness.enqueue(invocation.id, actor: ctx.rec)
    {:ok, _started} = SdrAgent.Operations.start_operation(operation, actor: ctx.rec)
    [job] = all_enqueued(worker: SdrAgent.Agents.Witness.ReconcileWorker)

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE FUNCTION review_refuse_access() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'review access unavailable'; END; $$
    """)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER review_refuse_access BEFORE INSERT ON audit_accesses " <>
        "FOR EACH ROW EXECUTE FUNCTION review_refuse_access()"
    )

    assert {:error, _} = SdrAgent.Agents.Witness.ReconcileWorker.perform(%{job | attempt: 3})
    {:ok, settled} = SdrAgent.Operations.get_operation(operation.id, actor: ctx.rec)
    assert settled.status == :discarded
  end

  test "out-of-order SSE must be unsupported rather than a matching proof", ctx do
    invocation = invocation!(ctx, "review-sse")

    app = %{
      request: Jason.encode!(%{prompt: @prompt, schema: @schema}),
      response: Jason.encode!([%{type: "result", result: @answer}])
    }

    raw = Proxy.sse_response(@answer)
    frames = String.split(raw, "\n\n", trim: true)
    raw = Enum.join([List.last(frames) | Enum.drop(frames, -1)], "\n\n") <> "\n\n"

    assert {:unsupported, _} =
             Projection.compare(
               invocation,
               app,
               Proxy.messages_request(ClaudeCLI.render_prompt(@prompt, @schema)),
               raw
             )
  end
end
