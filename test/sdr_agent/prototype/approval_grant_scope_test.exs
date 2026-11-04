defmodule SdrAgent.Prototype.ApprovalGrantScopeTest do
  @moduledoc "Synthetic allow/deny and historical-source checks for S4's two-field grant projection."
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Output

  defp approved do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    Map.put(ctx, :approval, approval)
  end

  defp scope(ctx, actor \\ nil) do
    actor = actor || ctx.operator

    %{
      tenant_id: actor.tenant_id,
      delegation_id: actor.id,
      approval_id: ctx.approval.id,
      anchor_id: ctx.anchor.id
    }
  end

  defp project(id, actor, scope) do
    assert Ash.Resource.Info.action(AuditEvent, :read_prototype_approval_grant),
           "missing the scoped approval-grant projection action"

    call(Audit, :read_prototype_approval_grant, [
      id,
      [
        actor: actor,
        context: if(scope, do: %{sdr_prototype_approval_grant_scope: scope}, else: %{})
      ]
    ])
  end

  test "the authorized action returns exactly two historical fields and records access" do
    ctx = approved()
    assert {:ok, metadata} = project(ctx.approval.id, ctx.operator, scope(ctx))

    assert metadata == %{
             "approval_mode" => "delegated_machine",
             "delegation_id" => ctx.operator.id
           }

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_accesses WHERE purpose = 'd237_prototype_approval_grant'"
      )

    assert count == 1
  end

  test "a second live session sees the original approving delegation, never itself" do
    ctx = approved()
    assert {:ok, _} = project(ctx.approval.id, ctx.operator, scope(ctx))
    assert {:ok, delegation_id} = Prototype.enter_session(:claude_code, "second-grant-session-01")
    assert {:ok, other} = Prototype.operator_actor(delegation_id)
    refute other.id == ctx.operator.id
    assert {:ok, view} = Output.view(:approval, ctx.approval.id, other)
    assert view["fields"]["delegation_id"] == ctx.operator.id
    refute view["fields"]["delegation_id"] == other.id
  end

  test "no scope and each forged binding field deny the action" do
    ctx = approved()
    base = scope(ctx)

    scopes = [nil] ++ Enum.map(Map.keys(base), &Map.put(base, &1, Ecto.UUID.generate()))

    for candidate <- scopes do
      assert {:error, :forbidden} = project(ctx.approval.id, ctx.operator, candidate)
    end
  end

  test "a scope for one approval cannot name another action argument" do
    ctx = approved()

    assert {:error, :forbidden} =
             project(Ecto.UUID.generate(), ctx.operator, scope(ctx))
  end

  test "humans, system actors, nil and a forged operator never obtain grant metadata" do
    ctx = approved()

    for actor <- [
          ctx.admin,
          ctx.agent,
          nil,
          %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}
        ] do
      assert {:error, :forbidden} = project(ctx.approval.id, actor, scope(ctx))
    end
  end

  test "ordinary runtime and a live binding mismatch deny before returning metadata" do
    ctx = approved()
    assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok
    assert {:error, :forbidden} = project(ctx.approval.id, ctx.operator, scope(ctx))
    assert PrototypeFixtures.leave_runtime() == :ok
    assert {:error, :forbidden} = project(ctx.approval.id, ctx.operator, scope(ctx))
  end

  test "an absent grant refuses rather than inventing approval metadata" do
    ctx = approved()
    missing = Ecto.UUID.generate()

    assert {:error, :not_found} =
             project(missing, ctx.operator, %{scope(ctx) | approval_id: missing})
  end

  test "two matching grants refuse instead of choosing one" do
    ctx = approved()
    [original] = Enum.filter(events(ctx.tenant), &(&1.event_type == "outreach.approval.granted"))

    assert {:ok, _} =
             Audit.append(
               %{
                 event_type: original.event_type,
                 subject_resource: original.subject_resource,
                 subject_id: original.subject_id,
                 category: original.category,
                 action: original.action,
                 payload: original.payload
               },
               actor: ctx.operator
             )

    assert {:error, :not_found} = project(ctx.approval.id, ctx.operator, scope(ctx))
  end

  test "inconsistent historical delegation is not replaced by the current actor" do
    ctx = approved()

    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments,delegation_id}', to_jsonb($1::text)) WHERE event_type = 'outreach.approval.granted' AND subject_id = $2",
      [Ecto.UUID.generate(), ctx.approval.id]
    )

    assert {:error, :not_found} = project(ctx.approval.id, ctx.operator, scope(ctx))
  end

  test "even a matching grant event in a foreign tenant is not projected" do
    ctx = approved()

    tamper!(
      "UPDATE audit_events SET tenant_id = $1 WHERE event_type = 'outreach.approval.granted' AND subject_id = $2",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), ctx.approval.id]
    )

    assert {:error, :not_found} = project(ctx.approval.id, ctx.operator, scope(ctx))
  end

  test "the projection grants no generic event or payload read" do
    ctx = approved()
    assert {:ok, _} = project(ctx.approval.id, ctx.operator, scope(ctx))
    assert {:ok, [_ | _]} = Audit.list_events(actor: ctx.admin)
    assert {:ok, [_ | _]} = Audit.list_payloads(actor: ctx.admin)
    # Ash read authorization filters unauthorized rows rather than raising
    # Forbidden for these list actions. Assert exact empty results against
    # populated positive controls, not a generic error-or-empty allowance.
    assert Audit.list_events(actor: ctx.operator) == {:ok, []}
    assert Audit.list_payloads(actor: ctx.operator) == {:ok, []}
  end

  test "a human approval is not represented as a delegated-machine approval" do
    ctx = prototype_drafted!()
    assert PrototypeFixtures.leave_runtime() == :ok

    assert {:ok, approval} =
             SdrAgent.Outreach.approve(
               ctx.draft,
               SdrAgent.OutreachFixtures.approval_input(ctx.revision),
               actor: ctx.admin
             )

    enter_window!(ctx.fixture)
    ctx = Map.put(ctx, :approval, approval)
    assert {:error, :not_found} = project(approval.id, ctx.operator, scope(ctx))
    assert Output.view(:approval, approval.id, ctx.operator) == {:error, :not_found}
  end

  test "Output is the only caller outside the audit boundary" do
    paths =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&String.starts_with?(&1, "lib/sdr_agent/audit/"))
      |> Enum.filter(&(File.read!(&1) =~ "read_prototype_approval_grant"))

    assert paths == ["lib/sdr_agent/audit.ex", "lib/sdr_agent/prototype/output.ex"]
  end
end
