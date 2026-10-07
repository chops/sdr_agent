defmodule SdrAgent.SDR.Support do
  @moduledoc """
  Shared steps of the SDR actions: tenant-scoped reads as the agent runtime,
  recording research artifacts (full content as a Payload, freshness
  computed at retrieval), the deterministic gates (campaign state,
  suppression — spec §8, never the model), and signal directives.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Signals
  alias SdrAgent.SDR.SuppressionCheck

  @excerpt 300

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
