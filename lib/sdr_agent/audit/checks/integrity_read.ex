defmodule SdrAgent.Audit.Checks.IntegrityRead do
  @moduledoc """
  Policy check: the read is the audit kernel's integrity read of a stored
  row (through `SdrAgent.Audit.Kernel.integrity_opts/1`, used by
  `SdrAgent.Audit.Verifier` and `SdrAgent.Audit.Changes.AppendEvent`): a
  `:kernel` `SdrAgent.Actor` with both the kernel marker and the private
  integrity marker in the query context.

  It lets the kernel compute `record_sha256` over the full row where a
  field policy withholds a field from every business read — the R0-07
  `ModelInvocation.parsed_output` gate. A plain kernel read
  (`Kernel.opts/1`) never matches it.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Audit.Checks.KernelContext

  @marker :sdr_audit_integrity

  @impl true
  def describe(_opts), do: "request is the audit kernel's integrity read"

  @impl true
  def match?(
        %SdrAgent.Actor{type: :kernel} = actor,
        %{subject: %{context: context}} = check,
        opts
      )
      when is_map(context),
      do: Map.get(context, @marker) == true and KernelContext.match?(actor, check, opts)

  def match?(_actor, _context, _opts), do: false

  @doc "The context map of the kernel's integrity read (kernel marker included)."
  def context, do: Map.put(KernelContext.context(), @marker, true)
end
