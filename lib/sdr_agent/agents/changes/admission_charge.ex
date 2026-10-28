defmodule SdrAgent.Agents.Changes.AdmissionCharge do
  @moduledoc """
  `ModelInvocation :reserve` change (C9): the grant and allocation a call
  is charged to come only from the admission context
  (`SdrAgent.Agents.Checks.AdmissionContext`), never from inputs (the
  action accepts neither). On the cast `provider`:

    * `:claude_cli` — refused (Forbidden) unless the context carries an
      admitted charge, which is then force-set on the row together with its
      admission instant as `reserved_at` (never the attribute default);
    * any other provider — refused (Forbidden) if a charge is present.

  R0-07 slice B (row B4): the `calibration_tuple` argument — recorded on
  the `model.invocation.reserved` event as the authority launch admission
  re-derives — is set only from the admitted charge of an authorized
  calibration call; a caller-supplied value is refused (Forbidden). The
  `calibration_claim` argument (R0-07 E4c-2, the console's launch-record
  claim) follows the same rule. So does the D-237 `prototype_authority`
  argument (interfaces r6 IF-4; Codex 339c8e8d ruling 3): a caller-supplied
  non-nil value is refused (Forbidden), never ignored, for every provider and
  runtime, before the insert, so the reservation transaction (run counter,
  request Payload, invocation and event) rolls back.

  D-237 partition (interfaces r6 IF-4; amendment item 4; mechanism note r3
  section B): in ordinary runtime a ClaudeCLI charge carries no
  `prototype_authority` and no registration. In prototype runtime it is made
  only under the registration `Admission.admit/5` returned for it: at build
  time (which also serves `Ash.can?/2`) the registration is verified
  read-only against the reservation (run, provider, profile, purpose,
  charge, instant); immediately before the insert, after authorization, a
  `before_action` verifies it against the ACTUAL changeset (tenant
  included) and consumes it, once, then records the authority it was
  registered with. A missing, forged, copied, consumed, stale, cross-process
  or rolled-back registration, or one for another reservation, is
  Forbidden: a prototype call never falls back to an ordinary grant. The
  production build has the ordinary rule only.
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden
  alias SdrAgent.Agents.Checks.AdmissionContext

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  # Arguments a caller may never supply (each is set only from an admitted
  # charge): any non-nil value is refused, for every provider and runtime.
  @charge_arguments [
    :calibration_tuple,
    :calibration_claim,
    :calibration_binding,
    :prototype_authority
  ]

  @impl true
  def change(changeset, _opts, _context) do
    provider = Ash.Changeset.get_attribute(changeset, :provider)

    supplied? =
      Enum.any?(@charge_arguments, fn argument ->
        not is_nil(Ash.Changeset.get_argument(changeset, argument))
      end)

    case {provider, AdmissionContext.charge(changeset.context)} do
      {_provider, _charge} when supplied? ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {:claude_cli, %{grant_id: grant_id, allocation_id: allocation_id, reserved_at: at} = charge} ->
        runtime_charge(changeset, charge, {grant_id, allocation_id, at})

      {:claude_cli, _missing} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {_provider, nil} ->
        changeset

      {_provider, _charge} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end
  end

  ## D-237 partition

  if @prototype_compiled do
    alias SdrAgent.Agents.Checks.AdmissionContext.Registration
    alias SdrAgent.Prototype.Admission, as: PrototypeAdmission

    @build_facts [:agent_run_id, :provider, :profile_id, :purpose]
    @insert_facts [:tenant_id | @build_facts] ++ [:grant_id, :allocation_id, :reserved_at]

    defp runtime_charge(changeset, charge, ids) do
      case {SdrAgent.Prototype.runtime(), Map.get(charge, :registration),
            Map.get(charge, :prototype_authority)} do
        {:ordinary, nil, nil} ->
          charged(changeset, charge, ids)

        {:prototype, %Registration{} = registration, _context_authority} ->
          if match?(
               {:ok, _},
               PrototypeAdmission.verify(registration, build_facts(changeset, ids))
             ),
             do:
               changeset
               |> charged(charge, ids)
               |> Ash.Changeset.before_action(&consume(&1, registration)),
             else: forbidden(changeset)

        _other ->
          forbidden(changeset)
      end
    end

    # Read-only verification at build time (nothing is consumed): the
    # registration's own entry and these facts (the reservation's run,
    # provider, profile, purpose and the charge) are compared before any
    # SQL, so a malformed or another process's registration is refused
    # without a query; only then is the transaction state read.
    defp build_facts(changeset, {grant_id, allocation_id, at}) do
      changeset
      |> attributes(@build_facts)
      |> Map.merge(%{grant_id: grant_id, allocation_id: allocation_id, reserved_at: at})
    end

    # Immediately before the insert, after authorization: the ACTUAL
    # changeset, then the one consumption and the registered authority.
    defp consume(changeset, registration) do
      case PrototypeAdmission.consume(registration, attributes(changeset, @insert_facts)) do
        {:ok, authority} ->
          Ash.Changeset.force_set_argument(changeset, :prototype_authority, authority)

        :error ->
          forbidden(changeset)
      end
    end

    defp attributes(changeset, keys),
      do: Map.new(keys, &{&1, Ash.Changeset.get_attribute(changeset, &1)})
  else
    # The production build has no prototype runtime: the ordinary rule only.
    defp runtime_charge(changeset, charge, ids) do
      if is_nil(Map.get(charge, :registration)) and is_nil(Map.get(charge, :prototype_authority)),
        do: charged(changeset, charge, ids),
        else: forbidden(changeset)
    end
  end

  defp forbidden(changeset), do: Ash.Changeset.add_error(changeset, Forbidden.exception([]))

  defp charged(changeset, charge, {grant_id, allocation_id, at}) do
    changeset
    |> Ash.Changeset.force_change_attributes(%{
      grant_id: grant_id,
      allocation_id: allocation_id,
      reserved_at: at
    })
    |> record_tuple(charge.calibration_tuple)
    |> record_claim(Map.get(charge, :calibration_claim))
    |> record_binding(Map.get(charge, :calibration_binding))
  end

  defp record_tuple(changeset, nil), do: changeset

  defp record_tuple(changeset, tuple),
    do: Ash.Changeset.force_set_argument(changeset, :calibration_tuple, tuple)

  defp record_binding(changeset, nil), do: changeset

  defp record_binding(changeset, binding),
    do: Ash.Changeset.force_set_argument(changeset, :calibration_binding, binding)

  defp record_claim(changeset, nil), do: changeset

  defp record_claim(changeset, claim),
    do: Ash.Changeset.force_set_argument(changeset, :calibration_claim, claim)
end
