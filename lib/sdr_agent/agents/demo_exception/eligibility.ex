defmodule SdrAgent.Agents.DemoException.Eligibility do
  @moduledoc """
  Eligibility of the C2* demo exception (ADR-0005 C2* amendment item 4; S3
  plan r2 §6). It holds:

    * the pure steps `e1_seed/1`, `e2/1`, `e4/2` and `e5/3`;
    * the fact loader `load/2`: plain reads in the invocation's tenant, with
      no lock clause, made by the release decision under the chain head;
    * the full evaluation `evaluate/2` in the closed refusal-code order.

  It writes nothing and does no file I/O. Authority comes only through
  `SdrAgent.Agents.DemoException`'s Source functions.

  `e4/2`, the positive v4 comparison, on the receipt's primary link of a
  ModelInvocation. It is `:ok` only when every one of these holds, and
  `{:refused, :link_not_eligible}` otherwise (the OQ7 code for E4):

    * the link is the invocation's, `:inferred` and `:propagated_id`;
    * `WitnessEvidence.validate/1` accepts the full evidence unchanged and
      `WitnessEvidence.validate_claim/1` returns `:ok` for it;
    * the extracted group (the evidence restricted to the v3 context-group
      keys plus the R keys present) passes `WitnessEvidence.exact_v4_group?/1`.
      The helper is never applied to the full evidence;
    * the evidence is a primary v4 claim with `projections_inapplicable`
      `["v2"]`, layout `reasoning_then_text`, and integer block counts 0..4
      totalling 1..4;
    * the ordinary release's identity check passes (it mirrors the
      `ReleaseDecision` check, `release_decision.ex:344-350`);
    * all four projection digests are present lowercase hex-64 values and
      each projected digest equals its observed one. An absent digest never
      matches another absent one;
    * the capture is complete: outcome `complete`, HTTP 200, both captures
      complete, the stream complete, and a reviewed proxy version
      (`SdrAgent.Agents.Witness.proxy_versions/0`);
    * the reason codes, compared as a set on a copy, have no duplicate and
      are exactly {`method_not_enabled`} or {`method_not_enabled`,
      `cli_injected_context`}. Persisted order is irrelevant and the
      evidence is never sorted, rewritten or repaired.

  That the link is the invocation's single current primary link, with no
  successor, needs the current links; it belongs to the full evaluation,
  not to this function.
  """

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.DemoException.Attestation
  alias SdrAgent.Agents.DemoException.Authorization
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Contact
  alias SdrAgent.Sales.Lead
  alias SdrAgent.Sales.Synthetic

  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"
  @r_keys ~w(response_layout response_thinking_count response_redacted_thinking_count)
  @counts ~w(response_thinking_count response_redacted_thinking_count)
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @digest_pairs [
    {"projected_request_sha256", "observed_request_projection_sha256"},
    {"projected_response_sha256", "observed_response_projection_sha256"}
  ]
  @receipt_codes MapSet.new(["method_not_enabled", "cli_injected_context"])
  @code_sets [
    MapSet.new(["method_not_enabled"]),
    MapSet.new(["method_not_enabled", "cli_injected_context"])
  ]

  @doc """
  E4, the positive v4 comparison, for `link` (the receipt's primary link)
  of `invocation`: `:ok` or `{:refused, :link_not_eligible}`.
  """
  @spec e4(struct(), struct()) :: :ok | {:refused, :link_not_eligible}
  def e4(%WireWitnessLink{} = link, %ModelInvocation{} = invocation) do
    evidence = link.evidence

    # In order, stopping at the first false: later checks read evidence keys
    # only after the contract check has proved the evidence a valid map.
    checks = [
      fn -> link_of?(link, invocation) end,
      fn -> contract?(evidence) end,
      fn -> claim?(evidence) end,
      fn -> same_identity?(invocation, evidence) end,
      fn -> digests?(evidence) end,
      fn -> complete?(evidence) end,
      fn -> codes?(evidence["reason_codes"]) end
    ]

    if Enum.all?(checks, & &1.()), do: :ok, else: {:refused, :link_not_eligible}
  end

  defp link_of?(link, invocation) do
    link.model_invocation_id == invocation.id and link.link_status == :inferred and
      link.method == :propagated_id
  end

  # The full evidence validates unchanged, its claim holds, and the extracted
  # group (never the full map) is exactly the v4 group.
  defp contract?(evidence) when is_map(evidence) do
    WitnessEvidence.validate(evidence) == {:ok, evidence} and
      WitnessEvidence.validate_claim(evidence) == :ok and
      WitnessEvidence.exact_v4_group?(extracted(evidence))
  end

  defp contract?(_evidence), do: false

  defp extracted(evidence) do
    Map.take(
      evidence,
      WitnessEvidence.context_group(@v3) ++ Enum.filter(@r_keys, &Map.has_key?(evidence, &1))
    )
  end

  defp claim?(evidence) do
    counts = Enum.map(@counts, &evidence[&1])

    evidence["classification"] == "primary" and evidence["projection_version"] == @v4 and
      evidence["projections_inapplicable"] == ["v2"] and
      evidence["response_layout"] == "reasoning_then_text" and
      Enum.all?(counts, &(is_integer(&1) and &1 in 0..4)) and Enum.sum(counts) in 1..4
  end

  # The ordinary release's identity check (release_decision.ex:344-350).
  defp same_identity?(invocation, evidence) do
    WitnessEvidence.check_identity(invocation, evidence) == :ok and
      map_size(WitnessEvidence.identity(invocation)) == 2 and
      evidence["cli_version"] == invocation.provider_version and
      evidence["app_request_sha256"] == hex(invocation.request_sha256) and
      evidence["app_response_sha256"] == hex(invocation.response_sha256)
  end

  defp digests?(evidence) do
    Enum.all?(@digest_pairs, fn {projected, observed} ->
      hex64?(evidence[projected]) and evidence[projected] == evidence[observed]
    end)
  end

  defp hex64?(value), do: is_binary(value) and Regex.match?(@hex64, value)

  defp complete?(evidence) do
    evidence["outcome"] == "complete" and evidence["http_status"] == 200 and
      evidence["request_capture_complete"] == true and
      evidence["response_capture_complete"] == true and evidence["stream_complete"] == true and
      evidence["proxy_version"] in Witness.proxy_versions()
  end

  # A comparison copy only: the persisted list is never sorted or repaired.
  defp codes?(codes) when is_list(codes),
    do: codes == Enum.uniq(codes) and MapSet.new(codes) in @code_sets

  defp codes?(_codes), do: false

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  ## The full evaluation (GREEN-3a)

  @doc """
  E2: the invocation's recorded identity (provider, CLI version, profile,
  model, the prompt builder recorded in its `model_catalog_entry`, ledger
  generation) equals the ENTRY's identity, absolutely; then the output is
  `:completed` and `:valid`. `:ok`, `{:refused, :identity_mismatch}` or
  `{:refused, :output_invalid}`, identity first.
  """
  @spec e2(struct()) :: :ok | {:refused, :identity_mismatch | :output_invalid}
  def e2(%ModelInvocation{} = invocation) do
    identity = DemoException.entry().identity

    catalog =
      if is_map(invocation.model_catalog_entry), do: invocation.model_catalog_entry, else: %{}

    recorded =
      {invocation.provider, invocation.provider_version, invocation.profile_id,
       invocation.model_id, catalog["prompt_builder"], invocation.ledger_generation}

    expected =
      {identity.provider, identity.cli_version, identity.profile_id, identity.model_id,
       identity.prompt_builder, identity.ledger_generation}

    cond do
      recorded != expected -> {:refused, :identity_mismatch}
      invocation.status != :completed -> {:refused, :output_invalid}
      invocation.validation_status != :valid -> {:refused, :output_invalid}
      true -> :ok
    end
  end

  @doc """
  E1's seed scope over loaded facts (`tenant_id`, `lead_id`, `lead`,
  `creation_events`, `account_domain`, `contact_email`): the run's lead id
  is one of the entry's, the lead row is that id in the tenant, it has
  exactly one `sales.lead.created` event in the tenant and that event's
  actor type is `:seeder`, and the account domain and contact email pass
  the reserved-name guards (`SdrAgent.Sales.Synthetic`) now. `:ok` or
  `{:refused, :scope_mismatch}`.
  """
  @spec e1_seed(map()) :: :ok | {:refused, :scope_mismatch}
  def e1_seed(%{tenant_id: tenant_id, lead_id: lead_id} = facts) do
    seeded? =
      lead_id in DemoException.entry().lead_ids and
        match?(%{id: ^lead_id, tenant_id: ^tenant_id}, facts.lead) and
        match?(
          [
            %{
              event_type: "sales.lead.created",
              actor_type: :seeder,
              tenant_id: ^tenant_id,
              subject_id: ^lead_id
            }
          ],
          facts.creation_events
        ) and Synthetic.reserved_domain?(facts.account_domain) and
        Synthetic.reserved_email?(facts.contact_email)

    if seeded?, do: :ok, else: {:refused, :scope_mismatch}
  end

  @doc """
  E5 over the persisted rows: `primary` (the receipt's link), `links`
  (every link of the invocation, current and superseded) and `failures`
  (its `reconciliation_required` Failures, any status). Clean when no link
  ever was a mismatch, every other CURRENT link is `ancillary`, and no
  Failure is critical (any status) or a live (not resolved) warning.
  `:ok` or `{:refused, :invocation_not_clean}`.
  """
  @spec e5(struct(), [struct()], [map()]) :: :ok | {:refused, :invocation_not_clean}
  def e5(primary, links, failures) do
    others = Enum.reject(current(links), &(&1.id == primary.id))

    clean? =
      not Enum.any?(links, &(&1.link_status == :mismatch)) and
        Enum.all?(others, &(&1.evidence["classification"] == "ancillary")) and
        not Enum.any?(failures, &unclean_failure?/1)

    if clean?, do: :ok, else: {:refused, :invocation_not_clean}
  end

  defp unclean_failure?(%{class: :reconciliation_required, severity: :critical}), do: true

  defp unclean_failure?(%{class: :reconciliation_required, severity: :warning, status: status}),
    do: status != :resolved

  defp unclean_failure?(_failure), do: false

  @doc "The current links of `links` (those no other link supersedes), sorted by id."
  @spec current([struct()]) :: [struct()]
  def current(links) do
    superseded = MapSet.new(links, & &1.supersedes_id)
    links |> Enum.reject(&MapSet.member?(superseded, &1.id)) |> Enum.sort_by(& &1.id)
  end

  @doc """
  The facts of one decision, read with plain reads (no lock clause, no file
  I/O) in `invocation`'s tenant under the caller's locks and chain head:
  the run, every link (current and superseded) and the one named
  `link_id`, the funding grant and allocation, the invocation's
  `reconciliation_required` Failures, the run's lead, its account domain
  and contact email, and its `sales.lead.created` events. Never supplied by
  a caller.
  """
  @spec load(struct(), Ecto.UUID.t() | nil) :: map()
  def load(%ModelInvocation{tenant_id: tenant_id} = invocation, link_id) do
    run = by_id(AgentRun, invocation.agent_run_id, tenant_id)
    links = links(invocation)
    lead_id = run && run.lead_id
    lead = by_id(Lead, lead_id, tenant_id)
    account = lead && by_id(Account, lead.account_id, tenant_id)
    contact = lead && by_id(Contact, lead.contact_id, tenant_id)

    %{
      tenant_id: tenant_id,
      invocation: invocation,
      run: run,
      links: links,
      primary: Enum.find(links, &(&1.id == link_id)),
      grant: by_id(ModelCallGrant, invocation.grant_id, tenant_id),
      allocation: by_id(ModelCallAllocation, invocation.allocation_id, tenant_id),
      failures: failures(invocation),
      lead_id: lead_id,
      lead: lead,
      creation_events: creation_events(lead_id, tenant_id),
      account_domain: account && to_string(account.domain),
      contact_email: contact && to_string(contact.email)
    }
  end

  @doc """
  The full E1-E5 evaluation of loaded `facts` (`load/2`, plus optional
  `receipt` and `kind` from the finalizer) at instant `t`, in the closed
  code order (`SdrAgent.Agents.DemoException.refusal_codes/0`):
  `{:ok, authority}` (`attestation`, `authorization`, `starts_at`,
  `expires_at`) or `{:refused, code}`. Decision authority reads the
  process's active snapshot through the Source (`attestation/0`, then
  `authorization/1` and the live binding read `live_binding?/2`), then
  `delegated_grant?/2`. With a receipt, E4 and E5 also require it to name
  the link, be `:inferred` from an `:ok` outcome and carry only
  `method_not_enabled`/`cli_injected_context`.
  """
  @spec evaluate(map(), DateTime.t()) :: {:ok, map()} | {:refused, atom()}
  def evaluate(facts, %DateTime{} = t) do
    with :ok <- active(facts),
         {:ok, attestation, authorization} <- authority(facts),
         {:ok, starts_at, expires_at} <- window(facts, authorization, t),
         :ok <- scope(facts, attestation, authorization),
         :ok <- e2(facts.invocation),
         :ok <- promotion(facts.invocation),
         :ok <- link(facts),
         :ok <- clean(facts) do
      {:ok,
       %{
         attestation: attestation,
         authorization: authorization,
         starts_at: starts_at,
         expires_at: expires_at
       }}
    end
  end

  defp active(facts) do
    if DemoException.selected?() and not DemoException.inert?() and
         Map.get(facts, :kind, :ok) != :interrupted,
       do: :ok,
       else: {:refused, :exception_off}
  end

  defp authority(%{tenant_id: tenant_id}) do
    entry_sha256 = DemoException.entry_sha256()
    authorization_id = DemoException.entry().authorization_id

    with {:ok,
          %Attestation{
            level: :spend_ready,
            environment_id: "agentenv-1",
            tenant_id: ^tenant_id,
            authorization: %{id: ^authorization_id, entry_sha256: ^entry_sha256}
          } = attestation} <- DemoException.attestation(),
         {:ok, %Authorization{id: ^authorization_id, entry_sha256: ^entry_sha256} = auth} <-
           DemoException.authorization(authorization_id),
         true <- DemoException.live_binding?(attestation, tenant_id) do
      {:ok, attestation, auth}
    else
      _ -> {:refused, :environment_unattested}
    end
  end

  defp window(%{grant: grant, allocation: allocation}, authorization, t)
       when not is_nil(grant) and not is_nil(allocation) do
    {starts_at, expires_at} = DemoException.effective_window(grant, allocation, authorization)

    if DateTime.compare(starts_at, t) != :gt and DateTime.compare(t, expires_at) == :lt,
      do: {:ok, starts_at, expires_at},
      else: {:refused, :outside_window}
  end

  defp window(_facts, _authorization, _t), do: {:refused, :scope_mismatch}

  # E1: the running run and the call are in the entry's scope, the call is
  # charged to the attested authorization's active grant through one of its
  # allocations, the seed scope holds, and the grant is delegated.
  defp scope(facts, attestation, authorization) do
    in_scope? =
      run_scope?(facts) and funded?(facts, attestation) and e1_seed(facts) == :ok and
        DemoException.delegated_grant?(facts.grant, authorization)

    if in_scope?, do: :ok, else: {:refused, :scope_mismatch}
  end

  defp run_scope?(%{run: %AgentRun{status: :running} = run, invocation: invocation}) do
    entry = DemoException.entry()

    run.id == invocation.agent_run_id and run.usage_origin in entry.usage_origins and
      invocation.purpose in entry.purposes
  end

  defp run_scope?(_facts), do: false

  defp funded?(%{invocation: invocation, grant: grant, allocation: allocation}, attestation) do
    grant.status == :active and invocation.grant_id == grant.id and
      attestation.authorization.grant_id == grant.id and
      invocation.allocation_id == allocation.id and allocation.grant_id == grant.id
  end

  defp promotion(invocation) do
    if Witness.allowlisted?(invocation, @v3, :propagated_id) and
         not Witness.allowlisted?(invocation, @v4, :propagated_id),
       do: :ok,
       else: {:refused, :promotion_gap_not_v4}
  end

  # E4 on the receipt's primary link: named (and, with a receipt, the
  # receipt's), this invocation's single current primary, and positive.
  defp link(%{primary: nil}), do: {:refused, :link_not_eligible}

  defp link(%{primary: primary, links: links, invocation: invocation} = facts) do
    primaries = Enum.filter(current(links), &(&1.evidence["classification"] == "primary"))

    named? =
      case Map.get(facts, :receipt) do
        nil -> true
        receipt -> receipt.link_id == primary.id
      end

    if named? and Enum.map(primaries, & &1.id) == [primary.id],
      do: e4(primary, invocation),
      else: {:refused, :link_not_eligible}
  end

  defp clean(facts) do
    receipt_clean? =
      case Map.get(facts, :receipt) do
        nil ->
          true

        receipt ->
          Map.get(facts, :kind, :ok) == :ok and receipt.status == :inferred and
            MapSet.subset?(MapSet.new(receipt.codes), @receipt_codes)
      end

    if receipt_clean?,
      do: e5(facts.primary, facts.links, facts.failures),
      else: {:refused, :invocation_not_clean}
  end

  defp by_id(_resource, nil, _tenant_id), do: nil

  defp by_id(resource, id, tenant_id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!()
  end

  defp links(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!()
  end

  defp failures(invocation) do
    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and class == :reconciliation_required and
        subject_resource == "SdrAgent.Agents.ModelInvocation" and subject_id == ^invocation.id
    )
    |> Ash.read!()
  end

  defp creation_events(nil, _tenant_id), do: []

  defp creation_events(lead_id, tenant_id) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and event_type == "sales.lead.created" and
        subject_resource == "SdrAgent.Sales.Lead" and subject_id == ^lead_id
    )
    |> Ash.read!()
  end
end
