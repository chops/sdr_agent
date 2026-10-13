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
  The `{profile_id, entry}` the marker `term` names; nil when no marker was
  supplied; `:invalid` when one was supplied but is malformed (missing
  fields, not a reviewed real profile, or not a marker at all), so it is
  refused rather than read as absence (review MF2). Always nil outside
  test-seam builds. The entry is returned as given; admission validates it.
  """
  def scope(term), do: if(@test_seams, do: marked(term))

  @doc """
  The console's launch-record claim (`instance_id`) the marker `term`
  carries (R0-07 E4c-2), or nil: no marker, no claim, or a marker that is
  not valid (which `scope/1` refuses). Always nil outside test-seam builds.
  """
  if @test_seams do
    def claim(term) do
      with {_profile_id, _entry} <- marked(term),
           %{@marker => %{claim: claim}} <- term do
        claim
      else
        _ -> nil
      end
    end
  else
    def claim(_term), do: nil
  end

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  defp marked(nil), do: nil

  defp marked(%{@marker => %{profile_id: profile_id, entry: entry} = marker})
       when is_atom(profile_id) do
    if ModelProfiles.real?(profile_id) and claim?(Map.get(marker, :claim, nil)),
      do: {profile_id, entry},
      else: :invalid
  end

  defp marked(_malformed), do: :invalid

  # A claim is absent or a launch-record instance id; anything else makes
  # the whole marker invalid (never a claimless reservation).
  defp claim?(nil), do: true
  defp claim?(claim), do: is_binary(claim) and claim =~ @uuid

  if @test_seams do
    @doc """
    Test-seam builds only: the calibration admission marker for one
    calibration call of the reviewed real profile `profile_id` under the
    candidate `entry`, with the console's launch-record `claim:` (an
    instance id) when given. Raises `ArgumentError` for anything but a real
    profile id or a well-formed claim.
    """
    def context(profile_id, entry, opts \\ []) do
      claim = Keyword.get(opts, :claim)

      cond do
        not ModelProfiles.real?(profile_id) ->
          raise ArgumentError, "not a reviewed real profile: #{inspect(profile_id)}"

        not claim?(claim) ->
          raise ArgumentError, "not a launch-record claim: #{inspect(claim)}"

        is_nil(claim) ->
          %{@marker => %{profile_id: profile_id, entry: entry}}

        true ->
          %{@marker => %{profile_id: profile_id, entry: entry, claim: claim}}
      end
    end
  end
end
