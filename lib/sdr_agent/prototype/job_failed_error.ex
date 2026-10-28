# Containment pure GREEN (proposal r1). Compiled only with the prototype
# authority; the production build has no containment code.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.JobFailedError do
    @moduledoc """
    The closed, value-free exception that E2 stores in place of a prototype
    job's error (containment packet r4 section 5). It has no fields, and
    `message/1` returns exactly `"prototype_job_failed"`, so
    `Oban.Job.format_attempt/1` stores
    `"** (SdrAgent.Prototype.JobFailedError) prototype_job_failed"`.
    """
    defexception []

    @impl Exception
    def message(_exception), do: "prototype_job_failed"
  end
end
