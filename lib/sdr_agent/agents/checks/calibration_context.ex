defmodule SdrAgent.Agents.Checks.CalibrationContext do
  @moduledoc """
  The only calibration authority (R0-07 entity PASS at 1da747a, entity
  CalibrationContext; round 5 contract (c), PASS at dc8cae7): a private
  changeset or query context marker binding one reviewed real profile and
  one proof invocation.

  It exists only in test-seam builds (`config :sdr_agent,
  :claude_cli_test_seams, true`, `config/test.exs`): `context/2`, the only
  builder, is compiled only there, and `scope/1` answers nil in every other
  build even if the marker is forged.

  Scope: the marker authorizes the `:calibration` latch of
  `SdrAgent.Agents.ModelResultRelease` (`SdrAgent.Agents.Changes.ReleaseDecision`)
  and the calibration read of a ModelInvocation's output-bearing fields
  (`SdrAgent.Agents.Checks.CalibrationRead`) only for the named invocation,
  which must be generation 2, `claude_cli`, of that profile and of a
  `:proof` run, and only as AGT. It is never an input to admission or
  launch. G-R0 binding, the fixed prompt and schema, the REQ-07-7 order and
  real-call authority belong to the reviewed harness (R0-07 slice D).
  """

  alias SdrAgent.AI.ModelProfiles

  @marker :sdr_calibration_context
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @doc """
  The `{profile_id, model_invocation_id}` the calibration context in
  `context` binds, or nil when there is none (always nil outside test-seam
  builds).
  """
  def scope(context), do: if(@test_seams, do: marked(context))

  defp marked(%{@marker => %{profile_id: profile_id, model_invocation_id: invocation_id}})
       when is_atom(profile_id) and is_binary(invocation_id) do
    if ModelProfiles.real?(profile_id), do: {profile_id, invocation_id}
  end

  defp marked(_context), do: nil

  if @test_seams do
    @doc """
    Test-seam builds only: the calibration context for one proof invocation
    of the reviewed real profile `profile_id`. Raises `ArgumentError` for
    anything but a real profile id and an invocation id.
    """
    def context(profile_id, model_invocation_id) when is_binary(model_invocation_id) do
      if ModelProfiles.real?(profile_id),
        do: %{@marker => %{profile_id: profile_id, model_invocation_id: model_invocation_id}},
        else: raise(ArgumentError, "not a reviewed real profile: #{inspect(profile_id)}")
    end

    def context(profile_id, _model_invocation_id),
      do: raise(ArgumentError, "not a calibration scope: #{inspect(profile_id)}")
  end
end
