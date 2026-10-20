defmodule SdrAgent.Research.QualificationRecordLockTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 L (T-L8 only; T-L7, T-L9 and T-L10 are
  RED-3 [P]): Qualification `:record` takes the lead `FOR UPDATE` first
  (`SdrAgent.Research.Changes.RecordLeadLock`, section 4.6.4 step 1), and a
  `lead_id` absent from the actor's tenant gives a fixed typed refusal,
  `InvalidAttribute` on `:lead_id` with no value. Nothing else is read or
  written: no Supersedes or QualificationRules read of `qualifications`,
  no INSERT, no evidence row and no event.

  Two cases: a random uuid under the tenant's agent, and a real lead under
  an agent actor with a random `tenant_id` (Audit.bootstrap returns the
  singleton tenant, so the foreign tenant has no row).

  RED form: behavioural. `Research.record_qualification/2` exists on main;
  there the random uuid is refused by `QualificationRules` on
  `:evidence_claim_ids` after the unlocked reads, and the foreign tenant
  reaches its INSERT, so the typed `:lead_id` assertion and the "no
  qualifications statement" assertion fail. Observation: a telemetry trace
  of this process's statements (as RED-1 T-A15).

  Interface names chosen here for review: the refusal is
  `{:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field: :lead_id,
  value: nil}]}}`, its message identical in both cases.
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Research
  alias SdrAgent.SalesFixtures, as: F

  @qualification_tables ~r/"qualifications"|"qualification_evidences"/

  setup do
    tenant = bootstrap!()
    lead = F.lead_in!(tenant, :qualifying)
    %{artifact: artifact, run: run} = F.artifact!(tenant, lead)
    claim = F.claim!(tenant, artifact, run)
    decision = F.qualification_decision!(tenant, run, lead)
    icp = F.active_icp!(tenant)

    %{
      tenant: tenant,
      lead: lead,
      agent: system_actor(:agent_runtime, tenant),
      attrs: F.qualification_attrs(lead, icp, run, decision, [claim])
    }
  end

  describe "T-L8 a lead absent from the actor's tenant" do
    test "T-L8 a random lead_id is the fixed InvalidAttribute on :lead_id; nothing written",
         ctx do
      missing = Ecto.UUID.generate()
      refused!(ctx, Map.put(ctx.attrs, :lead_id, missing), ctx.agent, [missing])
    end

    test "T-L8 a real lead under an agent of another tenant is the same refusal; nothing written",
         ctx do
      foreign = Ecto.UUID.generate()
      actor = system_actor(:agent_runtime, %{id: foreign})
      refused!(ctx, ctx.attrs, actor, [ctx.lead.id, foreign])
    end

    test "T-L8 both cases carry the same fixed message", ctx do
      missing = Ecto.UUID.generate()
      foreign = system_actor(:agent_runtime, %{id: Ecto.UUID.generate()})
      first = refused!(ctx, Map.put(ctx.attrs, :lead_id, missing), ctx.agent, [missing])
      second = refused!(ctx, ctx.attrs, foreign, [ctx.lead.id, foreign.tenant_id])
      assert first.message == second.message, "C3-02: the refusal message is fixed"
    end
  end

  ## Assertions

  defp refused!(ctx, attrs, actor, values) do
    before = state(ctx.lead)

    {result, queries} =
      trace(fn -> Research.record_qualification(attrs, actor: actor) end)

    assert match?(
             {:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field: :lead_id}]}},
             result
           ),
           "C3-02: expected the fixed InvalidAttribute on :lead_id, got: #{short(result)}"

    {:error, %Ash.Error.Invalid{errors: [refusal]} = error} = result
    assert refusal.value == nil, "C3-02: the refusal carries no value"
    assert is_binary(refusal.message)
    text = Exception.message(error) <> " " <> rendered(refusal)

    for value <- values do
      refute text =~ value, "C3-02: the refusal must not echo an id"
    end

    touched = for {sql, _params} <- queries, sql =~ @qualification_tables, do: sql

    assert touched == [],
           "C3-02: refused before the Supersedes read and the INSERT: #{short(touched)}"

    assert state(ctx.lead) == before, "C3-02: nothing is written and no event is appended"
    refusal
  end

  defp state(lead) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT (SELECT count(*) FROM qualifications),
               (SELECT count(*) FROM qualification_evidences),
               (SELECT count(*) FROM audit_events),
               (SELECT status FROM leads WHERE id = $1)
        """,
        [Ecto.UUID.dump!(lead.id)]
      )

    row
  end

  ## Query tracing

  defp trace(fun) do
    parent = self()
    handler = "c3-02-record-lock-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent do
            send(parent, {:c302_query, IO.iodata_to_binary(metadata.query), metadata[:params]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(acc) do
    receive do
      {:c302_query, sql, params} -> drain([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp short(term), do: inspect(term, limit: 12, printable_limit: 300)

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)
end
