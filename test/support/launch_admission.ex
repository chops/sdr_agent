defmodule SdrAgent.Test.LaunchAdmission do
  @moduledoc """
  Stand-ins for `SdrAgent.Agents.admit_launch/3` in ClaudeCLI tests that run
  without a reserved invocation (C9-03). Passed as the test-build-only
  `:launch_admission` start option, which ClaudeCLI honours only together
  with an injected test launcher; every other launch is admitted by the
  real `Agents.admit_launch/3`.
  """

  @doc "Admits every launch."
  def admitted(_invocation_id, _profile, _opts), do: {:ok, :admitted}

  @doc "Reports each admission to `pid` as `{:launch_admission, id, profile, opts}`, then answers `reply`."
  def recording(pid, reply \\ {:ok, :admitted}) do
    fn invocation_id, profile, opts ->
      send(pid, {:launch_admission, invocation_id, profile, opts})
      reply
    end
  end
end
