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
  claim) follows the same rule.
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden
  alias SdrAgent.Agents.Checks.AdmissionContext

  @impl true
  def change(changeset, _opts, _context) do
    provider = Ash.Changeset.get_attribute(changeset, :provider)

    supplied? =
      Enum.any?([:calibration_tuple, :calibration_claim], fn argument ->
        not is_nil(Ash.Changeset.get_argument(changeset, argument))
      end)

    case {provider, AdmissionContext.charge(changeset.context)} do
      {_provider, _charge} when supplied? ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {:claude_cli, %{grant_id: grant_id, allocation_id: allocation_id, reserved_at: at} = charge} ->
        changeset
        |> Ash.Changeset.force_change_attributes(%{
          grant_id: grant_id,
          allocation_id: allocation_id,
          reserved_at: at
        })
        |> record_tuple(charge.calibration_tuple)
        |> record_claim(Map.get(charge, :calibration_claim))

      {:claude_cli, _missing} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {_provider, nil} ->
        changeset

      {_provider, _charge} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end
  end

  defp record_tuple(changeset, nil), do: changeset

  defp record_tuple(changeset, tuple),
    do: Ash.Changeset.force_set_argument(changeset, :calibration_tuple, tuple)

  defp record_claim(changeset, nil), do: changeset

  defp record_claim(changeset, claim),
    do: Ash.Changeset.force_set_argument(changeset, :calibration_claim, claim)
end
