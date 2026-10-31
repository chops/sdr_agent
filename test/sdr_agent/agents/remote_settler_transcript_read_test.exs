defmodule SdrAgent.Agents.RemoteSettlerTranscriptReadTest do
  @moduledoc """
  S-B3 RED addition for plan r3 delta D1 (4b1af2e6; Codex PASS
  codex-sb3-r3-delta-review-20261031.org) and pick 1.

  Contract specified here:

  - the `RemoteCallResult` `:transcript` field policy gains exactly one
    settlement branch, `{SdrAgent.Agents.Checks.RemoteCallsScope, read:
    :settlement}`, beside the existing `IntegrityRead`;
  - that branch passes only for a settlement marker RemoteCalls registers
    internally against the current process, transaction and scope ref:
    a plain open scope whose context carries a forged settlement key, a
    captured (forged) context reused after the scope returns, and the same
    context copied into another process while the scope is open, all keep
    the transcript a `%Ash.ForbiddenField{}` (or read nothing);
  - an init-attestation drift settled by the settler opens one critical
    `:provider_error` Failure for the invocation, as the local path does;
    a non-drift settlement failure (an unparseable transcript) opens none.

  The settlement-branch structural guard runs first in each scope test,
  so before GREEN they fail on the missing branch, never vacuously pass.
  Synthetic transcripts only; no model, no CLI, no network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents.Checks.RemoteCallsScope
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.RemoteSettlerFixtures, as: S

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  ## Helpers

  defp completed!(fx) do
    %{worker: worker, token: token} = F.enrol!(fx)
    F.reserve!(fx)
    nonce = F.nonce()
    launch = F.claim!(token, nonce)
    bytes = F.transcript("settlement-read")

    assert F.kind(F.complete(token, nonce, launch.call_id, launch.request_sha256, bytes)) ==
             :accepted

    mac = struct(Actor, type: :mac_worker, id: worker.id, tenant_id: fx.tenant.id)
    %{launch: launch, bytes: bytes, mac: mac}
  end

  # The :transcript field policy's checks (module and options).
  defp transcript_checks do
    resource = F.loaded!(F.result_resource())

    for policy <- Ash.Policy.Info.field_policies_for_field(resource, :transcript),
        check <- policy.policies,
        do: {check.check_module, check.check_opts}
  end

  defp settlement_branch!() do
    checks = transcript_checks()

    assert Enum.any?(checks, fn {module, opts} ->
             module == RemoteCallsScope and is_list(opts) and opts[:read] == :settlement
           end),
           "the :transcript field policy has no {RemoteCallsScope, read: :settlement} branch: " <>
             inspect(checks)
  end

  # Every row any read action of RemoteCallResult returns with `context`.
  defp read_rows(life, context) do
    result_resource = F.loaded!(F.result_resource())

    for action <- Ash.Resource.Info.actions(result_resource),
        action.type == :read,
        {:ok, rows} <- [
          F.safely(fn ->
            Ash.read(result_resource, action: action.name, actor: life.mac, context: context)
          end)
        ],
        row <- rows,
        do: row
  end

  defp assert_no_bytes!(life, rows, label) do
    for row <- rows do
      assert match?(%Ash.ForbiddenField{}, row.transcript),
             "#{label}: the transcript field is readable: #{inspect(row.transcript)}"

      refute String.contains?(inspect(row, limit: :infinity), life.bytes),
             "#{label}: transcript bytes reached the row"
    end
  end

  # Context variants a caller could hand-build to claim the settlement read.
  defp forged(context) do
    [
      Map.put(context, :settlement, true),
      Map.put(context, :read, :settlement),
      Map.put(context, :sdr_agent_remote_calls_settlement, true),
      Map.put(context, :sdr_agent_remote_calls_settlement, make_ref()),
      Map.put(context, :remote_settler, true)
    ]
  end

  defp failure_count(invocation_id, class, severity) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM failures WHERE subject_id = $1 AND class = $2 AND severity = $3",
        [F.dump(invocation_id), class, severity]
      )

    n
  end

  ## D1: the settlement read is internal only

  test "D1: the :transcript field policy keeps IntegrityRead and adds the settlement branch" do
    settlement_branch!()

    assert Enum.any?(transcript_checks(), fn {module, _opts} ->
             module == SdrAgent.Audit.Checks.IntegrityRead
           end),
           "IntegrityRead branch missing: #{inspect(transcript_checks())}"
  end

  test "D1: a plain open scope with a forged settlement context exposes no bytes", %{fx: fx} do
    settlement_branch!()
    life = completed!(fx)

    rows =
      F.with_scope(fn context ->
        control = read_rows(life, context)
        assert control != [], "control: the open scope reads the result metadata"
        assert_no_bytes!(life, control, "plain scope")
        Enum.flat_map(forged(context), &read_rows(life, &1))
      end)

    assert is_list(rows), "with_scope: #{inspect(rows)}"
    assert_no_bytes!(life, rows, "forged settlement context")
  end

  test "D1: a captured forged context reused after the scope returns exposes no bytes",
       %{fx: fx} do
    settlement_branch!()
    life = completed!(fx)

    captured = F.with_scope(fn context -> forged(context) end)
    assert is_list(captured), "with_scope did not return the contexts: #{inspect(captured)}"

    for context <- captured do
      assert_no_bytes!(life, read_rows(life, context), "after with_scope")
    end
  end

  # The settlement branch's own decision for `context` (policy only, no query,
  # safe from a process without the connection).
  defp settlement?(actor, context),
    do: RemoteCallsScope.match?(actor, %{subject: %{context: context}}, read: :settlement)

  test "D1: an open scope, its forged contexts and their copies in another process never pass the settlement branch",
       %{fx: fx} do
    settlement_branch!()
    life = completed!(fx)

    outcome =
      F.with_scope(fn context ->
        contexts = [context | forged(context)]
        here = Enum.map(contexts, &settlement?(life.mac, &1))

        other =
          fn -> Enum.map(contexts, &settlement?(life.mac, &1)) end
          |> Task.async()
          |> Task.yield(10_000)

        {here, other}
      end)

    assert match?({here, {:ok, other}} when is_list(here) and is_list(other), outcome),
           "with_scope or the other process did not return: #{inspect(outcome)}"

    {here, {:ok, other}} = outcome

    assert Enum.all?(here, &(&1 == false)),
           "a plain or forged context passed here: #{inspect(here)}"

    assert Enum.all?(other, &(&1 == false)), "another process passed: #{inspect(other)}"
  end

  ## Pick 1: drift opens the local path's critical Failure

  test "pick 1: settled init-attest drift opens one critical provider_error Failure", %{fx: fx} do
    transcript =
      S.stream([S.init_event(%{"model" => "claude-sb3-drift-model"}), S.result_event()])

    c = S.completed!(fx, transcript)
    S.settle!(fx)

    assert S.invocation_row(c.invocation.id)["status"] == "failed"
    assert failure_count(c.invocation.id, "provider_error", "critical") == 1
  end

  test "pick 1: a non-drift settlement failure opens no provider_error Failure", %{fx: fx} do
    c = S.completed!(fx, "this is not a stream-json transcript\n")
    S.settle!(fx)

    assert S.invocation_row(c.invocation.id)["status"] == "failed"
    assert failure_count(c.invocation.id, "provider_error", "critical") == 0
    assert failure_count(c.invocation.id, "provider_error", "warning") == 0
  end
end
