defmodule SdrAgent.ConsoleReadsTest do
  @moduledoc """
  S10b read paths added for the operator console (Runs/Operations and
  auditor export views): `Agents.list_runs/1`,
  `Agents.list_tool_invocations/2`, `Operations.list_operations/1` and
  `Audit.list_exports/1` — tenant-scoped, newest first, behind each
  resource's existing read policy (allow and deny cases).
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [operator!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Operations

  setup ctx do
    %{run: run, operation: operation} = assign!(ctx, "01")
    %{success: 1} = drain!()
    Map.merge(ctx, %{run: run, operation: operation})
  end

  test "operators list the tenant's agent runs, newest first, optionally by lead", ctx do
    %{run: second} = assign!(ctx, "02")

    for role <- [:admin, :reviewer, :auditor] do
      assert {:ok, [newest, oldest]} = Agents.list_runs(actor: operator!(ctx, role))
      assert {newest.id, oldest.id} == {second.id, ctx.run.id}
    end

    assert {:ok, [only]} = Agents.list_runs(lead_id: ctx.run.lead_id, actor: ctx.admin)
    assert only.id == ctx.run.id
  end

  test "tool invocations of a run are listed in call order", ctx do
    assert {:ok, [first | _] = calls} = Agents.list_tool_invocations(ctx.run.id, actor: ctx.admin)
    assert first.agent_run_id == ctx.run.id

    assert Enum.map(calls, & &1.sequence_in_run) ==
             Enum.sort(Enum.map(calls, & &1.sequence_in_run))
  end

  test "operations are listed newest first for operators", ctx do
    for role <- [:admin, :reviewer, :auditor] do
      assert {:ok, [operation | _]} = Operations.list_operations(actor: operator!(ctx, role))
      assert operation.id == ctx.operation.id
    end
  end

  test "an anonymous caller lists nothing", ctx do
    refute match?({:ok, [_ | _]}, Agents.list_runs(actor: nil))
    refute match?({:ok, [_ | _]}, Operations.list_operations(actor: nil))

    refute match?({:ok, [_ | _]}, Agents.list_tool_invocations(ctx.run.id, actor: nil))
  end

  test "exports are readable by admins and auditors only", ctx do
    {:ok, export} =
      SdrAgent.Audit.AuditExport
      |> Ash.Changeset.for_create(
        :request,
        %{
          requested_by_type: :auditor_cli,
          requested_by_id: "console-reads-test",
          scope: :lead,
          scope_ref: ctx.run.lead_id
        },
        actor: ctx.aud
      )
      |> Ash.create()

    assert {:ok, [%{id: id}]} = Audit.list_exports(actor: ctx.admin)
    assert id == export.id
    assert {:ok, [%{id: ^id}]} = Audit.list_exports(actor: operator!(ctx, :auditor))

    refute match?({:ok, [_ | _]}, Audit.list_exports(actor: operator!(ctx, :reviewer)))
  end
end
