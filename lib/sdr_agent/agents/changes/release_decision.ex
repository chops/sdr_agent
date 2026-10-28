defmodule SdrAgent.Agents.Changes.ReleaseDecision do
  @moduledoc """
  `SdrAgent.Agents.ModelResultRelease` `:decide` rules (R0-07 entity PASS at
  1da747a), checked inside the action transaction:

    1. Statically: an allowed disposition/reason pair
       (`ModelResultRelease.allowed_pair?/2`); `evidence_sha256` present for
       `:calibration` and absent otherwise; a link for `:released`.
       The D-237 runtime partition (interfaces r6 IF-4) follows the context
       check, before any read: in prototype runtime `:released` is refused;
       `:released_unverified` and `:prototype_authority_refused` are refused
       outside it; `:released_unverified` is refused outside the prototype
       gate's own Prelocked context; a caller-built `basis` or
       `basis_sha256` is refused on every other decision;
       `prototype_authority_refused` carries exactly one
       `prototype_refusal` code (refused on any other reason); the
       `:reconciled` classification only with the code
       `witness_mode_mismatch`.
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
       the upsert returns that row and step 4 compares it. D-237 b2c β: a
       `:released_unverified` request on an existing `released_unverified`
       release is first compared with the ORIGINAL event's arguments
       (`SdrAgent.Prototype.ReleasedScope.original_basis/2`,
       `SdrAgent.Prototype.Basis.compare_existing/2`): identical is a
       replay, a valid different basis a `ReleaseConflict`, anything
       invalid is refused on `:basis` ("must be a valid d237-basis/1 with
       its digest"); never the current grant or window. β stage P (not
       landable): that original is checked for its event identity only, not
       yet historically (B1).
    3. Per disposition (any validated link's projection and method are
       copied onto the release, whatever the disposition):
       * D-237 b2c α, a NEW `:released_unverified` in the prototype gate's
         own context: its instant is the context's bound `decided_at` (the
         gate's one under-head clock read) or else this action's own, set
         on the row; the supplied `basis` and `basis_sha256` must pass
         `SdrAgent.Prototype.Basis.verify_new/2` against the basis rebuilt
         from the boot snapshot, the compiled entries, the invocation, its
         run, its charged grant and that instant, else it is refused on
         `:basis` ("must be a valid d237-basis/1 with its digest"); a read
         error keeps its identity;
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

  The run id is put in the changeset context
  (`:model_result_release_agent_run_id`) for the event's run correlation.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.CalibrationContext
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
  @fingerprint [:disposition, :reason, :wire_witness_link_id, :evidence_sha256]
  # D-237: prototype runtime exists only in builds with the prototype
  # authority (config/dev.exs and config/test.exs).
  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

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
      link_error(disposition, get.(:wire_witness_link_id))
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

  defp decide(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    tenant_id = get.(:tenant_id)
    ids = {tenant_id, get.(:model_invocation_id), get.(:wire_witness_link_id)}

    with {:ok, mode} <- lock_mode(changeset.context, ids),
         :ok <- check_gate_cause(changeset, mode),
         :ok <- prototype_rules(changeset, mode),
         {:ok, invocation} <- fetch(ModelInvocation, get.(:model_invocation_id), tenant_id, mode),
         {:ok, link} <- fetch_link(get.(:wire_witness_link_id), tenant_id, mode) do
      changeset =
        Ash.Changeset.set_context(changeset, %{
          model_result_release_agent_run_id: invocation.agent_run_id
        })

      case existing(invocation) do
        # The upsert returns the existing row; `check_replay/2` compares it.
        # D-237 b2c β: a released_unverified request on an existing
        # released_unverified release is first compared with its ORIGINAL
        # event (`unverified_existing/2`).
        :exists ->
          changeset
          |> unverified_existing(invocation)
          |> provenance(link)

        # Every disposition with a validated link records the link's
        # evaluated projection and method (item 5, code review MF2).
        # D-237 α: a NEW released_unverified decision is checked against the
        # basis rebuilt from the locked facts first.
        :none ->
          changeset
          |> unverified_new(invocation, mode)
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
  defp lock_mode(%{sdr_prelocked: context}, {tenant_id, invocation_id, link_id}) do
    with {:ok, registered} <- Prelocked.verify(context),
         true <-
           {registered.tenant_id, registered.model_invocation_id, registered.wire_witness_link_id} ==
             {tenant_id, invocation_id, link_id},
         :ok <- check_receipt(registered) do
      {:ok, {:prelocked, registered}}
    else
      _ -> {:error, :model_invocation_id, "the prelocked decision context is refused"}
    end
  end

  defp lock_mode(_context, _ids), do: {:ok, "FOR SHARE"}

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

  ## D-237 runtime partition (interfaces r6 IF-4; amendment item 5)

  # In prototype runtime the ordinary :released decision is unreachable;
  # the prototype values are decided only in prototype runtime. A
  # released_unverified decision is refused outside the prototype gate's own
  # Prelocked context (finalizer :prototype_gate); inside it, its closed
  # basis (d237-basis/1) is checked after the existing-release read. A
  # prototype_authority_refused decision carries exactly one closed code,
  # and only it may record the :reconciled classification, with the code
  # witness_mode_mismatch (Codex 2c9450b7 ruling 3b).
  defp prototype_rules(changeset, mode) do
    disposition = Ash.Changeset.get_attribute(changeset, :disposition)
    reason = Ash.Changeset.get_attribute(changeset, :reason)
    code = Ash.Changeset.get_argument(changeset, :prototype_refusal)
    classification = Ash.Changeset.get_argument(changeset, :gate_classification)

    with :ok <- runtime_partition(disposition, reason),
         :ok <- unverified(disposition, mode),
         :ok <- no_basis(disposition, changeset),
         :ok <- refusal_code(reason, code) do
      reconciled(classification, {reason, code})
    end
  end

  # D-237 RED-b2c deny-only (Codex 3122b0d4): a caller-built basis is never
  # recorded on any other decision. Value-free: the refusal names the field
  # only. (A released_unverified decision is still refused above.)
  defp no_basis(disposition, changeset) do
    supplied? =
      not is_nil(Ash.Changeset.get_argument(changeset, :basis)) or
        not is_nil(Ash.Changeset.get_argument(changeset, :basis_sha256))

    if supplied? and disposition != :released_unverified,
      do: {:error, :basis, "is recorded only for a released_unverified decision"},
      else: :ok
  end

  if @prototype_compiled do
    @basis_refused "must be a valid d237-basis/1 with its digest"

    # D-237 α (correction r2 N1/N2; boundary delta a7bbcac3): a NEW
    # released_unverified decision in the prototype gate's own context. Its
    # instant is the context's bound `decided_at` (the gate's one under-head
    # Clock read) or, without one, this action's own instant, forced onto the
    # row so that the row and the basis agree. The supplied basis is only
    # compared with the one rebuilt from the facts; never trusted.
    defp unverified_new(changeset, invocation, {:prelocked, %Prelocked{} = context}) do
      if Ash.Changeset.get_attribute(changeset, :disposition) == :released_unverified and
           context.finalizer == :prototype_gate,
         do: check_basis(changeset, invocation, context),
         else: changeset
    end

    defp unverified_new(changeset, _invocation, _mode), do: changeset

    # D-237 b2c β (packet r1 section 3.5, delta r2 section 1): a
    # released_unverified request on an EXISTING release (reached only in
    # the gate's own context, `unverified/2`). An existing release that is
    # not released_unverified keeps `check_replay/2`'s ReleaseConflict. For
    # a released_unverified one the request is compared with the ORIGINAL
    # event's arguments (`ReleasedScope.original_basis/2`), never re-derived
    # from the current grant or window and never time-forced: identical is
    # a replay (the upsert returns the row, no event), a valid different
    # basis is a ReleaseConflict, anything invalid is refused on :basis; a
    # read error keeps its identity. β stage P: the original is checked for
    # its event identity only, not yet historically (B1).
    defp unverified_existing(changeset, invocation) do
      if Ash.Changeset.get_attribute(changeset, :disposition) == :released_unverified,
        do: compare_original(changeset, invocation),
        else: changeset
    end

    defp compare_original(changeset, invocation) do
      requested = %{
        basis: Ash.Changeset.get_argument(changeset, :basis),
        basis_sha256: Ash.Changeset.get_argument(changeset, :basis_sha256)
      }

      case existing_release(invocation) do
        {:ok, %ModelResultRelease{disposition: :released_unverified} = release} ->
          release
          |> SdrAgent.Prototype.ReleasedScope.original_basis(invocation)
          |> compared(requested, release, changeset)

        {:ok, %ModelResultRelease{}} ->
          changeset

        {:ok, nil} ->
          invalid(changeset, :basis, @basis_refused)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end

    defp compared({:ok, original}, requested, release, changeset) do
      case SdrAgent.Prototype.Basis.compare_existing(requested, original) do
        :replay ->
          changeset

        :conflict ->
          Ash.Changeset.add_error(
            changeset,
            ReleaseConflict.exception(
              model_invocation_id: release.model_invocation_id,
              existing_id: release.id,
              existing_cause_id: nil
            )
          )

        {:error, :basis_invalid} ->
          invalid(changeset, :basis, @basis_refused)
      end
    end

    defp compared({:error, :basis_invalid}, _requested, _release, changeset),
      do: invalid(changeset, :basis, @basis_refused)

    defp compared({:error, error}, _requested, _release, changeset),
      do: Ash.Changeset.add_error(changeset, error)

    # A plain read (no lock clause) of the invocation's existing release.
    defp existing_release(invocation) do
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
      )
      |> Ash.read_one()
    end

    defp check_basis(changeset, invocation, context) do
      at = decision_instant(changeset, context)
      changeset = Ash.Changeset.force_change_attribute(changeset, :decided_at, at)

      supplied = %{
        basis: Ash.Changeset.get_argument(changeset, :basis),
        basis_sha256: Ash.Changeset.get_argument(changeset, :basis_sha256)
      }

      with {:ok, facts} <- basis_facts(invocation, at),
           :ok <- SdrAgent.Prototype.Basis.verify_new(supplied, facts) do
        changeset
      else
        {:error, :basis_invalid} ->
          invalid(changeset, :basis, @basis_refused)

        {:error, :not_prototype_runtime} ->
          invalid(changeset, :disposition, "is decided only in prototype runtime")

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end

    defp decision_instant(_changeset, %Prelocked{decided_at: %DateTime{} = bound}), do: bound

    defp decision_instant(changeset, _context),
      do: Ash.Changeset.get_attribute(changeset, :decided_at) || SdrAgent.Clock.utc_now()

    # The server's facts at `at`: the boot snapshot, the compiled entries,
    # the stored invocation, its run and its charged grant (plain reads with
    # no lock clause: the gate's own context holds the locks).
    defp basis_facts(invocation, at) do
      with {:ok, snapshot} <- SdrAgent.Prototype.binding(),
           {:ok, entry} <- SdrAgent.Prototype.policy_entry(),
           {:ok, funding} <- SdrAgent.Prototype.funding_entry(),
           {:ok, run} <- plain(AgentRun, invocation.agent_run_id, invocation.tenant_id),
           {:ok, grant} <-
             plain(SdrAgent.Agents.ModelCallGrant, invocation.grant_id, invocation.tenant_id) do
        {:ok,
         %{
           snapshot: snapshot,
           entry: entry,
           funding: funding,
           invocation: invocation,
           run: run,
           grant: grant,
           decided_at: at
         }}
      end
    end

    # An absent row is a named absence (no basis can be rebuilt); a read
    # error keeps its identity.
    defp plain(resource, id, tenant_id) when is_binary(id) do
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.read_one()
      |> case do
        {:ok, nil} -> {:error, :basis_invalid}
        result -> result
      end
    end

    defp plain(_resource, _id, _tenant_id), do: {:error, :basis_invalid}
  else
    # The production build has no prototype runtime: nothing to check here.
    defp unverified_new(changeset, _invocation, _mode), do: changeset
    defp unverified_existing(changeset, _invocation), do: changeset
  end

  if @prototype_compiled do
    defp runtime_partition(disposition, reason) do
      case SdrAgent.Prototype.runtime() do
        :prototype -> prototype_partition(disposition)
        _ordinary -> ordinary_partition(disposition, reason)
      end
    end

    defp prototype_partition(:released),
      do: {:error, :disposition, "the ordinary release is unreachable in prototype runtime"}

    defp prototype_partition(_disposition), do: :ok
  else
    # The production build has no prototype runtime.
    defp runtime_partition(disposition, reason), do: ordinary_partition(disposition, reason)
  end

  defp ordinary_partition(disposition, reason)
       when disposition == :released_unverified or reason == :prototype_authority_refused,
       do: {:error, :disposition, "is decided only in prototype runtime"}

  defp ordinary_partition(_disposition, _reason), do: :ok

  # Allowed only in the prototype gate's own context; its basis is checked
  # after the existing-release read (`unverified_new/3`, `unverified_existing/1`).
  defp unverified(:released_unverified, {:prelocked, %Prelocked{finalizer: :prototype_gate}}),
    do: :ok

  defp unverified(:released_unverified, _mode),
    do: {:error, :disposition, "is decided only by the prototype gate's own context"}

  defp unverified(_disposition, _mode), do: :ok

  defp refusal_code(:prototype_authority_refused, code) do
    if code in ModelResultRelease.prototype_codes(),
      do: :ok,
      else: {:error, :prototype_refusal, "must be one prototype refusal code"}
  end

  defp refusal_code(_reason, nil), do: :ok

  defp refusal_code(_reason, _code),
    do: {:error, :prototype_refusal, "is recorded only for a prototype refusal"}

  defp reconciled(:reconciled, {:prototype_authority_refused, :witness_mode_mismatch}), do: :ok

  defp reconciled(:reconciled, _refusal),
    do:
      {:error, :gate_classification,
       "reconciled is recorded only by the prototype gate's witness_mode_mismatch refusal"}

  defp reconciled(_classification, _refusal), do: :ok

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
