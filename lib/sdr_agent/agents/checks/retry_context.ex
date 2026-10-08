defmodule SdrAgent.Agents.Checks.RetryContext do
  @moduledoc """
  Policy check for `AgentRun :retry` (S13b, soft-stop v3): the retry is made
  inside the operator retry orchestration (`SdrAgent.SDR.retry_run/2`), which
  sets this marker only after its locked eligibility checks, in the same
  transaction as the new run's job and Operation. No public domain function
  sets it, so a direct `:retry` — which would create a queued run with no
  executable job — is refused (same pattern as
  `SdrAgent.Outreach.Checks.InternalWrite`).
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_agent_run_retry

  @impl true
  def describe(_opts), do: "retry made inside the operator retry orchestration"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts), do: marked?(context)
  def match?(_actor, _context, _opts), do: false

  @doc "Whether a changeset context carries the retry orchestration marker."
  def marked?(context) when is_map(context), do: Map.get(context, @marker) == true
  def marked?(_context), do: false

  @doc "The context map the retry orchestration attaches to `AgentRun :retry`."
  def context, do: %{@marker => true}
end
