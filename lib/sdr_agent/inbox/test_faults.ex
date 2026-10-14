if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.Inbox.TestFaults do
    @moduledoc "Closed C1 metadata-read faults; this module exists only in test-seam builds."

    @sources [
      :draft_list,
      :failure_list,
      :pending_email_drafts,
      :live_failures,
      :local_captures_this_week,
      :audit_append
    ]
    @modes [:returned, :raised, :timeout]

    @doc "The exact reviewed six-source by three-mode fault set."
    def selectors, do: for(source <- @sources, mode <- @modes, do: {source, mode})

    @doc "Apply a closed synthetic fault only to its matching source."
    def run({source, :returned}, source, _fun), do: {:error, :producer_error}
    def run({source, :timeout}, source, _fun), do: {:error, :timeout}
    def run({source, :raised}, source, _fun), do: raise("synthetic C1 read failure")
    def run(_, _, fun), do: fun.()
  end
end
