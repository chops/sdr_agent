# DRAFT r4 (outside the repository; review only; NOT formatted, compiled or
# run). Deny-only: message/1 does not yet return the fixed text.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.JobFailed do
    @moduledoc """
    The closed, value-free exception that E2 stores in place of a prototype
    job's error (containment packet r4 section 5). GREEN contract: no
    fields, and `message/1` returns exactly `"prototype_job_failed"`, so
    `Oban.Job.format_attempt/1` stores
    `"** (SdrAgent.Prototype.JobFailed) prototype_job_failed"`.

    Stage: deny-only.
    """
    defexception []

    @impl Exception
    def message(_exception), do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so callers compile against it.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
