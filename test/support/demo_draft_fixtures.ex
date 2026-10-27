defmodule SdrAgent.DemoDraftFixtures do
  @moduledoc """
  C2* slice S4 fixtures (plan r2 §5.1 "Test support", handback r3 §1.3):
  drafts whose lineage, origin run and cited claims carry chosen release
  dispositions, built through the domain APIs, plus the few sandbox-only
  corruptions the lineage-error tests need (ADR-0005 C2* addendum 2,
  decisions 1, 2 and 6).

  `base!/2` gives one seeded `:qualify` lead (fixture "01", a C2* lead) in
  outreach on a fresh campaign whose sequence has free steps, the
  hand-off draft of its Fake run on step 1, and one research artifact with
  an extraction Decision for the claims the drafts cite. `env!/2` then
  makes generation-2 ClaudeCLI calls admissible:

    * `:ordinary`: a test grant (`AgentsFixtures.grant!/3`) and the v1
      release allowlist entry, so `:released`, `:withheld`, `:none` and
      `:failed` invocations can be made;
    * `:demo`: S3's H2 environment (below) instead of a grant of this
      module, plus the same allowlist entry.

  `draft!/3` builds, on one free step, a new running `:assignment` run of
  the lead with the `origin:` invocations, then its `:outreach_proposal`
  invocation (`proposal:`), then the `after:` invocations (a higher
  `sequence_in_run`), records the `:llm` `draft_proposal` Decision on the
  proposal invocation, proposes the draft through `Outreach.propose_draft/2`
  citing the `cite:` claims, and makes `edits:` human edits as ADM. Every
  invocation spec is a disposition, or `{disposition, purpose}`:

    * `:fake`: a completed Fake call (not gated; no release);
    * `:released`, `:withheld`: a completed generation-2 ClaudeCLI call with
      that release (`:released` through a reconciled primary v1 link and
      the allowlist, `:withheld` with `:witness_missing`);
    * `:none`: a completed, valid generation-2 call with no release;
    * `:failed`: a generation-2 call that failed after it was sent (no
      release; terminal, so it can never be eligible);
    * `:demo`: a `:demo_exception` release decided by S3's real gate (H2).

  Addendum 3's closure (decision 6) refuses a proposal while a relevant
  gated, in-purpose invocation is still undecided. Every proposed fixture
  here keeps its relevant invocations resolved (Codex S4 r3 binding 3):
  a cited "no release" invocation of a proposed draft is `:failed`, or
  `:none` outside item 1's purposes (`:reply_classification`). The in-purpose
  `:none` variant is used only where nothing is proposed (the pure and
  `propose_facts/2` classification controls, and `release_status/2`).

  Lineage corruptions (`move_to_foreign_tenant!/2`, `reparent!/2`) are
  applied only after the draft exists, by `SdrAgent.AuditCase.tamper!/2`
  (`SET LOCAL` replica role inside the test's sandbox transaction), the
  way the tenant table's singleton makes "another tenant" reachable. They
  never touch a release row.

  ## S3 dependency (one adapter; reconciled once at the rebased base)

  A `:demo_exception` release exists only when S3's gate decides it, and
  S3's test support owns that harness (S3 plan r2 §6 "Test support", §8 H2).
  This module reaches it only through `demo_env!/1` and the `:demo`
  disposition, which call `SdrAgent.DemoExceptionFixtures`:

    * `demo_env!(ctx) :: ctx`: the selector on, the test double attesting a
      spend-ready `agentenv-1` with a test authorization, the owner-form test
      grant (after it, the only grant eligible for this test's ordinary
      `:claude_cli_opus` reservations, with room for about 100 `:b1`
      attempts: T-Q1 (i) makes 31 demo and 63 other generation-2 calls)
      and the clock inside the effective window, so the use authority of
      every release decided in it holds for the rest of the test; restored
      on exit;
    * `demo_invocation!(ctx, run, purpose) :: %{invocation:, release:}`: a
      completed generation-2 ClaudeCLI invocation of `run` (an
      `:assignment` run of a C2* lead) with `purpose`, whose
      `:demo_exception` release the gate decided (constructed v4 link and
      receipt, then `ResultGate.finalize/4`).

  If S3's harness names them differently, only `s3!/2`'s targets change.
  Until then a test using them fails with the "RED dependency" message
  below, which is a dependency failure, not an S4 RED.
  """

  import ExUnit.Assertions

  alias SdrAgent.Actor
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AuditCase
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures

  @s3 SdrAgent.DemoExceptionFixtures
  @witness SdrAgent.Agents.Witness
  @lead_key "01"
  @quote "hiring three SDRs"
  @body "Hello. We noticed you are hiring three SDRs in Denver; here is one idea for the team."
  @moved %{
    model_invocations: "UPDATE model_invocations SET tenant_id = $1 WHERE id = $2",
    evidence_claims: "UPDATE evidence_claims SET tenant_id = $1 WHERE id = $2"
  }

  @doc "The quote every fixture claim grounds, and the cited text in every fixture body."
  def cited_text, do: @quote

  @doc """
  Seeds the base of a test (see the moduledoc): a campaign whose sequence
  has `steps` steps, the hand-off draft of fixture lead "01" on step 1, and
  the research source of the claims. Returns `%{ctx:, lead:, draft:,
  revision:, run:, steps:, source:}`, where `steps` are the free steps in
  position order.
  """
  def base!(ctx, steps \\ 4) do
    sequence = SalesFixtures.sequence_with_steps!(ctx.tenant, steps)
    {:ok, sequence} = Sales.update(sequence, :activate, %{}, actor: ctx.admin)

    attrs =
      Fixtures.campaign()
      |> Map.take([
        :icp_definition_id,
        :sender_name,
        :sender_email,
        :timezone,
        :footer_template_version
      ])
      |> Map.merge(%{name: "C2* S4 fixture #{unique()}", sequence_id: sequence.id})

    {:ok, campaign} = Sales.create_campaign(attrs, actor: ctx.admin)
    {:ok, campaign} = Sales.update(campaign, :activate, %{}, actor: ctx.admin)
    ctx = %{ctx | campaign_id: campaign.id}
    drafted = OutreachFixtures.drafted!(ctx, @lead_key)

    {:ok, all} =
      Sales.list_records(Sales.SequenceStep,
        filter: [sequence_id: sequence.id],
        actor: ctx.admin
      )

    free =
      all
      |> Enum.sort_by(& &1.position)
      |> Enum.reject(&(&1.id == drafted.draft.sequence_step_id))

    drafted
    |> Map.take([:lead, :draft, :revision, :run])
    |> Map.merge(%{ctx: ctx, steps: free, source: source!(ctx, drafted.lead)})
  end

  @doc """
  A base for invocation-only tests (no draft): fixture lead "01" and the
  saved offering profile a new `:assignment` run needs. Returns `%{ctx:, lead:}`.
  """
  def lead_base!(ctx) do
    SdrAgent.SDRCase.ensure_offering!(ctx)
    %{ctx: ctx, lead: SdrAgent.SDRCase.fixture_lead!(ctx, @lead_key)}
  end

  @doc "Makes generation-2 ClaudeCLI calls admissible: `:ordinary` or `:demo` (see the moduledoc)."
  def env!(base, :ordinary) do
    AgentsFixtures.grant!(base.ctx.tenant, %{}, base.ctx.admin)
    allow_release_entry!()
    base
  end

  def env!(base, :demo) do
    ctx = s3!(:demo_env!, [base.ctx])
    allow_release_entry!()
    %{base | ctx: ctx}
  end

  @doc "A new running `:assignment` run of the base's lead."
  def run!(base) do
    definition = AgentsFixtures.definition!(base.ctx.tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, base.lead.id)
    {:ok, run} = Agents.create_run(attrs, actor: base.ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: base.ctx.agent)
    run
  end

  @doc """
  One invocation of `run` for `spec` (a disposition, or `{disposition,
  purpose}`; default purpose `:evidence_extraction`). Returns
  `%{invocation:, release:}` (`release: nil` when it has none).
  """
  def invocation!(base, run, spec) do
    {disposition, purpose} = spec(spec, :evidence_extraction)
    invocation!(base, run, disposition, purpose)
  end

  defp invocation!(base, run, :demo, purpose),
    do: s3!(:demo_invocation!, [base.ctx, run, purpose])

  defp invocation!(base, run, :fake, purpose) do
    attrs = purpose |> key() |> AgentsFixtures.model_attrs() |> Map.put(:purpose, purpose)
    {:ok, reserved} = Agents.reserve_model_invocation(run, attrs, actor: base.ctx.agent)
    %{invocation: complete!(base, reserved), release: nil}
  end

  defp invocation!(base, run, :failed, purpose) do
    sent = sent_claude!(base, run, purpose)
    failure = %{error: %{"code" => "c2star_s4_fixture_failure"}}
    {:ok, failed} = Agents.fail_model_invocation(sent, failure, actor: base.ctx.agent)
    %{invocation: failed, release: nil}
  end

  defp invocation!(base, run, disposition, purpose)
       when disposition in [:none, :released, :withheld] do
    invocation = base |> sent_claude!(run, purpose) |> then(&complete!(base, &1))
    %{invocation: invocation, release: release!(base, invocation, disposition)}
  end

  @doc """
  One invocation, in a new run of the lead, for `spec` (as `invocation!/3`;
  a bare `:none` defaults to `:reply_classification`, outside item 1's
  purposes, so a draft citing it stays valid under addendum 3's closure).
  Returns `%{invocation:, release:, run:}`.
  """
  def cross!(base, spec) do
    run = run!(base)
    {disposition, purpose} = spec(spec, cross_purpose(spec))
    base |> invocation!(run, disposition, purpose) |> Map.put(:run, run)
  end

  @doc """
  An accepted claim of the base's lead, grounded in the base's source, that
  names `invocation_id` in `model_invocation_id` (none when nil).
  """
  def claim!(base, invocation_id) do
    overrides = if invocation_id, do: %{model_invocation_id: invocation_id}, else: %{}

    attrs =
      SalesFixtures.claim_attrs(base.source.artifact, base.source.decision, @quote, overrides)

    {:ok, claim} = Research.record_claim(attrs, actor: base.ctx.agent)
    claim
  end

  @doc "The `:llm` `draft_proposal` Decision of `run` on `invocation` (whole output)."
  def proposal_decision!(base, run, invocation) do
    attrs = %{
      agent_run_id: run.id,
      kind: :draft_proposal,
      mode: :llm,
      subject_resource: "SdrAgent.Sales.Lead",
      subject_id: base.lead.id,
      model_invocation_id: invocation.id,
      output_pointer: "",
      inputs: %{"fixture" => "c2star-s4"},
      outcome: "proposed",
      idempotency_key: "c2star-s4:proposal:#{unique()}"
    }

    {:ok, decision} = Agents.record_decision(attrs, actor: base.ctx.agent)
    decision
  end

  @doc """
  The `Draft :propose` inputs for `step` from `run` and its proposal
  `decision`, citing `claims` (as the public `Outreach.propose_draft/2` takes them).
  """
  def propose_attrs(base, step, run, decision, claims) do
    %{
      lead_id: base.draft.lead_id,
      enrollment_id: base.draft.enrollment_id,
      sequence_step_id: step.id,
      campaign_id: base.draft.campaign_id,
      recipient_contact_id: base.draft.recipient_contact_id,
      origin_agent_run_id: run.id,
      subject: "C2* S4 fixture",
      body_text: @body,
      decision_id: decision.id,
      model_invocation_id: decision.model_invocation_id,
      citations: Enum.map(claims, &%{evidence_claim_id: &1.id, kind: :claim, text: @quote})
    }
  end

  @doc """
  Builds one draft on `step` (see the moduledoc). Options: `origin:` and
  `after:` (invocation specs), `proposal:` (`:released` default, `:fake` or
  `:demo`), `cite:` (each `{:origin, index}`, `{:cross, spec}`,
  `{:claim, claim, entry}` or `:no_invocation`) and `edits:` (default 0).
  Returns `%{draft:, revisions:, run:, origin:, proposal:, after:, claims:,
  cited:, decision:}`; `revisions` are revision 1 first, read as ADM, and
  `cited` holds the `%{invocation:, release:}` behind each claim (nil for
  `:no_invocation`).
  """
  def draft!(base, step, spec \\ []) do
    run = run!(base)
    origin = Enum.map(Keyword.get(spec, :origin, []), &invocation!(base, run, &1))

    proposal =
      invocation!(base, run, {Keyword.get(spec, :proposal, :released), :outreach_proposal})

    later = Enum.map(Keyword.get(spec, :after, []), &invocation!(base, run, &1))

    {claims, cited} =
      spec |> Keyword.get(:cite, []) |> Enum.map(&cite!(base, &1, origin)) |> Enum.unzip()

    decision = proposal_decision!(base, run, proposal.invocation)

    {:ok, draft} =
      Outreach.propose_draft(propose_attrs(base, step, run, decision, claims),
        actor: base.ctx.agent
      )

    {draft, revisions} = edit!(base, draft, Keyword.get(spec, :edits, 0))

    %{
      draft: draft,
      revisions: revisions,
      run: run,
      origin: origin,
      proposal: proposal,
      after: later,
      claims: claims,
      cited: cited,
      decision: decision
    }
  end

  @doc "H2 (plan r2 §5.1): the proposal invocation itself has the `:demo_exception` release."
  def demo_draft!(base, step, opts \\ []),
    do: draft!(base, step, Keyword.merge([proposal: :demo], opts))

  @doc """
  Mixed run (plan r2 §5.1): a demo-released extraction invocation, a claim
  recorded with its id, and a `:released` proposal in the same run citing it.
  """
  def mixed_draft!(base, step, opts \\ []) do
    spec = [origin: [{:demo, :evidence_extraction}], proposal: :released, cite: [{:origin, 0}]]
    draft!(base, step, Keyword.merge(spec, opts))
  end

  @doc """
  Cross run (plan r2 §5.1, handback r3 §1.3): a `:released` proposal citing
  claims extracted in other runs of the lead by a demo, a Fake, a released,
  a withheld and a failed (no-release) invocation.
  """
  def cross_run_draft!(base, step, opts \\ []) do
    cite = Enum.map([:demo, :fake, :released, :withheld, :failed], &{:cross, &1})
    draft!(base, step, Keyword.merge([proposal: :released, cite: cite], opts))
  end

  @doc """
  The ordinary control (T-M6, T-M9): a withheld and a released origin-run
  call, a released proposal, and claims of a Fake, a released, a withheld,
  a failed and an off-purpose no-release invocation of other runs, of an
  origin-run call, and naming no invocation. Nothing is `:demo_exception`.
  """
  def ordinary_draft!(base, step, opts \\ []) do
    cite =
      [{:cross, :fake}, {:cross, :released}, {:cross, :withheld}, {:cross, :failed}] ++
        [{:cross, {:none, :reply_classification}}, {:origin, 1}, :no_invocation]

    spec = [
      origin: [{:withheld, :qualification}, {:released, :evidence_extraction}],
      proposal: :released,
      cite: cite
    ]

    draft!(base, step, Keyword.merge(spec, opts))
  end

  @doc """
  T-M10 (handback r3 §1.3): the claim's FK to the invocation is not
  tenant-scoped (`evidence_claim.ex:35`), so a claim can name an invocation
  of another tenant. Moves the row behind `table` (`:model_invocations` or
  `:evidence_claims`) `id` into a random other tenant (sandbox only).
  """
  def move_to_foreign_tenant!(table, id) when is_map_key(@moved, table) do
    AuditCase.tamper!(Map.fetch!(@moved, table), [dump(Ash.UUIDv7.generate()), dump(id)])
  end

  @doc "A corrupted lineage (sandbox only): `revision`'s parent becomes `parent_id`."
  def reparent!(revision, parent_id) do
    AuditCase.tamper!(
      "UPDATE draft_revisions SET parent_revision_id = $1 WHERE id = $2",
      [dump(parent_id), dump(revision.id)]
    )
  end

  @doc "`{release.id, invocation.id}` of each entry whose release is `:demo_exception`."
  def demo_pairs(entries) do
    for %{release: %{disposition: :demo_exception} = release, invocation: invocation} <-
          entries,
        do: {release.id, invocation.id}
  end

  @doc "`{revision.id, revision.draft_id}` of each revision, the loader's input."
  def pairs(revisions), do: Enum.map(revisions, &{&1.id, &1.draft_id})

  ## Helpers

  defp source!(ctx, lead) do
    %{run: run} = AgentsFixtures.running_run(ctx.tenant)
    tool = SalesFixtures.tool_invocation!(ctx.tenant, run)
    url = %{source_url: "fixture://web/c2star-s4-#{unique()}"}
    attrs = SalesFixtures.artifact_attrs(lead, run, tool, url)
    {:ok, artifact} = Research.record_artifact(attrs, actor: ctx.agent)
    %{artifact: artifact, decision: SalesFixtures.extraction_decision!(ctx.tenant, run, artifact)}
  end

  defp cite!(base, {:origin, index}, origin) do
    entry = Enum.at(origin, index)
    {claim!(base, entry.invocation.id), entry}
  end

  defp cite!(base, {:cross, spec}, _origin) do
    entry = cross!(base, spec)
    {claim!(base, entry.invocation.id), entry}
  end

  defp cite!(_base, {:claim, claim, entry}, _origin), do: {claim, entry}
  defp cite!(base, :no_invocation, _origin), do: {claim!(base, nil), nil}

  defp sent_claude!(base, run, purpose) do
    attrs = purpose |> key() |> AgentsFixtures.claude_attrs() |> Map.put(:purpose, purpose)

    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs, actor: base.ctx.agent)
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: base.ctx.agent)
    sent
  end

  defp complete!(base, %{status: :reserved} = reserved) do
    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: base.ctx.agent)
    complete!(base, sent)
  end

  defp complete!(base, sent) do
    {:ok, done} =
      Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: base.ctx.agent)

    done
  end

  defp release!(_base, _invocation, :none), do: nil

  defp release!(base, invocation, :withheld) do
    attrs = %{
      model_invocation_id: invocation.id,
      disposition: :withheld,
      reason: :witness_missing
    }

    {:ok, release} = Agents.decide_result_release(attrs, actor: base.ctx.agent)
    release
  end

  defp release!(base, invocation, :released) do
    rec = Actor.system(:reconciler, invocation.tenant_id)
    link = AgentsFixtures.reconciled_link!(invocation, rec)

    attrs = %{
      model_invocation_id: invocation.id,
      disposition: :released,
      reason: :reconciled,
      wire_witness_link_id: link.id
    }

    {:ok, release} = Agents.decide_result_release(attrs, actor: base.ctx.agent)
    release
  end

  defp edit!(base, draft, edits) do
    {draft, ids} =
      Enum.reduce(1..edits//1, {draft, [draft.current_revision_id]}, fn n, {current, ids} ->
        attrs = %{subject: "C2* S4 fixture edit #{n}", body_text: @body}
        {:ok, edited} = Outreach.edit_draft(current, attrs, actor: base.ctx.admin)
        {edited, ids ++ [edited.current_revision_id]}
      end)

    {draft, Enum.map(ids, &OutreachFixtures.revision!(base.ctx, &1))}
  end

  # The v1 release allowlist entry of the synthetic links, added to the
  # current entries (S3's included) and restored on exit.
  defp allow_release_entry! do
    previous = Application.get_env(:sdr_agent, @witness, [])
    entries = Keyword.get(previous, :reconciled_methods, [])
    AgentsFixtures.put_allowlist!(Enum.uniq([AgentsFixtures.release_entry() | entries]))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:sdr_agent, @witness, previous) end)
  end

  defp s3!(fun, args) do
    arity = length(args)

    assert Code.ensure_loaded?(@s3) and function_exported?(@s3, fun, arity),
           "C2* S4 RED dependency (S3 H2 harness, not S4): " <>
             "#{inspect(@s3)}.#{fun}/#{arity} is not available"

    apply(@s3, fun, args)
  end

  defp spec({disposition, purpose}, _default), do: {disposition, purpose}
  defp spec(disposition, default) when is_atom(disposition), do: {disposition, default}

  defp cross_purpose(:none), do: :reply_classification
  defp cross_purpose(_spec), do: :evidence_extraction

  defp key(purpose), do: "c2star-s4:#{purpose}:#{unique()}"
  defp unique, do: System.unique_integer([:positive])
  defp dump(id), do: Ecto.UUID.dump!(id)
end
