defmodule SdrAgent.Agents.Checks.CalibrationAdmission do
  @moduledoc """
  The calibration admission authority (R0-07 slice B, row B4; entity PASS
  at 3600fcf): a private marker `{profile_id, entry}` passed to
  `SdrAgent.Agents.reserve_model_invocation/3` as its `calibration:` option.
  It is distinct from `SdrAgent.Agents.Checks.CalibrationContext`, which
  scopes the `:calibration` latch and read of one invocation and is never
  an admission input (contract (c)).

  It exists only in test-seam builds (`config :sdr_agent,
  :claude_cli_test_seams, true`): `context/2`, the only builder, is
  compiled only there, and `scope/1` answers nil in every other build even
  for a forged marker. Slice D's reviewed harness is its only non-test
  caller. The marker authorizes nothing by itself: admission
  (`SdrAgent.Agents.Admission.Gate`) accepts it only for a `:proof` run,
  with an exact six-key entry (`Witness.exact_overrides/1`) of the call's
  own reviewed profile that promotes the call's runtime identity. A `:proof`
  origin or a test build alone grants nothing.
  """

  alias SdrAgent.AI.ModelProfiles

  @marker :sdr_calibration_admission
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @doc """
  The `{profile_id, entry}` the marker `term` names, or nil when there is
  none (always nil outside test-seam builds). The entry is returned as
  given; admission validates it.
  """
  def scope(term), do: if(@test_seams, do: marked(term))

  defp marked(%{@marker => %{profile_id: profile_id, entry: entry}}) when is_atom(profile_id) do
    if ModelProfiles.real?(profile_id), do: {profile_id, entry}
  end

  defp marked(_term), do: nil

  if @test_seams do
    @doc """
    Test-seam builds only: the calibration admission marker for one
    calibration call of the reviewed real profile `profile_id` under the
    candidate `entry`. Raises `ArgumentError` for anything but a real
    profile id.
    """
    def context(profile_id, entry) do
      if ModelProfiles.real?(profile_id),
        do: %{@marker => %{profile_id: profile_id, entry: entry}},
        else: raise(ArgumentError, "not a reviewed real profile: #{inspect(profile_id)}")
    end
  end
end
