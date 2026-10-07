defmodule SdrAgent.Audit.Checks.KernelContext do
  @moduledoc """
  Policy check: the request is made by the audit kernel — a `:kernel`
  `SdrAgent.Actor` with the private kernel marker in the query, changeset or
  action-input context (see `SdrAgent.Audit.Kernel.opts/1`).

  Ledger writes (AuditEvent, AuditChainHead, AuditAccess) and content reads
  authorize only through this check, so no domain action can append to the
  chain except via the kernel.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_audit_kernel

  @impl true
  def describe(_opts), do: "request made by the audit kernel"

  @impl true
  def match?(%SdrAgent.Actor{type: :kernel}, %{subject: %{context: context}}, _opts)
      when is_map(context),
      do: Map.get(context, @marker) == true

  def match?(_actor, _context, _opts), do: false

  @doc "The context map the kernel attaches to its requests."
  def context, do: %{@marker => true}
end
