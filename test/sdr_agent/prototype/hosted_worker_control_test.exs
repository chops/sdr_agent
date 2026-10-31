defmodule SdrAgent.Prototype.HostedWorkerControlTest do
  @moduledoc """
  S-B5 worker-control RED: current hosted owner only, exact binding,
  terminal disable, no delegated privilege or broad default read. Synthetic
  fixtures; these controls never invoke a model or claim a call.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.Actor
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Operations
  alias SdrAgent.Operations.MacWorker
  alias SdrAgent.Prototype.Checks.OperatorAction
  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    enrolled = H.enrol!(ctx)
    Map.merge(ctx, %{admin: admin, enrolled: enrolled})
  end

  defp enrol(actor),
    do: call(Operations, :enrol_mac_worker, [%{profile_pins: F.pins()}, [actor: actor]])

  defp enrol!(actor) do
    assert {:ok, worker} = enrol(actor)
    worker
  end

  defp list(actor), do: call(Operations, :list_mac_workers, [[actor: actor]])

  defp intake(worker, value, actor),
    do: call(Operations, :set_mac_worker_intake, [worker, value, [actor: actor]])

  defp disable(worker, actor),
    do: call(Operations, :disable_mac_worker, [worker, [actor: actor]])

  defp event_count(type) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM audit_events WHERE event_type=$1", [type])

    count
  end

  test "current owner enrols one current-binding worker and lists it without the token", ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)
    token = Ash.Resource.get_metadata(worker, :token)
    assert is_binary(token) and byte_size(token) == 32
    assert worker.tenant_id == ctx.fx.tenant.id
    assert worker.binding_id == ctx.fx.binding.id
    assert worker.token_sha256 == :crypto.hash(:sha256, token)
    assert {:ok, [listed]} = list(ctx.enrolled.user)
    assert listed.id == worker.id
    assert Ash.Resource.get_metadata(listed, :token) == nil
    assert event_count("mac_worker.enrolled") == 1
  end

  test "pause and resume affect intake only; disable is terminal", ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)
    assert {:ok, paused} = intake(worker, :paused, ctx.enrolled.user)
    assert paused.status == :active and paused.intake == :paused
    assert {:ok, resumed} = intake(paused, :open, ctx.enrolled.user)
    assert resumed.intake == :open
    assert {:ok, disabled} = disable(resumed, ctx.enrolled.user)
    assert disabled.status == :disabled and disabled.disabled_at != nil
    assert {:error, _} = intake(worker, :open, ctx.enrolled.user)
    assert {:error, _} = disable(worker, ctx.enrolled.user)
    assert event_count("mac_worker.disabled") == 1
    assert event_count("mac_worker.intake_set") == 2
  end

  test "a second active worker is refused, but a terminal worker can be replaced", ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)
    assert {:error, _} = enrol(ctx.enrolled.user)
    assert event_count("mac_worker.enrolled") == 1
    assert {:ok, _} = disable(worker, ctx.enrolled.user)
    replacement = enrol!(ctx.enrolled.user)
    refute replacement.id == worker.id
    assert {:ok, workers} = list(ctx.enrolled.user)
    assert length(workers) == 2
  end

  test "the owner-only control atom is absent from delegated operator actions", ctx do
    H.enter!(ctx)
    assert OperatorAction.match?(ctx.enrolled.user, %{}, action: :mac_worker_control)
    refute :mac_worker_control in OperatorAction.actions()

    delegated = %Actor{
      type: :prototype_operator,
      id: Ecto.UUID.generate(),
      tenant_id: ctx.fx.tenant.id
    }

    refute OperatorAction.match?(delegated, %{}, action: :mac_worker_control)
  end

  test "auditor, legacy humans, delegated actor, forged owner and worker cannot control or list",
       ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)

    for actor <- [
          ctx.fx.auditor,
          ctx.admin,
          ctx.fx.actor,
          %{ctx.enrolled.user | role: :admin},
          %{ctx.enrolled.user | id: Ecto.UUID.generate()},
          %Actor{
            type: :prototype_operator,
            id: Ecto.UUID.generate(),
            tenant_id: ctx.fx.tenant.id
          },
          %Actor{type: :mac_worker, id: worker.id, tenant_id: ctx.fx.tenant.id}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = enrol(actor)
      assert {:error, %Ash.Error.Forbidden{}} = intake(worker, :paused, actor)
      assert {:error, %Ash.Error.Forbidden{}} = disable(worker, actor)
      result = list(actor)
      assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)
    end

    assert event_count("mac_worker.enrolled") == 1
    assert event_count("mac_worker.intake_set") == 0
    assert event_count("mac_worker.disabled") == 0
  end

  test "stale disabled owner cannot operate the retained worker", ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)
    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.enrolled.user)
    assert {:error, %Ash.Error.Forbidden{}} = intake(worker, :open, ctx.enrolled.user)
    assert {:error, %Ash.Error.Forbidden{}} = disable(worker, ctx.enrolled.user)
    assert {:error, _} = enrol(ctx.enrolled.user)
    result = list(ctx.enrolled.user)
    assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)
  end

  test "an older activation owner loses worker control", ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)
    third = %{ctx.destination | database_oid: ctx.destination.database_oid + 1_000}
    H.relocate!(ctx, ctx.destination, third, 2)
    H.enter!(ctx)
    assert {:error, %Ash.Error.Forbidden{}} = intake(worker, :paused, ctx.enrolled.user)
    assert {:error, %Ash.Error.Forbidden{}} = disable(worker, ctx.enrolled.user)
  end

  test "direct owner actions refuse foreign binding or tenant even without the facade", ctx do
    H.enter!(ctx)
    _ = enrol!(ctx.enrolled.user)

    for binding <- [Ecto.UUID.generate(), nil] do
      assert {:error, %Ash.Error.Forbidden{}} =
               MacWorker
               |> Ash.Changeset.for_create(:enrol, %{binding_id: binding, profile_pins: F.pins()},
                 actor: ctx.enrolled.user
               )
               |> Ash.create()
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             enrol(%{ctx.enrolled.user | tenant_id: Ecto.UUID.generate()})

    assert event_count("mac_worker.enrolled") == 1
  end

  test "default worker read stays private despite the explicit owner list", ctx do
    H.enter!(ctx)
    _ = enrol!(ctx.enrolled.user)
    assert {:ok, [_]} = list(ctx.enrolled.user)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(MacWorker, actor: ctx.enrolled.user)
  end

  test "owner updates refuse persisted foreign-binding and foreign-tenant rows unchanged", ctx do
    H.enter!(ctx)
    worker = enrol!(ctx.enrolled.user)

    # Tenant and prototype binding are database singletons. Plant isolated
    # corrupt foreign rows with the existing fault helper; a second fixture
    # world cannot legally coexist. The subject is the public action, not
    # this setup write. The Sandbox owns every inserted row.
    for tenant_id <- [ctx.fx.tenant.id, Ecto.UUID.generate()] do
      id = Ecto.UUID.generate()
      binding_id = Ecto.UUID.generate()

      assert :ok =
               F.copy_insert(
                 MacWorker,
                 "id = $1",
                 [F.dump(worker.id)],
                 [
                   {"id", F.dump(id)},
                   {"binding_id", F.dump(binding_id)},
                   {"tenant_id", F.dump(tenant_id)},
                   {"token_sha256", :crypto.strong_rand_bytes(32)}
                 ], replica: true)

      foreign = Ash.get!(MacWorker, id, authorize?: false)

      before =
        Repo.query!("SELECT row_to_json(w)::text FROM mac_workers w WHERE id=$1", [F.dump(id)]).rows

      assert {:error, %Ash.Error.Forbidden{}} = intake(foreign, :paused, ctx.enrolled.user)
      assert {:error, %Ash.Error.Forbidden{}} = disable(foreign, ctx.enrolled.user)

      assert Repo.query!("SELECT row_to_json(w)::text FROM mac_workers w WHERE id=$1", [
               F.dump(id)
             ]).rows == before
    end

    assert event_count("mac_worker.intake_set") == 0
    assert event_count("mac_worker.disabled") == 0
  end

  test "enrollment token is absent from log and audit payload bytes", ctx do
    H.enter!(ctx)
    parent = self()
    log = capture_log(fn -> send(parent, {:enrolled, enrol!(ctx.enrolled.user)}) end)
    assert_receive {:enrolled, worker}
    token = Ash.Resource.get_metadata(worker, :token)
    encoded = Base.url_encode64(token, padding: false)
    %{rows: rows} = Repo.query!("SELECT payload::text FROM audit_events", [])
    refute String.contains?(log, encoded)
    refute Enum.any?(rows, fn [payload] -> String.contains?(payload, encoded) end)
  end
end
