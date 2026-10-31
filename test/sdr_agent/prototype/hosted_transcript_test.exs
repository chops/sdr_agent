defmodule SdrAgent.Prototype.HostedTranscriptTest do
  @moduledoc """
  S-B5 explicit owner-only diagnostic transcript reads. Synthetic bytes
  through reservation/claim/complete, never a CLI or model process. Metadata
  never carries transcript content; successful disclosure commits one access
  record first, and failure returns no bytes.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.RemoteCallResult
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Prototype.Checks.OperatorAction
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F

  @bytes "synthetic-private-transcript-<script>alert('not executable')</script>"

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    agent = Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    SdrAgent.AdmissionFixtures.admit_tuples!()
    grant = AgentsFixtures.grant!(fx.tenant, %{}, admin)
    run = G.run!(fx)
    fx = Map.merge(fx, %{grant: grant, run: run})
    F.remote!()
    %{worker: worker, token: token} = F.enrol!(fx)
    invocation = F.reserve!(fx)
    nonce = F.nonce()
    launch = F.claim!(token, nonce)

    assert F.kind(F.complete(token, nonce, launch.call_id, launch.request_sha256, @bytes)) ==
             :accepted

    enrolled = H.enrol!(ctx)
    H.enter!(ctx)

    Map.merge(ctx, %{
      admin: admin,
      enrolled: enrolled,
      worker: worker,
      run: run,
      invocation: invocation,
      call_id: launch.call_id
    })
  end

  defp read(id, actor), do: call(Agents, :read_remote_transcript, [id, [actor: actor]])
  defp list(run, actor), do: call(Agents, :list_remote_calls, [run.id, [actor: actor]])

  defp access_rows do
    Repo.query!(
      "SELECT actor_id, target_resource, target_ref, purpose FROM audit_accesses WHERE target_resource=$1",
      [inspect(RemoteCallResult)]
    ).rows
  end

  test "one explicit owner request returns exact bytes and commits one attributed access record",
       ctx do
    assert access_rows() == []
    assert {:ok, result} = read(ctx.call_id, ctx.enrolled.user)
    assert result.call_id == ctx.call_id
    assert result.transcript == @bytes
    assert result.transcript_sha256 == :crypto.hash(:sha256, @bytes)
    assert result.byte_size == byte_size(@bytes)
    assert [[actor, resource, target, purpose]] = access_rows()

    assert {actor, resource, target} ==
             {ctx.enrolled.user.id, inspect(RemoteCallResult), ctx.call_id}

    assert purpose == "remote model transcript diagnostic"
    assert {:ok, _} = read(ctx.call_id, ctx.enrolled.user)
    assert length(access_rows()) == 2
  end

  test "status listing exposes call metadata only and records no content access", ctx do
    assert {:ok, [row]} = list(ctx.run, ctx.enrolled.user)
    assert row.id == ctx.call_id and row.state == :completed
    refute Map.has_key?(row, :transcript)
    refute inspect(row) =~ @bytes
    assert access_rows() == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.read(SdrAgent.Agents.RemoteModelCall, actor: ctx.enrolled.user)
  end

  test "raw default and explicit transcript actions cannot bypass the audited API", ctx do
    _ = read(ctx.call_id, ctx.enrolled.user)

    assert Ash.Resource.Info.action(RemoteCallResult, :owner_transcript),
           "missing named owner action"

    for action <- [:read, :owner_transcript] do
      result =
        RemoteCallResult
        |> Ash.Query.for_read(action, %{}, actor: ctx.enrolled.user)
        |> Ash.read()

      assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result),
             "direct action exposed transcript without access transaction: #{inspect(result)}"
    end

    assert length(access_rows()) == 1
  end

  test "auditor, legacy admin, delegated operator, worker and forged owner get no transcript",
       ctx do
    assert {:ok, _} = read(ctx.call_id, ctx.enrolled.user)

    for actor <- [
          ctx.fx.auditor,
          ctx.admin,
          ctx.fx.actor,
          %{ctx.enrolled.user | id: Ecto.UUID.generate()},
          %{ctx.enrolled.user | role: :admin},
          %Actor{type: :mac_worker, id: ctx.worker.id, tenant_id: ctx.fx.tenant.id}
        ] do
      assert {:error, _} = read(ctx.call_id, actor)
      result = list(ctx.run, actor)
      assert result == {:ok, []} or match?({:error, _}, result)
    end

    assert length(access_rows()) == 1
  end

  test "owner-only transcript action never enters delegated atom namespace", ctx do
    assert OperatorAction.match?(ctx.enrolled.user, %{}, action: :transcript_read)
    refute :transcript_read in OperatorAction.actions()
    refute OperatorAction.match?(ctx.fx.actor, %{}, action: :transcript_read)
  end

  test "disabled owner's stale User and foreign ids return no bytes or access record", ctx do
    assert {:ok, _} = read(ctx.call_id, ctx.enrolled.user)
    assert {:error, _} = read(Ecto.UUID.generate(), ctx.enrolled.user)
    assert {:error, _} = read(ctx.call_id, %{ctx.enrolled.user | tenant_id: Ecto.UUID.generate()})
    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.enrolled.user)
    assert {:error, _} = read(ctx.call_id, ctx.enrolled.user)
    assert length(access_rows()) == 1
  end

  test "failed access append rolls back the access transaction and returns no transcript", ctx do
    assert {:ok, _} = read(ctx.call_id, ctx.enrolled.user)
    before = access_rows()

    Repo.query!(
      """
      CREATE FUNCTION pg_temp.sdr_test_transcript_fault() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'synthetic transcript access fault'; END
      $$ LANGUAGE plpgsql
      """,
      []
    )

    Repo.query!(
      "CREATE TRIGGER sdr_test_transcript_fault BEFORE INSERT ON audit_accesses FOR EACH ROW EXECUTE FUNCTION pg_temp.sdr_test_transcript_fault()",
      []
    )

    result = F.safely(fn -> read(ctx.call_id, ctx.enrolled.user) end)
    refute match?({:ok, _}, result)
    refute inspect(result) =~ @bytes
    assert access_rows() == before
  end

  test "explicit transcript never becomes a log or event payload and does not release output",
       ctx do
    log = capture_log(fn -> assert {:ok, _} = read(ctx.call_id, ctx.enrolled.user) end)
    refute log =~ @bytes
    %{rows: payloads} = Repo.query!("SELECT payload::text FROM audit_events", [])
    refute Enum.any?(payloads, fn [payload] -> String.contains?(payload, @bytes) end)

    %{rows: [[0]]} =
      Repo.query!("SELECT count(*) FROM model_result_releases WHERE model_invocation_id=$1", [
        Ecto.UUID.dump!(ctx.invocation.id)
      ])
  end
end
