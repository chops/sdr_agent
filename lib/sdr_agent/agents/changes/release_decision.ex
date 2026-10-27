defmodule SdrAgent.Agents.Changes.ReleaseDecision do
  @moduledoc """
  `SdrAgent.Agents.ModelResultRelease` `:decide` rules (R0-07 entity PASS at
  1da747a), checked inside the action transaction:

    1. Statically: an allowed disposition/reason pair
       (`ModelResultRelease.allowed_pair?/2`); `evidence_sha256` present for
       `:calibration` and absent otherwise; a link for `:released`.
    2. Before the insert, with no row lock requested after the chain head
       (the event is appended in an after-action hook): the invocation is
       re-read **in the release's tenant** and locked `FOR SHARE`, then the
       link, when given, `FOR SHARE`. Link writes lock the invocation
       `FOR UPDATE`, so no successor can appear while the decision holds it.
       Under a verified `SdrAgent.Agents.ReleaseDecision.Prelocked` context
       (its finalizer already holds those locks; every binding, the receipt
       included, matches) they are read with no lock clause; a refused
       context writes nothing.
       When the invocation already has a release, nothing else is checked:
       the upsert returns that row and step 4 compares it.
    3. Per disposition (any validated link's projection and method are
       copied onto the release, whatever the disposition):
       * `:released` / `:withheld`: a completed generation-2 ClaudeCLI
         invocation of a non-`:proof` run; `:released` also needs a `:valid`
         output and a link that is this invocation's current, reconciled
         primary link, leaving the invocation `reconciled`, whose evidence
         names the invocation's CLI version, model, profile (round 5 item 7)
         and application digests, and
         whose exact tuple is on the shipped allowlist;
       * `:calibration`: `SdrAgent.Agents.Checks.CalibrationContext` bound
         to this invocation and its profile, a generation-2 ClaudeCLI
         invocation of a `:proof` run in any terminal status;
       * any given link must be this invocation's current link.
    4. After the upsert: a fresh row passes; an existing row with the same
       disposition, reason, link and evidence — and the same gate cause
       bound by its withheld event (R0-07 R7-1,
       `SdrAgent.Agents.ReleaseDecision.Binding`) — is an identical replay
       (marked so no second event is appended); anything else fails with
       `SdrAgent.Agents.Errors.ReleaseConflict`.

  5. C2* `:demo_exception` (S3 plan r2 §6, §6.1; ADR-0005 C2* items 4-8):
     only under the result-gate finalizer's verified context
     (`finalizer: :result_gate`, no receipt) whose current link ids, funding
     grant and allocation and snapshot generation equal the locked state,
     with no lock clause. A new decision re-evaluates E1-E6 authoritatively
     at the context's own instant (`SdrAgent.Agents.DemoException.Eligibility`,
     facts read here with plain reads) and records the closed basis, the
     four exception columns and that instant, or is refused with
     `SdrAgent.Agents.Errors.DemoExceptionRefused` carrying the first
     failing code. An existing demo row is an identical replay only when
     its stored basis validates against its own recorded policy and window
     and its digest, with L re-derived from the locked rows, is the row's;
     anything else, and any existing row of another disposition, is a
     `ReleaseConflict`. While the selector is on, a withheld release may
     carry one closed `demo_exception_refusal` code; the demo event's
     private arguments are never caller-supplied.

  The run id is put in the changeset context
  (`:model_result_release_agent_run_id`) for the event's run correlation.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.CalibrationContext
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.DemoException.Basis
  alias SdrAgent.Agents.DemoException.Eligibility
  alias SdrAgent.Agents.Errors.DemoExceptionRefused
  alias SdrAgent.Agents.Errors.ReleaseConflict
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Binding
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @terminal [:completed, :failed, :unknown]
  @fingerprint [
    :disposition,
    :reason,
    :wire_witness_link_id,
    :evidence_sha256,
    :exception_policy_id
  ]
  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"
  @private [:demo_exception_policy_id, :demo_exception_basis_sha256, :demo_exception_label]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> static_rules()
    |> Ash.Changeset.before_action(&decide/1)
    |> Ash.Changeset.after_action(&check_replay/2)
  end

  defp static_rules(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    disposition = get.(:disposition)

    [
      pair_error(disposition, get.(:reason)),
      evidence_error(disposition, get.(:evidence_sha256)),
      link_error(disposition, get.(:wire_witness_link_id)),
      refusal_error(disposition, Ash.Changeset.get_argument(changeset, :demo_exception_refusal))
      | Enum.map(@private, &private_error(changeset, &1))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(changeset, fn {field, message}, acc -> invalid(acc, field, message) end)
  end

  # Missing or out-of-range values are reported by the attribute itself.
  defp pair_error(disposition, reason) when is_nil(disposition) or is_nil(reason), do: nil

  defp pair_error(disposition, reason) do
    unless ModelResultRelease.allowed_pair?(disposition, reason),
      do: {:reason, "#{inspect(reason)} is not a reason for #{inspect(disposition)}"}
  end

  defp evidence_error(:calibration, nil),
    do: {:evidence_sha256, "is required for a calibration latch"}

  defp evidence_error(disposition, evidence)
       when disposition in [:released, :withheld] and not is_nil(evidence),
       do: {:evidence_sha256, "is recorded only for a calibration latch"}

  defp evidence_error(_disposition, _evidence), do: nil

  defp link_error(:released, nil),
    do: {:wire_witness_link_id, "is required to release an output"}

  defp link_error(_disposition, _link), do: nil

  # C2* (ADR-0005 item 5): the refusal code only on a withheld release, and
  # only while the selector names the entry.
  defp refusal_error(_disposition, nil), do: nil

  defp refusal_error(disposition, _code) do
    unless disposition == :withheld and DemoException.selected?(),
      do:
        {:demo_exception_refusal,
         "is recorded only on a withheld release while the selector is on"}
  end

  # The demo event's private arguments are set by this change only.
  defp private_error(changeset, argument) do
    unless is_nil(Ash.Changeset.get_argument(changeset, argument)),
      do: {argument, "is set only by the release decision"}
  end

  defp decide(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    tenant_id = get.(:tenant_id)
    ids = {tenant_id, get.(:model_invocation_id), get.(:wire_witness_link_id)}

    with {:ok, mode} <- lock_mode(changeset.context, ids, get.(:disposition)),
         :ok <- check_gate_cause(changeset, mode),
         {:ok, invocation} <- fetch(ModelInvocation, get.(:model_invocation_id), tenant_id, mode),
         {:ok, link} <- fetch_link(get.(:wire_witness_link_id), tenant_id, mode) do
      changeset =
        Ash.Changeset.set_context(changeset, %{
          model_result_release_agent_run_id: invocation.agent_run_id
        })

      cond do
        # C2* (ADR-0005 item 6): only under the finalizer's verified context.
        get.(:disposition) == :demo_exception ->
          {:prelocked, registered} = mode
          changeset |> provenance(link) |> demo(registered, invocation, link)

        # The upsert returns the existing row; `check_replay/2` compares it.
        existing(invocation) == :exists ->
          provenance(changeset, link)

        # Every disposition with a validated link records the link's
        # evaluated projection and method (item 5, code review MF2).
        true ->
          changeset
          |> check_disposition(get.(:disposition), invocation, link)
          |> check_link(invocation, link)
          |> provenance(link)
      end
    else
      {:error, field, message} -> invalid(changeset, field, message)
    end
  end

  # Standalone decide locks its parents `FOR SHARE` before the head. Under a
  # verified prelocked context (contract (d)) the finalizer already holds
  # them, so no lock clause is requested; any other `:sdr_prelocked` value
  # is refused, never treated as standalone.
  defp lock_mode(%{sdr_prelocked: context}, {tenant_id, invocation_id, link_id}, disposition) do
    with {:ok, registered} <- Prelocked.verify(context),
         true <-
           {registered.tenant_id, registered.model_invocation_id, registered.wire_witness_link_id} ==
             {tenant_id, invocation_id, link_id},
         :ok <- check_receipt(registered),
         :ok <- check_finalizer(registered, disposition) do
      {:ok, {:prelocked, registered}}
    else
      _ -> {:error, :model_invocation_id, "the prelocked decision context is refused"}
    end
  end

  defp lock_mode(_context, _ids, :demo_exception),
    do:
      {:error, :model_invocation_id,
       "a demo exception is decided only by the result-gate finalizer"}

  defp lock_mode(_context, _ids, _disposition), do: {:ok, "FOR SHARE"}

  # C2* (ADR-0005 item 6): a `:demo_exception` decide needs the result-gate
  # finalizer's context with no receipt and its captured instant; no other
  # disposition is decided under such a context.
  defp check_finalizer(
         %Prelocked{finalizer: :result_gate, receipt_id: nil, decided_at: %DateTime{}},
         :demo_exception
       ),
       do: :ok

  defp check_finalizer(%Prelocked{finalizer: nil}, disposition)
       when disposition != :demo_exception,
       do: :ok

  defp check_finalizer(_registered, _disposition), do: :error

  # R0-07 slice C (G1/G2): `gate_cause_id` only for :withheld and only as the
  # verified Prelocked receipt; `gate_classification` only with a cause.
  defp check_gate_cause(changeset, mode) do
    cause = Ash.Changeset.get_argument(changeset, :gate_cause_id)
    classification = Ash.Changeset.get_argument(changeset, :gate_classification)
    disposition = Ash.Changeset.get_attribute(changeset, :disposition)

    cond do
      is_nil(cause) and is_nil(classification) -> :ok
      is_nil(cause) -> {:error, :gate_classification, "is recorded only with a gate cause"}
      disposition != :withheld -> {:error, :gate_cause_id, "is recorded only when withheld"}
      match?({:prelocked, %Prelocked{receipt_id: ^cause}}, mode) -> :ok
      true -> {:error, :gate_cause_id, "must be the finalizer's selected receipt"}
    end
  end

  # The receipt, when bound, is this invocation's reconciliation cause.
  defp check_receipt(%Prelocked{receipt_id: nil}), do: :ok

  defp check_receipt(%Prelocked{receipt_id: id} = registered) when is_binary(id) do
    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(registered.tenant_id))
    |> Ash.Query.filter(
      id == ^id and tenant_id == ^registered.tenant_id and class == :reconciliation_required and
        subject_resource == "SdrAgent.Agents.ModelInvocation" and
        subject_id == ^registered.model_invocation_id
    )
    |> Ash.exists?()
    |> if(do: :ok, else: :error)
  end

  defp check_receipt(_registered), do: :error

  # The link's evaluated projection and method, copied onto the release.
  defp provenance(changeset, %WireWitnessLink{} = link) do
    changeset
    |> Ash.Changeset.force_change_attribute(
      :projection_version,
      link.evidence["projection_version"]
    )
    |> Ash.Changeset.force_change_attribute(:method, link.method)
  end

  defp provenance(changeset, nil), do: changeset

  defp fetch(resource, id, tenant_id, mode) when is_binary(id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> then(&if(match?({:prelocked, _}, mode), do: &1, else: Ash.Query.lock(&1, mode)))
    |> Ash.read_one()
    |> case do
      {:ok, %^resource{} = row} -> {:ok, row}
      _ -> {:error, :model_invocation_id, "is not a model invocation of this tenant"}
    end
  end

  defp fetch(_resource, _id, _tenant_id, _mode),
    do: {:error, :model_invocation_id, "is not a model invocation of this tenant"}

  defp fetch_link(nil, _tenant_id, _mode), do: {:ok, nil}

  defp fetch_link(id, tenant_id, mode) do
    case fetch(WireWitnessLink, id, tenant_id, mode) do
      {:ok, link} ->
        {:ok, link}

      {:error, _field, _message} ->
        {:error, :wire_witness_link_id, "is not a link of this tenant"}
    end
  end

  defp existing(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.exists?()
    |> if(do: :exists, else: :none)
  end

  defp check_disposition(changeset, disposition, invocation, link)
       when disposition in [:released, :withheld] do
    cond do
      not gated?(invocation) ->
        invalid(
          changeset,
          :model_invocation_id,
          "must be a generation-2 ClaudeCLI invocation"
        )

      invocation.status != :completed ->
        invalid(changeset, :model_invocation_id, "must be completed")

      proof?(invocation) ->
        invalid(changeset, :model_invocation_id, "is a calibration call; it is never released")

      disposition == :released ->
        check_release(changeset, invocation, link)

      true ->
        changeset
    end
  end

  defp check_disposition(changeset, :calibration, invocation, _link) do
    cond do
      CalibrationContext.scope(changeset.context) != {invocation.profile_id, invocation.id} ->
        invalid(
          changeset,
          :disposition,
          "a calibration latch needs the calibration context of this invocation"
        )

      not gated?(invocation) or invocation.status not in @terminal ->
        invalid(
          changeset,
          :model_invocation_id,
          "must be a terminal generation-2 ClaudeCLI invocation"
        )

      not proof?(invocation) ->
        invalid(changeset, :model_invocation_id, "must be an invocation of a proof run")

      true ->
        changeset
    end
  end

  defp check_disposition(changeset, _disposition, _invocation, _link), do: changeset

  defp check_release(
         changeset,
         %{validation_status: :valid} = invocation,
         %WireWitnessLink{} = link
       ) do
    evidence = link.evidence
    projection = evidence["projection_version"]

    cond do
      link.link_status != :reconciled or evidence["classification"] != "primary" ->
        invalid(changeset, :wire_witness_link_id, "must be a reconciled primary link")

      not same_identity?(invocation, evidence) ->
        invalid(changeset, :wire_witness_link_id, "evidence must name this invocation")

      not Witness.allowlisted?(invocation, projection, link.method) ->
        invalid(changeset, :wire_witness_link_id, "its exact tuple is not on the allowlist")

      Witness.status(current_links(invocation)) != :reconciled ->
        invalid(changeset, :wire_witness_link_id, "the invocation is not reconciled")

      true ->
        changeset
    end
  end

  defp check_release(changeset, %{validation_status: :valid}, _link),
    do: invalid(changeset, :wire_witness_link_id, "is required to release an output")

  defp check_release(changeset, _invocation, _link),
    do: invalid(changeset, :model_invocation_id, "must have a valid output to be released")

  # Any given link must be this invocation's current link (no successor).
  defp check_link(changeset, _invocation, nil), do: changeset

  defp check_link(changeset, invocation, link) do
    cond do
      link.model_invocation_id != invocation.id ->
        invalid(changeset, :wire_witness_link_id, "must be a link of this invocation")

      not Enum.any?(current_links(invocation), &(&1.id == link.id)) ->
        invalid(changeset, :wire_witness_link_id, "has been superseded")

      true ->
        changeset
    end
  end

  defp current_links(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        not exists(successors, true)
    )
    |> Ash.read!()
  end

  defp same_identity?(invocation, evidence) do
    WitnessEvidence.check_identity(invocation, evidence) == :ok and
      map_size(WitnessEvidence.identity(invocation)) == 2 and
      evidence["cli_version"] == invocation.provider_version and
      evidence["app_request_sha256"] == hex(invocation.request_sha256) and
      evidence["app_response_sha256"] == hex(invocation.response_sha256)
  end

  defp gated?(invocation),
    do: invocation.ledger_generation == 2 and invocation.provider == :claude_cli

  defp proof?(invocation) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(id == ^invocation.agent_run_id and tenant_id == ^invocation.tenant_id)
    |> Ash.read_one!()
    |> case do
      %AgentRun{usage_origin: :proof} -> true
      _ -> false
    end
  end

  ## C2* demo exception (S3 plan r2 §6, §6.1; ADR-0005 C2* items 4, 6-8)

  # Only under the result-gate finalizer's verified context, whose bindings
  # are the current locked state: the sorted current link ids, the
  # invocation's funding grant and allocation, and the active snapshot's
  # generation. The instant is the context's own (`Prelocked.run/2`).
  defp demo(changeset, registered, invocation, link) do
    facts = Eligibility.load(invocation, link && link.id)

    if demo_bindings?(registered, facts) do
      case existing_row(invocation) do
        nil -> demo_new(changeset, registered, facts)
        row -> demo_replay(changeset, row, facts)
      end
    else
      invalid(changeset, :model_invocation_id, "the prelocked decision context is refused")
    end
  end

  defp demo_bindings?(registered, %{invocation: invocation, links: links}) do
    generation =
      case DemoException.attestation() do
        {:ok, %{generation: generation}} -> generation
        _none -> nil
      end

    registered.current_link_ids == Enum.map(Eligibility.current(links), & &1.id) and
      registered.grant_id == invocation.grant_id and
      registered.allocation_id == invocation.allocation_id and
      not is_nil(generation) and registered.snapshot_generation == generation
  end

  # A new decision: E1-E6 at the context's instant, authoritative.
  defp demo_new(changeset, registered, facts) do
    t = registered.decided_at

    case Eligibility.evaluate(facts, t) do
      {:ok, authority} ->
        demo_record(changeset, facts, authority, t)

      {:refused, code} ->
        Ash.Changeset.add_error(
          changeset,
          DemoExceptionRefused.exception(model_invocation_id: facts.invocation.id, code: code)
        )
    end
  end

  defp demo_record(changeset, facts, authority, t) do
    entry = DemoException.entry()
    entry_sha256 = DemoException.entry_sha256()

    basis =
      Basis.build(%{
        entry_sha256: entry_sha256,
        acceptance_ref: entry.acceptance_ref,
        binding_sha256: authority.attestation.environment_binding_sha256,
        authorization_id: authority.authorization.id,
        authorization_sha256: authority.authorization.entry_sha256,
        starts_at: authority.starts_at,
        effective_expires_at: authority.expires_at,
        decided_at: t,
        invocation: facts.invocation,
        run: facts.run,
        link: facts.primary,
        current_link_ids: Enum.map(Eligibility.current(facts.links), & &1.id),
        v3_allowlisted: true,
        v4_allowlisted: false
      })

    expected = %{
      decided_at: t,
      exception_expires_at: authority.expires_at,
      entry_sha256: entry_sha256,
      acceptance_ref: entry.acceptance_ref
    }

    case Basis.validate(basis, expected) do
      :ok ->
        digest = Basis.sha256_hex(basis)

        changeset
        |> Ash.Changeset.force_change_attributes(%{
          decided_at: t,
          exception_policy_id: DemoException.policy_id(),
          exception_expires_at: authority.expires_at,
          exception_basis: basis,
          exception_basis_sha256: digest
        })
        |> Ash.Changeset.set_argument(:demo_exception_policy_id, DemoException.policy_id())
        |> Ash.Changeset.set_argument(:demo_exception_basis_sha256, digest)
        |> Ash.Changeset.set_argument(:demo_exception_label, DemoException.label())

      {:error, reason} ->
        invalid(changeset, :model_invocation_id, "the demo-exception basis is refused: #{reason}")
    end
  end

  # §6.1 replay: the STORED basis is validated against its own recorded
  # policy and window (never today's entry, time, selector or grant status),
  # its L sections are re-derived from the locked rows, and the digest must
  # be the row's. An identical replay proposes the stored row (so its CHECKs
  # hold) and the upsert returns it with no event; any difference, or an
  # existing release of another disposition, is a `ReleaseConflict`.
  defp demo_replay(changeset, %ModelResultRelease{disposition: :demo_exception} = row, facts) do
    if same_basis?(row, facts) do
      Ash.Changeset.force_change_attributes(changeset, %{
        decided_at: row.decided_at,
        exception_policy_id: row.exception_policy_id,
        exception_expires_at: row.exception_expires_at,
        exception_basis: row.exception_basis,
        exception_basis_sha256: row.exception_basis_sha256
      })
    else
      conflict(changeset, row)
    end
  end

  defp demo_replay(changeset, row, _facts), do: conflict(changeset, row)

  defp same_basis?(row, %{primary: %WireWitnessLink{} = primary} = facts) do
    stored = row.exception_basis
    policy = if is_map(stored), do: stored["policy"], else: nil

    with %{"entry_sha256" => entry_sha256, "acceptance_ref" => acceptance_ref}
         when is_binary(entry_sha256) and is_binary(acceptance_ref) <- policy,
         :ok <-
           Basis.validate(stored, %{
             decided_at: row.decided_at,
             exception_expires_at: row.exception_expires_at,
             entry_sha256: entry_sha256,
             acceptance_ref: acceptance_ref
           }) do
      derived =
        Basis.evidence_sections(stored, %{
          invocation: facts.invocation,
          run: facts.run,
          link: primary,
          current_link_ids: Enum.map(Eligibility.current(facts.links), & &1.id),
          v3_allowlisted: Witness.allowlisted?(facts.invocation, @v3, :propagated_id),
          v4_allowlisted: Witness.allowlisted?(facts.invocation, @v4, :propagated_id)
        })

      Basis.sha256_hex(derived) == row.exception_basis_sha256
    else
      _ -> false
    end
  end

  defp same_basis?(_row, _facts), do: false

  defp conflict(changeset, row) do
    cause =
      case Binding.bound_cause(row) do
        {:ok, cause} -> cause
        {:error, _} -> nil
      end

    Ash.Changeset.add_error(
      changeset,
      ReleaseConflict.exception(
        model_invocation_id: row.model_invocation_id,
        existing_id: row.id,
        existing_cause_id: cause
      )
    )
  end

  defp existing_row(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.read_one!()
  end

  defp check_replay(changeset, record) do
    if record.id == Ash.Changeset.get_attribute(changeset, :id),
      do: {:ok, record},
      else: replay(changeset, record, Binding.bound_cause(record))
  end

  # Round-7 obligation 1: an unavailable original binding is refused, never
  # read as "no cause".
  defp replay(_changeset, record, {:error, :binding_unavailable}) do
    {:error,
     Ash.Error.Changes.InvalidArgument.exception(
       field: :gate_cause_id,
       message: "the existing release #{record.id} has no readable original binding"
     )}
  end

  defp replay(changeset, record, {:ok, bound}) do
    if Map.take(record, @fingerprint) == fingerprint(changeset) and
         bound == Ash.Changeset.get_argument(changeset, :gate_cause_id) do
      {:ok, Ash.Resource.put_metadata(record, :sdr_replayed, true)}
    else
      {:error,
       ReleaseConflict.exception(
         model_invocation_id: record.model_invocation_id,
         existing_id: record.id,
         existing_cause_id: bound
       )}
    end
  end

  defp fingerprint(changeset),
    do: Map.new(@fingerprint, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp invalid(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
