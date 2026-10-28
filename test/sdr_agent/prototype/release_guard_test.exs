defmodule SdrAgent.Prototype.ReleaseGuardTest do
  @moduledoc """
  RED-b2c (Codex 3122b0d4 Q3, R1), D-237 slice S2: the producer and
  consumer guard of the release increment's internal APIs, over the
  compiled test build's imports (remote calls; a dynamic `apply/3` is not
  covered, as in `AdmissionRegisterGuardTest`).

  | API (pinned for b2c) | Its only importer |
  |---|---|
  | `SdrAgent.Prototype.Basis.build/1` | `SdrAgent.Prototype.Release` |
  | `SdrAgent.Prototype.Basis.verify_new/2` | `SdrAgent.Agents.Changes.ReleaseDecision` |
  | `SdrAgent.Prototype.Basis.verify_historical/2` | `SdrAgent.Prototype.ReleasedScope` |
  | `SdrAgent.Prototype.ReleasedScope.run/3` | `SdrAgent.Agents.ReleasedOutput` (b2d adds the predicate) |
  | `SdrAgent.Prototype.Admission.check_recorded/3` (the closed 14-key comparator) | `SdrAgent.Prototype.Release` (launch uses it locally) |
  | `SdrAgent.Prototype.Admission.check_charge/3` (the charged grant's current checks) | `SdrAgent.Prototype.Release` (launch uses it locally) |

  And the release never calls the launch gate itself
  (`Prototype.Admission.launch/3`). The APIs do not exist yet, so the
  importer cases fail STRUCTURALLY (no importer), never as semantic RED; the
  launch/3 case is a control. No database.
  """
  use ExUnit.Case, async: true

  defp importers(mfa) do
    for module <- Application.spec(:sdr_agent, :modules),
        path <- [:code.which(module)],
        is_list(path),
        {:ok, {^module, [imports: imports]}} <- [:beam_lib.chunks(path, [:imports])],
        mfa in imports,
        do: module
  end

  for {mfa, importer} <- [
        {{SdrAgent.Prototype.Basis, :build, 1}, SdrAgent.Prototype.Release},
        {{SdrAgent.Prototype.Basis, :verify_new, 2}, SdrAgent.Agents.Changes.ReleaseDecision},
        {{SdrAgent.Prototype.Basis, :verify_historical, 2}, SdrAgent.Prototype.ReleasedScope},
        {{SdrAgent.Prototype.ReleasedScope, :run, 3}, SdrAgent.Agents.ReleasedOutput},
        {{SdrAgent.Prototype.Admission, :check_recorded, 3}, SdrAgent.Prototype.Release},
        {{SdrAgent.Prototype.Admission, :check_charge, 3}, SdrAgent.Prototype.Release}
      ] do
    {module, fun, arity} = mfa

    test "only #{inspect(importer)} imports #{inspect(module)}.#{fun}/#{arity}" do
      assert importers(unquote(Macro.escape(mfa))) == [unquote(importer)],
             "structural until b2c: importers #{inspect(importers(unquote(Macro.escape(mfa))))}"
    end
  end

  test "the release never calls the launch gate" do
    refute SdrAgent.Prototype.Release in importers({SdrAgent.Prototype.Admission, :launch, 3})
  end
end
