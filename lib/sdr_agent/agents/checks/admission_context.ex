defmodule SdrAgent.Agents.Checks.AdmissionContext do
  @moduledoc """
  Marker and charge for `ModelInvocation :reserve` (C9): a real-model
  (ClaudeCLI) reservation is created only by
  `SdrAgent.Agents.reserve_model_invocation/3`, which sets this context —
  the admitted `%{grant_id:, allocation_id:, reserved_at:}` (the admission
  instant, read after every reservation lock is held) — only after
  `SdrAgent.Agents.Admission.admit/4` selected and checked the allocation
  inside the reservation transaction. No other code sets it, so a direct
  `:reserve` of a ClaudeCLI call is refused
  (`SdrAgent.Agents.Changes.AdmissionCharge`; same pattern as
  `SdrAgent.Agents.Checks.RetryContext` and `GrantContext`).
  """

  @marker :sdr_agent_model_admission

  @doc """
  The context map carrying an admitted charge, with the recorded
  `calibration_tuple` of an authorized calibration call (R0-07 slice B,
  row B4; nil otherwise) and the console's `calibration_claim` recorded
  next to it (R0-07 E4c-2; nil otherwise).
  """
  def context(
        %{grant_id: grant_id, allocation_id: allocation_id, reserved_at: %DateTime{} = at} =
          charge
      )
      when is_binary(grant_id) and is_binary(allocation_id) do
    %{
      @marker => %{
        grant_id: grant_id,
        allocation_id: allocation_id,
        reserved_at: at,
        calibration_tuple: Map.get(charge, :calibration_tuple),
        calibration_claim: Map.get(charge, :calibration_claim)
      }
    }
  end

  @doc "The admitted charge in a changeset context, or `nil`."
  def charge(%{
        @marker =>
          %{grant_id: grant_id, allocation_id: allocation_id, reserved_at: %DateTime{}} =
            charge
      })
      when is_binary(grant_id) and is_binary(allocation_id),
      do: charge |> Map.put_new(:calibration_tuple, nil) |> Map.put_new(:calibration_claim, nil)

  def charge(%{@marker => _malformed}), do: :malformed
  def charge(_context), do: nil
end
