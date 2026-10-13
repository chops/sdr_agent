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
  The console's G-R0 binding (`%{grant_id, grant_revision, allocation_id,
  profile_id}`, packet 8.3) the marker `term` carries, or nil (as
  `claim/1`). Always nil outside test-seam builds.
  """
  if @test_seams do
    def binding(term) do
      with {_profile_id, _entry} <- marked(term),
           %{@marker => %{binding: binding}} <- term do
        binding
      else
        _ -> nil
      end
    end
  else
    def binding(_term), do: nil
  end

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
    if ModelProfiles.real?(profile_id) and claim?(Map.get(marker, :claim, nil)) and
         binding?(Map.get(marker, :binding, nil), profile_id),
       do: {profile_id, entry},
       else: :invalid
  end

  defp marked(_malformed), do: :invalid

  # A claim is absent or a launch-record instance id; anything else makes
  # the whole marker invalid (never a claimless reservation).
  defp claim?(nil), do: true
  defp claim?(claim), do: is_binary(claim) and claim =~ @uuid

  # A binding is absent or a well-formed G-R0 binding of the marker's own
  # profile; anything else makes the whole marker invalid.
  defp binding?(nil, _profile_id), do: true

  defp binding?(%{} = binding, profile_id) do
    Enum.sort(Map.keys(binding)) == [:allocation_id, :grant_id, :grant_revision, :profile_id] and
      claim?(binding.grant_id) and not is_nil(binding.grant_id) and
      claim?(binding.allocation_id) and not is_nil(binding.allocation_id) and
      is_integer(binding.grant_revision) and binding.grant_revision > 0 and
      binding.profile_id == profile_id
  end

  defp binding?(_binding, _profile_id), do: false

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
      binding = Keyword.get(opts, :binding)

      cond do
        not ModelProfiles.real?(profile_id) ->
          raise ArgumentError, "not a reviewed real profile: #{inspect(profile_id)}"

        not claim?(claim) ->
          raise ArgumentError, "not a launch-record claim: #{inspect(claim)}"

        not binding?(binding, profile_id) ->
          raise ArgumentError, "not a G-R0 binding of this profile: #{inspect(binding)}"

        true ->
          %{profile_id: profile_id, entry: entry}
          |> put_present(:claim, claim)
          |> put_present(:binding, binding)
          |> then(&%{@marker => &1})
      end
    end

    defp put_present(map, _key, nil), do: map
    defp put_present(map, key, value), do: Map.put(map, key, value)
  end
end
