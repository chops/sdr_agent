defmodule SdrAgent.Agents.Checks.CalibrationContext do
  @moduledoc """
  The only calibration authority (R0-07 entity PASS at 1da747a, entity
  CalibrationContext; REQ-07-3): a private changeset or query context marker
  carrying the calibration profile id.

  It exists only in test-seam builds (`config :sdr_agent,
  :claude_cli_test_seams, true`, `config/test.exs`): `context/1`, the only
  builder, is compiled only there, and `match?/3` and `profile/1` answer
  "absent" in every other build even if the marker is forged. The external
  calibration harness (R0-07 slice D) sets it as AGT; in slice A it gates
  the `:calibration` disposition of `SdrAgent.Agents.ModelResultRelease`
  and the calibration read of `ModelInvocation.parsed_output`.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_calibration_context
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @impl true
  def describe(_opts), do: "request made under the test-seam calibration context"

  @impl true
  def match?(%SdrAgent.Actor{type: :agent_runtime}, %{subject: %{context: context}}, _opts),
    do: not is_nil(profile(context))

  def match?(_actor, _context, _opts), do: false

  @doc """
  The calibration profile id in `context`, or nil when there is none (always
  nil outside test-seam builds).
  """
  def profile(context), do: if(@test_seams, do: marked_profile(context))

  defp marked_profile(%{@marker => %{profile_id: profile_id}})
       when is_atom(profile_id) and not is_nil(profile_id),
       do: profile_id

  defp marked_profile(_context), do: nil

  if @test_seams do
    @doc "Test-seam builds only: the calibration context for `profile_id`."
    def context(profile_id) when is_atom(profile_id), do: %{@marker => %{profile_id: profile_id}}
  end
end
