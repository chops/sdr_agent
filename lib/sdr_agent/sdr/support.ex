defmodule SdrAgent.SDR.Support do
  @moduledoc """
  Shared steps of the SDR actions: tenant-scoped reads as the agent runtime,
  the authoritative draft the deterministic draft checks measure
  (`authoritative_draft/3`, B1-R1), recording research artifacts (full
  content as a Payload, freshness computed at retrieval), the deterministic
  gates (campaign state, suppression — spec §8, never the model), and signal
  directives.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.SDR.Signals
  alias SdrAgent.SDR.SuppressionCheck

  @excerpt 300
  # B1-R1: fixed, content-free stop reasons (no identifier, setting or
  # proposal text).
  @not_this_draft "the draft is not this run's draft"
  @unreadable_draft "the draft's stored output failed schema validation"

  @doc "Reads one Sales record as the agent."
  def fetch(%Context{actor: actor}, resource, id), do: Sales.fetch(resource, id, actor: actor)

  @doc "The lead, its contact and account."
  def lead_context(%Context{} = ctx, lead_id) do
    with {:ok, lead} <- fetch(ctx, Sales.Lead, lead_id),
         {:ok, contact} <- fetch(ctx, Sales.Contact, lead.contact_id),
         {:ok, account} <- fetch(ctx, Sales.Account, lead.account_id) do
      {:ok, %{lead: lead, contact: contact, account: account}}
    end
  end

  @doc "Accepted evidence claims of a lead."
  def accepted_claims(%Context{actor: actor}, lead_id) do
    Research.list_records(Research.EvidenceClaim,
      filter: [lead_id: lead_id, quality: :accepted],
      actor: actor
    )
  end

  @doc """
  B1-R1 (Codex PR #234 review, plans `claude-b1-r1-neighbor-validators-delta-r1.md`
  and `claude-b1-r1-version-route-r1.md`): the authoritative draft of this
  run about `lead_id`, named by the draft map's `decision_id` and
  `model_invocation_id`. The map's `proposal`, when present, is never read.

  The Decision must be this run's `:draft_proposal` (`:llm`) in the actor's
  tenant, about `lead_id` (the run's lead), citing exactly the named
  ModelInvocation, itself of this run in that tenant. The content is that
  invocation's output through the released-output read
  (`SdrAgent.Agents.released_output/2`, never a direct `parsed_output`),
  parsed by the OutreachProposal schema.

  Returns `{:ok, %{decision: decision, invocation: invocation, proposal:
  proposal}}`, or fails closed before any Decision with no identifier,
  setting or proposal text in the failure:

    * a missing or mismatched row: the run stops `:crash` with the fixed
      reason #{inspect(@not_this_draft)};
    * an output the result gate withholds: `{:error, {:halt,
      :result_not_released}}`, with the run left for recovery (R0-07);
    * a stored output the schema refuses: the run fails
      `:invalid_model_output` with a fixed reason.
  """
  def authoritative_draft(%Context{} = ctx, lead_id, %{} = draft) do
    with {:ok, decision, invocation} <- draft_pair(ctx, lead_id, draft),
         {:ok, proposal} <- released_proposal(ctx, invocation) do
      {:ok, %{decision: decision, invocation: invocation, proposal: proposal}}
    end
  end

  def authoritative_draft(%Context{} = ctx, _lead_id, _draft),
    do: Model.halt_fail(ctx, nil, :crash, @not_this_draft)

  defp draft_pair(ctx, lead_id, draft) do
    with decision_id when is_binary(decision_id) <- Map.get(draft, :decision_id),
         invocation_id when is_binary(invocation_id) <- Map.get(draft, :model_invocation_id),
         {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         {:ok, decision} <- Agents.get_decision(decision_id, actor: ctx.actor),
         {:ok, invocation} <- Agents.get_model_invocation(invocation_id, actor: ctx.actor),
         true <- draft_of?(ctx, run, lead_id, decision, invocation) do
      {:ok, decision, invocation}
    else
      _mismatch -> Model.halt_fail(ctx, nil, :crash, @not_this_draft)
    end
  end

  # This run's draft Decision about its lead, citing exactly this
  # invocation of this run, all in the actor's tenant.
  defp draft_of?(ctx, run, lead_id, decision, invocation) do
    run_of?(ctx, run, lead_id) and draft_decision?(ctx, run, lead_id, decision) and
      decision.model_invocation_id == invocation.id and
      invocation.tenant_id == ctx.tenant_id and invocation.agent_run_id == run.id
  end

  defp run_of?(ctx, run, lead_id),
    do: run.id == ctx.run_id and run.tenant_id == ctx.tenant_id and run.lead_id == lead_id

  defp draft_decision?(ctx, run, lead_id, decision) do
    decision.tenant_id == ctx.tenant_id and decision.agent_run_id == run.id and
      decision.kind == :draft_proposal and decision.mode == :llm and
      decision.subject_resource == "SdrAgent.Sales.Lead" and decision.subject_id == lead_id
  end

  defp released_proposal(ctx, invocation) do
    case Agents.released_output(invocation, actor: ctx.actor) do
      {:ok, released} when is_map(released) ->
        case Zoi.parse(Schemas.outreach_proposal(), released) do
          {:ok, proposal} -> {:ok, proposal}
          {:error, _errors} -> Model.halt_fail(ctx, nil, :invalid_model_output, @unreadable_draft)
        end

      {:ok, _not_a_map} ->
        Model.halt_fail(ctx, nil, :invalid_model_output, @unreadable_draft)

      {:error, :result_not_released} ->
        {:error, {:halt, :result_not_released}}

      {:error, _other} ->
        Model.halt_fail(ctx, nil, :crash, @not_this_draft)
    end
  end

  @doc """
  Records a research artifact retrieved by the current tool invocation and
  returns its summary (with the full `content`, which later steps ground
  claims against) and an external request ref.
  """
  def record_artifact(%Context{} = ctx, lead_id, attrs) do
    content = Map.fetch!(attrs, :content)

    attrs =
      attrs
      |> Map.merge(%{
        lead_id: lead_id,
        agent_run_id: ctx.run_id,
        tool_invocation_id: ctx.tool_invocation.id,
        retrieved_at: SdrAgent.Clock.utc_now(),
        excerpt: String.slice(content, 0, @excerpt),
        freshness: freshness(Map.get(attrs, :published_at))
      })

    with {:ok, artifact} <- Research.record_artifact(attrs, actor: ctx.actor) do
      digest = Base.encode16(artifact.content_sha256, case: :lower)

      summary = %{
        id: artifact.id,
        source_type: artifact.source_type,
        source_url: artifact.source_url,
        title: artifact.title,
        trust_level: artifact.trust_level,
        freshness: artifact.freshness,
        content: content
      }

      ref = %{
        provider: Atom.to_string(artifact.provider),
        request_id: artifact.source_url,
        target: artifact.source_url,
        response_sha256: digest
      }

      {:ok, summary, ref}
    end
  end

  @doc "Freshness of a source at retrieval (S5 choice 13: computed by the retrieving action)."
  def freshness(nil), do: :unknown

  def freshness(%DateTime{} = published_at) do
    case DateTime.diff(SdrAgent.Clock.utc_now(), published_at, :day) do
      days when days <= 30 -> :current
      days when days <= 180 -> :recent
      _ -> :stale
    end
  end

  @doc """
  Deterministic campaign-state gate: records a `campaign_state_check`
  Decision (outcome `active` or `not_active`) and returns it.
  """
  def campaign_gate(%Context{} = ctx, campaign, lead_id, point) do
    Context.decide(
      ctx,
      %{
        kind: :campaign_state_check,
        mode: :deterministic,
        rule_id: "sdr.campaign_state_check",
        rule_version: "1",
        subject_id: lead_id,
        inputs: %{"campaign_id" => campaign.id, "status" => Atom.to_string(campaign.status)},
        outcome: if(campaign.status == :active, do: "active", else: "not_active")
      },
      point,
      [campaign]
    )
  end

  @doc """
  Deterministic suppression gate through the configured
  `SdrAgent.SDR.SuppressionCheck`: records a `suppression_check` Decision
  (outcome `suppressed` or `not_suppressed`) and returns it.
  """
  def suppression_gate(%Context{} = ctx, contact, lead_id, point) do
    check = SuppressionCheck.impl()

    with {:ok, verdict, detail} <-
           check.check(to_string(contact.email), %{
             tenant_id: ctx.tenant_id,
             contact_id: contact.id
           }) do
      Context.decide(
        ctx,
        %{
          kind: :suppression_check,
          mode: :deterministic,
          rule_id: "sdr.suppression_check",
          rule_version: "1",
          subject_id: lead_id,
          inputs: %{
            "contact_id" => contact.id,
            "email" => to_string(contact.email),
            "checker" => inspect(check),
            "detail" => detail
          },
          outcome: Atom.to_string(verdict)
        },
        point,
        [contact]
      )
    end
  end

  @doc "A deterministic `phase_transition` Decision about the lead."
  def phase_decision(%Context{} = ctx, lead_id, point, outcome, inputs, refs \\ []) do
    Context.decide(
      ctx,
      %{
        kind: :phase_transition,
        mode: :deterministic,
        rule_id: "sdr.#{point}",
        rule_version: "1",
        subject_id: lead_id,
        inputs: inputs,
        outcome: outcome
      },
      point,
      refs
    )
  end

  @doc "An `Emit` directive for a new signal of `type`."
  def emit(type, data) do
    {:ok, signal} = Signals.build(type, data)
    Jido.Agent.Directive.emit(signal)
  end

  @doc "The run's current budget counters, as agent working state."
  def budget(%Context{} = ctx) do
    {:ok, run} = Agents.get_run(ctx.run_id, actor: ctx.actor)
    %{model_calls: run.budget.model_calls_used, tool_calls: run.budget.tool_calls_used}
  end
end
