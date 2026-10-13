defmodule SdrAgent.Agents.Witness.GateEvidenceTest do
  @moduledoc """
  R0-07 slice C, row G4 (with its section 6.4 bounds): after a withheld
  release, the cause its `model.result.withheld` event binds is
  **protected** under the scan's witness attention.

    * The scan never resolves it.
    * It counts, at its actual severity, as the invocation's live
      attention, so no duplicate is opened.
    * A resolved protected cause stays resolved, and an unchanged
      observation never recreates it under a new id.
    * A distinct later mismatch still opens its critical.
    * Each change of the invocation's C1 status appends one metadata-only
      `agents.witness.gate_evidence_changed` note.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }
  @note "agents.witness.gate_evidence_changed"
  @note_keys ~w(release_id cause_failure_id previous_status current_status current_link_ids)

  setup do
    unless Code.ensure_loaded?(Proxy),
      do: Code.require_file(Path.expand("../../../support/fake_witness_proxy.exs", __DIR__))

    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    root = GateFixtures.root!()
    previous = AgentsFixtures.put_allowlist!([@v3_opus])
    config = Application.get_env(:sdr_agent, ResultGate)
    Application.put_env(:sdr_agent, ResultGate, wait_ms: 300, poll_ms: 25)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:sdr_agent, Witness, previous)
      Application.put_env(:sdr_agent, ResultGate, config)
    end)

    %{run: run, agent: agent} = AgentsFixtures.operated_run(tenant)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      root: root,
      rec: system_actor(:reconciler, tenant),
      admin: human(:admin, tenant)
    }
  end

  # The facade's gate step: a withheld release whose event binds `cause`.
  defp gated!(ctx, variant) do
    invocation = GateFixtures.call_model!(ctx, variant)
    gate = %{run_id: ctx.run.id, operation_id: ctx.run.operation_id}

    assert {:withheld, release, run} =
             ResultGate.gate(invocation, gate, store_root: ctx.root)

    {invocation, release, failure!(ctx, run.attention_failure_id)}
  end

  defp scan(ctx, invocation),
    do: Witness.reconcile(invocation.id, actor: ctx.rec, store_root: ctx.root)

  defp failure!(ctx, id) do
    {:ok, failure} = Operations.get_failure(id, actor: ctx.admin)
    failure
  end

  defp live(ctx, invocation) do
    {:ok, all} = Operations.list_attention(actor: ctx.admin)
    Enum.filter(all, &(&1.subject_id == invocation.id and &1.status in [:open, :acknowledged]))
  end

  defp resolve!(ctx, failure) do
    {:ok, _} = Operations.resolve_failure(failure, %{resolution_note: "seen"}, actor: ctx.admin)
  end

  defp notes(ctx, release) do
    ctx.tenant |> events_of_type(@note) |> Enum.filter(&(&1.subject_id == release.id))
  end

  test "a changed condition never resolves the protected warning; one note per change", ctx do
    AgentsFixtures.put_allowlist!([])
    {invocation, release, cause} = gated!(ctx, "cli_shape_v3")
    assert {release.reason, cause.severity} == {:witness_missing, :warning}

    AgentsFixtures.put_allowlist!([@v3_opus])
    assert {:ok, %{status: :reconciled}} = scan(ctx, invocation)
    assert failure!(ctx, cause.id).status == :open

    assert [note] = notes(ctx, release)
    assert Enum.sort(Map.keys(note.payload)) == Enum.sort(@note_keys)

    assert {note.payload["previous_status"], note.payload["current_status"]} ==
             {"inferred", "reconciled"}

    assert {note.payload["release_id"], note.payload["cause_failure_id"]} ==
             {release.id, cause.id}

    assert {note.model_invocation_id, note.agent_run_id} == {invocation.id, ctx.run.id}

    assert {:ok, %{status: :reconciled}} = scan(ctx, invocation)
    assert [_one] = notes(ctx, release)
  end

  test "a late gate-mode reconcile honours the protection too (review MF3)", ctx do
    AgentsFixtures.put_allowlist!([])
    {invocation, _release, cause} = gated!(ctx, "cli_shape_v3")

    AgentsFixtures.put_allowlist!([@v3_opus])
    gate = %{run_id: ctx.run.id, operation_id: ctx.run.operation_id}

    assert {:ok, %{status: :reconciled}} =
             Witness.reconcile(invocation.id, actor: ctx.rec, store_root: ctx.root, gate: gate)

    assert failure!(ctx, cause.id).status == :open
  end

  test "the protected warning is the live warning: no duplicate, no note", ctx do
    {invocation, release, cause} = gated!(ctx, "none")
    before = live(ctx, invocation)
    assert cause.id in Enum.map(before, & &1.id)

    assert {:ok, %{status: :unwitnessed}} = scan(ctx, invocation)

    assert Enum.map(live(ctx, invocation), & &1.id) |> Enum.sort() ==
             Enum.map(before, & &1.id) |> Enum.sort()

    assert notes(ctx, release) == []
  end

  test "a resolved protected cause stays resolved; an unchanged observation opens none", ctx do
    {invocation, _release, cause} = gated!(ctx, "none")
    Enum.each(live(ctx, invocation), &resolve!(ctx, &1))

    assert {:ok, %{status: :unwitnessed}} = scan(ctx, invocation)
    assert live(ctx, invocation) == []
    assert failure!(ctx, cause.id).status == :resolved
  end

  test "a protected mismatch critical is not duplicated when the mismatch recurs", ctx do
    {invocation, release, cause} = gated!(ctx, "cli_shape_v3_mismatch")
    assert {release.reason, cause.severity} == {:witness_mismatch, :critical}

    assert {:ok, %{status: :mismatch}} = scan(ctx, invocation)
    assert [%{id: id}] = Enum.filter(live(ctx, invocation), &(&1.severity == :critical))
    assert id == cause.id

    resolve!(ctx, cause)
    assert {:ok, %{status: :mismatch}} = scan(ctx, invocation)
    assert Enum.filter(live(ctx, invocation), &(&1.severity == :critical)) == []
  end

  test "a resolved distinct mismatch is not reopened while the C1 status stays mismatch (review MF4)",
       ctx do
    {invocation, release, cause} = gated!(ctx, "cli_shape_v3_mismatch")
    resolve!(ctx, cause)

    # A later link time than the release's (the clock is per process).
    SdrAgent.Clock.freeze(DateTime.add(release.decided_at, 1, :second))
    on_exit(&SdrAgent.Clock.unfreeze/0)

    inventory = Path.join([ctx.root, "witnesses", invocation.id])
    for entry <- File.ls!(inventory), do: File.rm!(Path.join(inventory, entry))

    Proxy.exchange!(ctx.root, invocation.id,
      request:
        Proxy.cli_request("a different synthetic mismatch",
          cache_ttl: "1h",
          trailing_message_extra: %{"output_config" => %{"effort" => "high"}}
        ),
      response: Proxy.sse_response(~s({"answer":"qualified","score":42}))
    )

    assert {:ok, %{status: :mismatch, links: links}} = scan(ctx, invocation)
    assert Enum.count(links, &(&1.link_status == :mismatch)) >= 2
    assert [later] = Enum.filter(live(ctx, invocation), &(&1.severity == :critical))
    resolve!(ctx, later)

    assert {:ok, %{status: :mismatch}} = scan(ctx, invocation)
    assert Enum.filter(live(ctx, invocation), &(&1.severity == :critical)) == []
    assert notes(ctx, release) == []
  end

  test "a distinct later mismatch still opens its own critical", ctx do
    {invocation, release, cause} = gated!(ctx, "none")
    assert cause.severity == :warning

    Proxy.exchange!(ctx.root, invocation.id,
      request:
        Proxy.cli_request("an unrelated later prompt",
          cache_ttl: "1h",
          trailing_message_extra: %{"output_config" => %{"effort" => "high"}}
        ),
      response: Proxy.sse_response(~s({"answer":"qualified","score":42}))
    )

    assert {:ok, %{status: :mismatch}} = scan(ctx, invocation)
    assert [critical] = Enum.filter(live(ctx, invocation), &(&1.severity == :critical))
    refute critical.id == cause.id
    assert failure!(ctx, cause.id).status == :open
    assert [%{payload: %{"current_status" => "mismatch"}}] = notes(ctx, release)
  end
end
