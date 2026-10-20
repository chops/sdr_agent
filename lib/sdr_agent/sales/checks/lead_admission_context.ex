defmodule SdrAgent.Sales.Checks.LeadAdmissionContext do
  @moduledoc """
  Policy check: the write is made from inside the lead admission
  orchestrator (packet section 3, Sales.LeadAdmission `:record` and, from the
  C3-02 cutover, Lead `:create`; named by C3-02 D6).

  The orchestrator (`SdrAgent.SDR.admit_lead/2`) sets the private marker
  returned by `context/0` on the writes it makes inside its own transaction;
  no public domain function sets it. Lives in Sales (the lower domain), as
  `SdrAgent.Sales.Checks.QualificationContext` does, so the orchestrator
  above may depend on it, never the reverse.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_lead_admission_write

  @impl true
  def describe(_opts), do: "write made by the lead admission orchestrator"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts) when is_map(context),
    do: Map.get(context, @marker) == true

  def match?(_actor, _context, _opts), do: false

  @doc "The context map the admission orchestrator attaches to its writes."
  def context, do: %{@marker => true}
end
