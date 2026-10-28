defmodule SdrAgent.Prototype.OperatorGatesTest do
  @moduledoc """
  D-237 least privilege at S4's operator gates (interfaces r6 IF-3 operator
  atoms; amendment item 3 "Allowed actions" and "Refused for the operator";
  plan r7 section 6 row "Least privilege", S4's part):

  - `SDR.assign_lead/2` admits the resolved prototype operator
    (`OperatorAction(:assign)`) in its binding's tenant, and records the
    operator's own identity; it refuses a forged operator struct, a
    foreign-tenant operator and the auditor, writing nothing;
  - Lead `:assign` only (Codex S4 RED ruling 1): the live operator may
    assign, with the transition, stamp, owner and event as before; an
    operator-supplied owner is refused; no other Lead mutation;
  - `SDR.retry_run/2` is refused in prototype runtime for every actor;
  - the `:review_read` read lines: the operator reads exactly the listed
    resources (Draft, DraftRevision, RevisionCitation, Approval,
    DeliveryOperation, DeliveryReceipt, AgentRun, Lead, Account, Contact,
    Decision, ResearchArtifact, EvidenceClaim), plus Campaign (Codex S4
    RED ruling 2), and only rows of the binding tenant, through the policy
    itself and nothing else here; a
    forged operator struct reads none of them in ordinary runtime, except
    AgentRun and Decision, whose existing read policy admits any present
    actor (unchanged);
  - the auditor cannot assign, approve or capture.

  Grant, provisioning, user-administration and settings refusals are S1's
  and S3's (provision_test, anchor_auth_test, seed_policy_test).
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
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
    SdrAgent.Research.EvidenceClaim,
    SdrAgent.Sales.Campaign
  ]

  # Review resources whose existing read policy is `authorize_if actor_present()`
  # (unchanged by D-237): any present actor reads them, a forged struct included.
  @any_present_actor_reads [SdrAgent.Agents.AgentRun, SdrAgent.Agents.Decision]

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
    enter_window!(fixture)
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

    enter_window!(fixture)

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

      # The direct read of one of those rows, by id.
      {:ok, [row | _]} = result

      assert match?({:ok, %{id: _}}, Ash.get(resource, row.id, actor: ctx.operator)),
             "the operator cannot read a #{inspect(resource)} directly"
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

    # AgentRun's and Decision's existing read policy admits any present
    # actor (unchanged), so they are exempt here.
    for resource <- @review_read -- @any_present_actor_reads do
      refute match?({:ok, [_ | _]}, Ash.read(resource, actor: forged)),
             "a forged operator reads #{inspect(resource)} in ordinary runtime"
    end
  end

  test "a forged operator struct reads nothing in prototype runtime either" do
    ctx = prototype_drafted!()
    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}

    for resource <- @review_read -- @any_present_actor_reads do
      refute match?({:ok, [_ | _]}, Ash.read(resource, actor: forged)),
             "a forged operator reads #{inspect(resource)}"
    end
  end

  # Codex S4 RED-2 Q1: the exemption above documents existing semantics, not
  # least privilege. AgentRun's and Decision's :read keeps its existing first
  # line `authorize_if actor_present()` (no D-237 line ahead of it), so any
  # present actor, a forged operator struct included, reads their rows.
  test "existing semantics, not least privilege: AgentRun and Decision :read still admit any present actor" do
    ctx = prototype_drafted!()
    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}

    for resource <- @any_present_actor_reads do
      read_lines =
        for policy <- Ash.Policy.Info.policies(resource),
            match?([{Ash.Policy.Check.ActionType, opts}] when is_list(opts), policy.condition),
            [{Ash.Policy.Check.ActionType, opts}] = policy.condition,
            Keyword.get(opts, :type) == [:read],
            do: Enum.map(policy.policies, &{&1.type, &1.check_module})

      assert match?([[{:authorize_if, Ash.Policy.Check.ActorPresent} | _]], read_lines),
             "#{inspect(resource)} :read no longer starts with authorize_if actor_present(): " <>
               inspect(read_lines)

      assert match?({:ok, [_ | _]}, Ash.read(resource, actor: forged)),
             "#{inspect(resource)} rows are not readable by any present actor (prototype runtime)"
    end

    PrototypeFixtures.leave_runtime()

    for resource <- @any_present_actor_reads do
      assert match?({:ok, [_ | _]}, Ash.read(resource, actor: forged)),
             "#{inspect(resource)} rows are not readable by any present actor (ordinary runtime)"
    end
  end

  # The twelve review_read lines of Codex 92a99417 step 4 (Lead and Campaign
  # came with B2 because the assignment path reads them).
  @step4_reads @review_read -- [SdrAgent.Sales.Lead, SdrAgent.Sales.Campaign]

  defp reviewed! do
    ctx = prototype_drafted!()
    assert {:ok, _approval} = operator_approve(ctx, ctx.draft)
    deliver!()
    ctx
  end

  defp kernel_row!(ctx, resource) do
    result = Ash.read(resource, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))
    assert match?({:ok, [_ | _]}, result), "no #{inspect(resource)} row in the fixture"
    {:ok, [row | _]} = result
    row
  end

  # Negative synthetic tampering, not a domain-write success path: the row is
  # moved to a random, foreign tenant by SQL with triggers disabled.
  defp move_to_foreign_tenant!(resource, id) do
    table = AshPostgres.DataLayer.Info.table(resource)

    tamper!("UPDATE #{table} SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(id)
    ])
  end

  test "review_read: a row moved to a foreign tenant leaves the operator's list and direct read (the twelve)" do
    ctx = reviewed!()

    # AgentRun and Decision keep their existing actor_present() read (see the
    # existing-semantics regression): they are not tenant-filtered for any
    # present actor, so they are exempt here as in the forged-read loops.
    for resource <- @step4_reads -- @any_present_actor_reads do
      row = kernel_row!(ctx, resource)

      assert match?({:ok, %{id: _}}, Ash.get(resource, row.id, actor: ctx.operator)),
             "the operator cannot read its own #{inspect(resource)} row"

      move_to_foreign_tenant!(resource, row.id)
      listed = Ash.read(resource, actor: ctx.operator)
      assert match?({:ok, _}, listed), "#{inspect(resource)} list: #{inspect(listed, limit: 3)}"
      {:ok, rows} = listed
      refute row.id in Enum.map(rows, & &1.id), "a foreign #{inspect(resource)} row is listed"

      refute match?({:ok, _}, Ash.get(resource, row.id, actor: ctx.operator)),
             "a foreign #{inspect(resource)} row is read directly"
    end
  end

  test "review_read: with a stale binding the live operator reads none of them" do
    ctx = reviewed!()
    assert PrototypeFixtures.put_live_identity(%{system_identifier: 1}) == :ok

    for resource <- @review_read -- @any_present_actor_reads do
      refute match?({:ok, [_ | _]}, Ash.read(resource, actor: ctx.operator)),
             "a stale-binding operator reads #{inspect(resource)}"
    end
  end

  test "review_read grants no mutation: no write action of the twelve for the operator (Approval :approve aside)" do
    ctx = reviewed!()

    for resource <- @step4_reads,
        action <- Ash.Resource.Info.actions(resource),
        action.type != :read,
        {resource, action.name} != {SdrAgent.Outreach.Approval, :approve} do
      subject =
        if action.type in [:create, :action], do: resource, else: kernel_row!(ctx, resource)

      refute Ash.can?({subject, action.name}, ctx.operator) == true,
             "the operator may #{action.name} #{inspect(resource)}"
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

  # ------------------------------------------------------------------ ruling 1: Lead :assign only

  defp can?(record, action, actor), do: Ash.can?({record, action}, actor) == true

  @lead_mutations [
    :start_research,
    :start_qualifying,
    :qualify,
    :disqualify,
    :start_outreach,
    :disqualify_by_override,
    :requalify_by_override,
    :mark_replied,
    :convert,
    :nurture,
    :stop,
    :block,
    :retry,
    :reopen
  ]

  test "Lead :assign: the live operator assigns; transition, stamp, owner and event as before" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "07")
    assert can?(lead, :assign, ctx.operator)

    assert {:ok, assigned} = Sales.update(lead, :assign, %{}, actor: ctx.operator)
    assert assigned.status == :assigned
    assert assigned.assigned_at
    assert assigned.owner_user_id == lead.owner_user_id

    [event] = events_of(ctx.tenant, "sales.lead.assigned")
    assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.operator.id}
  end

  # Every assignment effect a refused call must not have (supplement 2 r2
  # Q1): runs, jobs, operations and audit events other than a denial record.
  defp assignment_effects(ctx) do
    opts = SdrAgent.Audit.Kernel.opts(ctx.tenant.id)
    {:ok, runs} = Ash.read(SdrAgent.Agents.AgentRun, opts)
    {:ok, operations} = Ash.read(SdrAgent.Operations.Operation, opts)

    %{
      runs: length(runs),
      operations: length(operations),
      jobs: Repo.aggregate(Oban.Job, :count),
      events:
        ctx.tenant |> events() |> Enum.reject(&(&1.event_type == "authz.denied")) |> length()
    }
  end

  defp refused_without_effects!(ctx, lead, fun) do
    before = assignment_effects(ctx)
    result = fun.()
    assert match?({:error, %Ash.Error.Forbidden{}}, result), "not Forbidden: #{inspect(result)}"
    reloaded = reload!(ctx, lead)
    assert {reloaded.status, reloaded.owner_user_id} == {lead.status, lead.owner_user_id}
    assert assignment_effects(ctx) == before, "a refused assignment left an effect"
  end

  # A human user who is NOT the lead's current owner, so the input is a change.
  defp other_owner!(ctx, lead) do
    owner =
      Enum.find([ctx.admin, operator!(ctx, :reviewer)], &(&1.id != lead.owner_user_id))

    assert owner && owner.id != lead.owner_user_id
    owner
  end

  test "Lead :assign (direct): an operator-supplied CHANGED owner is Forbidden by the policy alone, with no effect" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "07")
    owner = other_owner!(ctx, lead)

    refused_without_effects!(ctx, lead, fn ->
      Sales.update(lead, :assign, %{owner_user_id: owner.id}, actor: ctx.operator)
    end)
  end

  test "SDR.assign_lead: any caller-supplied owner is Forbidden before assignment, never stripped" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "07")

    # A changed owner, and the current owner value itself (nil when there is
    # none): owner input present at all is refused on the operator path.
    for owner_id <- [other_owner!(ctx, lead).id, lead.owner_user_id] do
      refused_without_effects!(ctx, lead, fn ->
        SDR.assign_lead(lead,
          campaign_id: ctx.campaign_id,
          owner_user_id: owner_id,
          actor: ctx.operator
        )
      end)
    end
  end

  test "SDR.assign_lead: an accepted operator call keeps the existing owner" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "07")

    assert {:ok, %{lead: assigned}} =
             SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: ctx.operator)

    assert {assigned.status, assigned.owner_user_id} == {:assigned, lead.owner_user_id}
  end

  test "SDR.assign_lead control: a human still assigns with an owner in ordinary runtime (unchanged)" do
    ctx = demo!(nil)
    SdrAgent.SDRCase.ensure_offering!(ctx)
    lead = lead!(ctx, "07")
    reviewer = operator!(ctx, :reviewer)

    assert {:ok, %{lead: assigned}} =
             SDR.assign_lead(lead,
               campaign_id: ctx.campaign_id,
               owner_user_id: reviewer.id,
               actor: ctx.admin
             )

    assert {assigned.status, assigned.owner_user_id} == {:assigned, reviewer.id}
  end

  test "Lead :assign: forged, foreign-tenant and stale-binding operators are refused" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "07")
    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}

    foreign = %Actor{
      type: :prototype_operator,
      id: ctx.operator.id,
      tenant_id: Ecto.UUID.generate()
    }

    for actor <- [forged, foreign] do
      refute can?(lead, :assign, actor)
      assert forbidden?(Sales.update(lead, :assign, %{}, actor: actor))
    end

    assert PrototypeFixtures.put_live_identity(%{system_identifier: 1}) == :ok
    refute can?(lead, :assign, ctx.operator)
    assert forbidden?(Sales.update(lead, :assign, %{}, actor: ctx.operator))
    assert reload!(ctx, lead).status == :new
  end

  test "the operator gets no other Lead mutation" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "07")

    for action <- @lead_mutations do
      refute can?(lead, action, ctx.operator), "the operator may #{action} a lead"
    end

    refute Ash.can?({Sales.Lead, :create}, ctx.operator) == true
  end

  test "Lead :assign control: an admin still assigns with an owner in ordinary runtime (unchanged)" do
    ctx = demo!(nil)
    lead = lead!(ctx, "07")

    assert {:ok, assigned} =
             Sales.update(lead, :assign, %{owner_user_id: ctx.admin.id}, actor: ctx.admin)

    assert {assigned.status, assigned.owner_user_id} == {:assigned, ctx.admin.id}
  end

  # ------------------------------------------------------------------ ruling 2: Campaign review_read

  # Negative synthetic tampering, not a domain-write success path: a raw copy
  # of an existing row under a random, foreign tenant (SQL with triggers
  # disabled). The operator's policy-level read must exclude it.
  defp foreign_copy!(table, id) do
    foreign_id = Ecto.UUID.generate()

    tamper!(
      "INSERT INTO #{table} SELECT (jsonb_populate_record(NULL::#{table}, to_jsonb(t) || " <>
        "jsonb_build_object('id', $1::text, 'tenant_id', $2::text))).* FROM #{table} t WHERE id = $3",
      [foreign_id, Ecto.UUID.generate(), Ecto.UUID.dump!(id)]
    )

    foreign_id
  end

  test "Campaign review_read: the binding tenant's campaigns are read; a foreign-tenant row is excluded" do
    ctx = bound_with_demo!()
    foreign_id = foreign_copy!("campaigns", ctx.campaign_id)

    assert {:ok, rows} = Ash.read(Sales.Campaign, actor: ctx.operator)
    ids = Enum.map(rows, & &1.id)
    assert ctx.campaign_id in ids
    refute foreign_id in ids

    assert {:ok, %{id: _}} = Sales.fetch(Sales.Campaign, ctx.campaign_id, actor: ctx.operator)
    refute match?({:ok, _}, Sales.fetch(Sales.Campaign, foreign_id, actor: ctx.operator))
    refute match?({:ok, _}, Ash.get(Sales.Campaign, foreign_id, actor: ctx.operator))
  end

  test "review_read rows are the binding tenant's only (Lead, through the policy itself)" do
    ctx = bound_with_demo!()
    lead = lead!(ctx, "05")
    foreign_id = foreign_copy!("leads", lead.id)

    assert {:ok, rows} = Ash.read(Sales.Lead, actor: ctx.operator)
    ids = Enum.map(rows, & &1.id)
    assert lead.id in ids
    refute foreign_id in ids
  end

  test "Campaign review_read: a forged or stale operator reads nothing; ordinary runtime denies" do
    ctx = bound_with_demo!()
    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}
    refute match?({:ok, [_ | _]}, Ash.read(Sales.Campaign, actor: forged))

    assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok
    refute match?({:ok, [_ | _]}, Ash.read(Sales.Campaign, actor: ctx.operator))

    PrototypeFixtures.leave_runtime()
    refute match?({:ok, [_ | _]}, Ash.read(Sales.Campaign, actor: ctx.operator))
  end

  test "Campaign: the operator gets no Campaign write" do
    ctx = bound_with_demo!()
    {:ok, campaign} = Sales.fetch(Sales.Campaign, ctx.campaign_id, actor: ctx.admin)

    for action <- [:update, :activate, :pause, :resume, :complete, :archive] do
      refute can?(campaign, action, ctx.operator), "the operator may #{action} a campaign"
    end

    refute Ash.can?({Sales.Campaign, :create}, ctx.operator) == true
  end

  test "control: the human auditor still reads the review resources in ordinary runtime (unchanged)" do
    ctx = demo!(nil)
    %{draft: draft} = drafted!(ctx)
    auditor = operator!(ctx, :auditor)

    for resource <- [Sales.Lead, Sales.Campaign, SdrAgent.Outreach.Draft] do
      assert match?({:ok, [_ | _]}, Ash.read(resource, actor: auditor)),
             "the auditor cannot read #{inspect(resource)}"
    end

    assert match?({:ok, %{id: _}}, Ash.get(SdrAgent.Outreach.Draft, draft.id, actor: auditor))
  end
end
