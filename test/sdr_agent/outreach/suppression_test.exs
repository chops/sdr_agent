defmodule SdrAgent.Outreach.SuppressionTest do
  @moduledoc """
  S8a Suppression: deterministic, append-only, monotonic do-not-contact
  entries. Creating one stops, in the same transaction, every open lead and
  enrollment of the matching contacts, invalidates their granted approvals
  and cancels their drafts; the agent's suppression gate reads the store.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Checks.SuppressionContext
  alias SdrAgent.SDR.SuppressionCheck

  defp denials(ctx), do: length(events_of_type(ctx.tenant, "authz.denied"))

  test "ADM creates a normalised manual suppression, idempotently", ctx do
    lead = fixture_lead!(ctx, "02")
    email = to_string(contact!(ctx, lead).email)
    before = length(events_of_type(ctx.tenant, "outreach.suppression.created"))

    assert {:ok, suppression} =
             Outreach.suppress(%{scope: :email, value: "  #{String.upcase(email)} "},
               actor: ctx.admin
             )

    assert {suppression.scope, to_string(suppression.value)} == {:email, email}
    assert {suppression.reason, suppression.created_by_user_id} == {:manual, ctx.admin.id}
    assert suppression.effective_at

    assert {:ok, again} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)
    assert again.id == suppression.id
    assert length(events_of_type(ctx.tenant, "outreach.suppression.created")) == before + 1

    assert {:error, %Ash.Error.Invalid{}} =
             Outreach.suppress(%{scope: :email, value: "not-an-email"}, actor: ctx.admin)

    refute Enum.any?(Ash.Resource.Info.actions(Suppression), &(&1.type in [:update, :destroy]))
  end

  test "only ADM creates manual suppressions; refusals are audited", ctx do
    before = denials(ctx)

    for actor <- [
          operator!(ctx, :reviewer),
          operator!(ctx, :auditor),
          ctx.agent,
          SdrAgent.Actor.system(:delivery_worker, ctx.tenant.id)
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Outreach.suppress(%{scope: :domain, value: "cobalt-dock.test"}, actor: actor)
    end

    assert denials(ctx) == before + 4
  end

  test "an email suppression stops the lead and enrollment, invalidates the approval, cancels the draft",
       ctx do
    %{draft: draft, lead: lead} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    untouched = fixture_lead!(ctx, "02")
    email = to_string(contact!(ctx, lead).email)

    assert {:ok, _suppression} =
             Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)

    assert %{status: :stopped, status_reason: "suppressed: manual"} = reload!(ctx, lead)
    assert %{status: :stopped, stop_reason: :suppressed} = enrollment!(ctx, lead)
    assert %{status: :cancelled} = draft!(ctx, draft)

    {:ok, invalidated} = Outreach.fetch(Outreach.Approval, approval.id, actor: ctx.admin)
    assert {invalidated.status, invalidated.invalidated_reason} == {:invalidated, :suppressed}
    assert reload!(ctx, untouched).status == :new

    for type <- ~w(sales.lead.stopped sales.enrollment.stopped outreach.approval.invalidated
                   outreach.draft.cancelled outreach.suppression.created) do
      assert [_ | _] = events_of_type(ctx.tenant, type), type
    end

    assert {:ok, %{valid?: true}} = SdrAgent.Audit.verify_chain(actor: ctx.aud)
  end

  # Review #13 MF1: the dependent work of a lead that is already terminal is
  # still stopped, invalidated and cancelled.
  for {scope, key} <- [email: "01", domain: "02"] do
    test "a #{scope} suppression cascades even when the lead was already stopped", ctx do
      %{draft: draft, lead: lead} = drafted!(ctx, unquote(key))
      approval = approve!(ctx, draft, operator!(ctx, :reviewer))

      {:ok, stopped} =
        Sales.update(lead, :stop, %{status_reason: "operator stop"}, actor: ctx.admin)

      email = to_string(contact!(ctx, lead).email)

      value =
        if unquote(scope) == :email, do: email, else: email |> String.split("@") |> List.last()

      assert {:ok, _} =
               Outreach.suppress(%{scope: unquote(scope), value: value}, actor: ctx.admin)

      assert %{status: :stopped, status_reason: "operator stop"} = reload!(ctx, stopped)
      assert %{status: :stopped, stop_reason: :suppressed} = enrollment!(ctx, lead)
      assert %{status: :cancelled} = draft!(ctx, draft)
      assert %{status: :invalidated} = outreach!(ctx, approval)
    end
  end

  test "a failing side effect rolls the whole suppression back", ctx do
    %{draft: draft, lead: lead} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    email = to_string(contact!(ctx, lead).email)

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE FUNCTION test_refuse_cancel() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'refused by test'; END; $$
    """)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER test_refuse_cancel BEFORE UPDATE ON drafts FOR EACH ROW " <>
        "WHEN (NEW.status = 'cancelled') EXECUTE FUNCTION test_refuse_cancel()"
    )

    before = length(events(ctx.tenant))
    assert {:error, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)

    assert {:ok, []} = Outreach.matching_suppressions(email, actor: ctx.admin)
    assert reload!(ctx, lead).status == :in_outreach
    assert enrollment!(ctx, lead).status == :active
    assert draft!(ctx, draft).status == :queued
    assert outreach!(ctx, approval).status == :granted
    assert length(events(ctx.tenant)) == before
  end

  test "a domain suppression covers every contact of the domain", ctx do
    %{draft: draft, lead: lead} = drafted!(ctx)

    [_, domain] =
      lead |> then(&contact!(ctx, &1)) |> Map.get(:email) |> to_string() |> String.split("@")

    assert {:ok, %{scope: :domain}} =
             Outreach.suppress(%{scope: :domain, value: domain}, actor: ctx.admin)

    assert reload!(ctx, lead).status == :stopped
    assert draft!(ctx, draft).status == :cancelled
  end

  test "a suppression stops the agent before it works the lead", ctx do
    lead = fixture_lead!(ctx, "02")
    email = to_string(contact!(ctx, lead).email)
    {:ok, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)

    assert {:error, {:lead_not_assignable, :stopped}} =
             SdrAgent.SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: ctx.admin)
  end

  test "the configured suppression check reads the store (email and domain)", ctx do
    assert SuppressionCheck.impl() == SuppressionCheck.Store
    context = %{tenant_id: ctx.tenant.id, contact_id: nil}

    assert {:ok, :not_suppressed, %{"store" => "outreach", "suppression_ids" => []}} =
             SuppressionCheck.Store.check("someone@cobalt-dock.test", context)

    {:ok, by_domain} =
      Outreach.suppress(%{scope: :domain, value: "cobalt-dock.test"}, actor: ctx.admin)

    assert {:ok, :suppressed, %{"suppression_ids" => [id]}} =
             SuppressionCheck.Store.check("Someone@Cobalt-Dock.TEST", context)

    assert id == by_domain.id

    [suppressed_email] = SdrAgent.Demo.Fixtures.suppressed_contact_emails()
    assert {:ok, :suppressed, _} = SuppressionCheck.Store.check(suppressed_email, context)
  end

  test "agent and delivery actors may stop leads and enrollments only inside a suppression",
       ctx do
    %{lead: lead} = drafted!(ctx)
    enrollment = enrollment!(ctx, lead)
    dlv = SdrAgent.Actor.system(:delivery_worker, ctx.tenant.id)

    for actor <- [ctx.agent, dlv] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(lead, :stop, %{status_reason: "x"}, actor: actor)
    end

    assert {:ok, %{status: :stopped}} =
             enrollment
             |> Ash.Changeset.for_update(:stop, %{stop_reason: :suppressed},
               actor: dlv,
               context: SuppressionContext.context()
             )
             |> Ash.update()

    assert {:ok, %{status: :stopped}} =
             lead
             |> Ash.Changeset.for_update(:stop, %{status_reason: "suppressed: test"},
               actor: ctx.agent,
               context: SuppressionContext.context()
             )
             |> Ash.update()
  end
end
