defmodule SdrAgent.Prototype.OperatorGatesTest do
  @moduledoc """
  D-237 least privilege at S4's operator gates (interfaces r6 IF-3 operator
  atoms; amendment item 3 "Allowed actions" and "Refused for the operator";
  plan r7 section 6 row "Least privilege", S4's part):

  - `SDR.assign_lead/2` admits the resolved prototype operator
    (`OperatorAction(:assign)`) in its binding's tenant, and records the
    operator's own identity; it refuses a forged operator struct, a
    foreign-tenant operator and the auditor, writing nothing;
  - `SDR.retry_run/2` is refused in prototype runtime for every actor;
  - the `:review_read` read lines: the operator reads exactly the listed
    resources (Draft, DraftRevision, RevisionCitation, Approval,
    DeliveryOperation, DeliveryReceipt, AgentRun, Lead, Account, Contact,
    Decision, ResearchArtifact, EvidenceClaim) and nothing else here; a
    forged operator struct reads none of them in ordinary runtime;
  - the auditor cannot assign, approve or capture.

  Grant, provisioning, user-administration and settings refusals are S1's
  and S3's (provision_test, anchor_auth_test, seed_policy_test).
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Outreach
  alias SdrAgent.SDR

  @review_read [
    SdrAgent.Outreach.Draft,
    SdrAgent.Outreach.DraftRevision,
    SdrAgent.Outreach.RevisionCitation,
    SdrAgent.Outreach.Approval,
    SdrAgent.Outreach.DeliveryOperation,
    SdrAgent.Outreach.DeliveryReceipt,
    SdrAgent.Agents.AgentRun,
    SdrAgent.Sales.Lead,
    SdrAgent.Sales.Account,
    SdrAgent.Sales.Contact,
    SdrAgent.Agents.Decision,
    SdrAgent.Research.ResearchArtifact,
    SdrAgent.Research.EvidenceClaim
  ]

  @not_review_read [
    SdrAgent.Agents.ModelInvocation,
    SdrAgent.Agents.ModelResultRelease,
    SdrAgent.Outreach.Suppression,
    SdrAgent.Accounts.User
  ]

  defp forbidden?({:error, %Ash.Error.Forbidden{}}), do: true
  defp forbidden?(_), do: false

  defp lead!(ctx, key) do
    lead = SdrAgent.SDRCase.fixture_lead!(ctx, key)
    assert lead.status == :new
    lead
  end

  # A bound prototype with the demo data set and a saved offering profile,
  # in prototype runtime, before any assignment.
  defp bound_with_demo!(opts \\ []) do
    fixture = bound!(Keyword.merge([enter_runtime: false], opts))
    ctx = demo!(fixture)
    SdrAgent.SDRCase.ensure_offering!(ctx)
    enter!(fixture)
    Map.merge(ctx, %{fixture: fixture, operator: fixture.actor})
  end

  # ------------------------------------------------------------------ assign

  test "the resolved operator assigns a lead; the event records prototype_operator and the delegation" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "02")

    result = SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: ctx.operator)

    assert match?({:ok, %{run: _, job: _, operation: _}}, result),
           "assign refused: #{inspect(result)}"

    {:ok, %{run: run, job: job}} = result

    assert run.usage_origin == :assignment
    assert job.worker == "SdrAgent.SDR.AgentWorker"
    assert reload!(ctx, lead).status == :assigned

    [assigned] = events_of(ctx.tenant, "sales.lead.assigned")
    assert {assigned.actor_type, assigned.actor_id} == {:prototype_operator, ctx.operator.id}
  end

  test "a forged operator struct, a foreign-tenant operator and the auditor cannot assign; nothing is written" do
    ctx = bound_with_demo!(auditor: true)
    lead = lead!(ctx, "02")

    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}

    foreign = %Actor{
      type: :prototype_operator,
      id: ctx.operator.id,
      tenant_id: Ecto.UUID.generate()
    }

    for actor <- [forged, foreign, ctx.fixture.auditor] do
      assert forbidden?(SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: actor)),
             "assign was not refused for #{inspect(actor.__struct__)}"
    end

    assert reload!(ctx, lead).status == :new
    assert events_of(ctx.tenant, "sales.lead.assigned") == []
  end

  test "ordinary runtime: an operator-typed struct cannot assign (control)" do
    ctx = demo!(nil)
    lead = lead!(ctx, "02")
    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}
    assert forbidden?(SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: forged))
  end

  # ------------------------------------------------------------------ retry

  test "retry is refused in prototype runtime for every actor, before any retry check" do
    fixture = bound!(enter_runtime: false)
    ctx = demo!(fixture)
    %{run: run} = drafted!(ctx)

    ordinary = SDR.retry_run(run.id, actor: ctx.admin)
    refute forbidden?(ordinary), "control: the ordinary admin retry reaches the retry checks"

    enter!(fixture)

    for actor <- [ctx.admin, fixture.actor] do
      assert forbidden?(SDR.retry_run(run.id, actor: actor)),
             "retry was not refused in prototype runtime"
    end
  end

  # ------------------------------------------------------------------ review_read

  test "the operator reads exactly the :review_read resources of its tenant" do
    ctx = prototype_drafted!()
    assert {:ok, _approval} = operator_approve(ctx, ctx.draft)
    deliver!()

    for resource <- @review_read do
      result = Ash.read(resource, actor: ctx.operator)

      assert match?({:ok, [_ | _]}, result),
             "the operator cannot read #{inspect(resource)}: #{inspect(result, limit: 3)}"
    end

    for resource <- @not_review_read do
      refute match?({:ok, [_ | _]}, Ash.read(resource, actor: ctx.operator)),
             "the operator reads #{inspect(resource)}"
    end
  end

  test "ordinary runtime: a forged operator struct reads none of the :review_read resources" do
    ctx = prototype_drafted!()
    forged = ctx.operator
    PrototypeFixtures.leave_runtime()

    # AgentRun's existing read policy admits any present actor (unchanged).
    for resource <- @review_read -- [SdrAgent.Agents.AgentRun] do
      refute match?({:ok, [_ | _]}, Ash.read(resource, actor: forged)),
             "a forged operator reads #{inspect(resource)} in ordinary runtime"
    end
  end

  test "a forged operator struct reads nothing in prototype runtime either" do
    ctx = prototype_drafted!()
    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}

    for resource <- @review_read -- [SdrAgent.Agents.AgentRun] do
      refute match?({:ok, [_ | _]}, Ash.read(resource, actor: forged)),
             "a forged operator reads #{inspect(resource)}"
    end
  end

  # ------------------------------------------------------------------ the auditor

  test "the bound auditor cannot approve or record a capture" do
    ctx = prototype_drafted!(auditor: true)
    auditor = ctx.fixture.auditor
    {draft, input} = reviewed(ctx, ctx.draft)
    assert forbidden?(Outreach.approve(draft, input, actor: auditor))

    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    receipt = %{
      delivery_operation_id: delivery.id,
      idempotency_key: delivery.idempotency_key,
      kind: :captured,
      provider: :capture,
      provider_message_id: "capture-forged",
      rendered_sha256: :crypto.hash(:sha256, "x")
    }

    assert forbidden?(Outreach.record_receipt(receipt, actor: auditor))
    assert receipts!(ctx, delivery) == []
  end

  test "the bound auditor cannot assign" do
    ctx = bound_with_demo!(auditor: true)
    lead = lead!(ctx, "03")

    assert forbidden?(
             SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: ctx.fixture.auditor)
           )

    assert reload!(ctx, lead).status == :new
  end
end
