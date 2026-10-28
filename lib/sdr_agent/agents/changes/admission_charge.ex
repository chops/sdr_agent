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

  D-237 partition (interfaces r6 IF-4; amendment item 4): a ClaudeCLI charge
  is made here only in ordinary runtime and only without a
  `prototype_authority`. In prototype runtime the prototype gate
  (`SdrAgent.Prototype.Admission`) admits no charge without the authority it
  records, and no reservation records one yet, so every prototype-runtime
  ClaudeCLI charge is refused (Forbidden): it never falls back to an
  ordinary grant.
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Prototype

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
        if partitioned?(charge),
          do: charged(changeset, charge, {grant_id, allocation_id, at}),
          else: Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {:claude_cli, _missing} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {_provider, nil} ->
        changeset

      {_provider, _charge} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end
  end

  # D-237 IF-4: ordinary runtime only, and no prototype authority.
  defp partitioned?(charge),
    do: Prototype.runtime() == :ordinary and is_nil(Map.get(charge, :prototype_authority))

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
