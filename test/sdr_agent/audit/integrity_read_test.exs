defmodule SdrAgent.Audit.IntegrityReadTest do
  @moduledoc """
  R0-07 slice A round 5, contract (b): the audit kernel's integrity read
  (`Kernel.integrity_opts/1`, `Audit.Checks.IntegrityRead`) matches only a
  `:kernel` actor carrying both the kernel and the integrity markers. Its
  callers are exactly `AppendEvent` and `Audit.Verifier`. It emits no
  plaintext: a verifier report names issue types and ids, never a value.
  A plain kernel read stays masked.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Checks.IntegrityRead
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Audit.Kernel

  @callers ["lib/sdr_agent/audit/changes/append_event.ex", "lib/sdr_agent/audit/verifier.ex"]

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, invocation: AgentsFixtures.claude_completed!(run, agent, "ir-1")}
  end

  test "only AppendEvent and the Verifier call integrity_opts/1" do
    callers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "integrity_opts("))
      |> Enum.reject(&(&1 == "lib/sdr_agent/audit/kernel.ex"))
      |> Enum.sort()

    assert callers == @callers
  end

  test "only the double-marked kernel read sees a gated output", ctx do
    read = fn opts ->
      {:ok, row} = Ash.get(ModelInvocation, ctx.invocation.id, opts)
      row.parsed_output
    end

    kernel = system_actor(:kernel, ctx.tenant)
    agent = system_actor(:agent_runtime, ctx.tenant)

    assert is_map(read.(Kernel.integrity_opts(ctx.tenant.id)))
    assert %Ash.ForbiddenField{} = read.(Kernel.opts(ctx.tenant.id))
    assert %Ash.ForbiddenField{} = read.(actor: kernel, context: %{sdr_audit_integrity: true})
    assert %Ash.ForbiddenField{} = read.(actor: agent, context: IntegrityRead.context())
    assert %Ash.ForbiddenField{} = read.(actor: kernel, context: KernelContext.context())
  end

  test "a verifier report names the tampered row, never its values", ctx do
    canary = "canary-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    tamper!(
      "UPDATE model_invocations SET parsed_output = $1 WHERE id = $2",
      [%{"note" => canary}, Ecto.UUID.dump!(ctx.invocation.id)]
    )

    assert {:ok, report} = Audit.verify_chain(actor: human(:admin, ctx.tenant))
    refute report.valid?
    assert Enum.any?(report.issues, &(&1.type == :record_hash_mismatch))
    refute inspect(report, limit: :infinity) =~ canary
  end
end
