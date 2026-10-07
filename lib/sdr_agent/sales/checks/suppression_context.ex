defmodule SdrAgent.Sales.Checks.SuppressionContext do
  @moduledoc """
  Policy check: the write is a side effect of an Outreach Suppression create
  (S2 Suppression: "Same-transaction side effects: matching enrollments →
  stopped … leads → stopped"), made by one of the system actors that may
  create suppressions (`:types`, default AGT, DLV, WHK and SEED).

  `SdrAgent.Outreach` sets the private marker returned by `context/0` only on
  the Lead and CampaignEnrollment `:stop` writes its Suppression create makes;
  no public domain function sets it. It lets agent- or delivery-created
  suppressions stop leads and enrollments without granting those actors a
  general stop (S5 obligation). Lives in Sales (the lower domain) so Outreach
  may depend on it, never the reverse.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_suppression_side_effect
  @types [:agent_runtime, :delivery_worker, :webhook_ingestor, :seeder]

  @impl true
  def describe(_opts), do: "stop made by an Outreach suppression create"

  @impl true
  def match?(%SdrAgent.Actor{type: type}, %{subject: %{context: context}}, opts)
      when is_map(context),
      do: Map.get(context, @marker) == true and type in Keyword.get(opts, :types, @types)

  def match?(_actor, _context, _opts), do: false

  @doc "The context map the suppression create attaches to its side-effect writes."
  def context, do: %{@marker => true}
end
