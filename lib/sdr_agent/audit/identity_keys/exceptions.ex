defmodule SdrAgent.Audit.IdentityKeys.LateAcquisition do
  @moduledoc """
  An identity key was requested after this application transaction's pass,
  outside the pass's recorded set (ADR-0009 C3 amendment item 2; plan r8
  section 2.4 rule 4). Carries the count of ids outside the pass only.
  """
  defexception count: 0

  @impl true
  def message(%{count: count}),
    do: "identity keys requested after the application transaction's pass (#{count} not in it)"
end

defmodule SdrAgent.Audit.IdentityKeys.PassInconsistent do
  @moduledoc """
  The application transaction's identity pass cannot be trusted (plan r8
  section 2.4 rules 1, 2, 5, 7, 9 and an unparseable record): the scope is
  poisoned or mid-acquisition, the recorded set is not physically held,
  the record names another backend, or another record replaced it without
  a proven revert. Carries a fixed reason atom only.
  """
  defexception reason: :inconsistent

  @impl true
  def message(%{reason: reason}),
    do: "the identity pass of this application transaction is inconsistent (#{reason})"
end

defmodule SdrAgent.Audit.IdentityKeys.MissingPass do
  @moduledoc """
  `require_held/2` found no pass in this application transaction (plan r8
  section 2.4, rule 8 for `require_held`). Carries the count of required
  ids only.
  """
  defexception count: 0

  @impl true
  def message(%{count: count}),
    do: "no identity pass covers the #{count} required key(s) in this application transaction"
end

defmodule SdrAgent.Audit.IdentityKeys.AcquisitionFailed do
  @moduledoc """
  An identity pass failed while acquiring or publishing (plan r8 section
  2.5); the application scope is poisoned until it ends. Carries the
  failure's class (`:error`, `:exit` or `:throw`) only.
  """
  defexception class: :error

  @impl true
  def message(%{class: class}), do: "identity key acquisition failed (class #{class})"
end

defmodule SdrAgent.Audit.IdentityKeys.InvalidKeyValue do
  @moduledoc """
  An identity key input is not representable for its kind (plan r8 section
  2.7, `Normalize.key_value/2`). Carries the kind only, never the value.
  """
  defexception kind: :unknown

  @impl true
  def message(%{kind: kind}), do: "invalid #{kind} identity key value"
end

defmodule SdrAgent.Audit.IdentityKeys.NotInTransaction do
  @moduledoc """
  An identity key was requested outside any `SdrAgent.Repo` transaction:
  advisory transaction locks need one (plan r8 section 2.2).
  """
  defexception message: "identity keys require an SdrAgent.Repo transaction"
end

defmodule SdrAgent.Audit.IdentityKeys.UnscopedTransaction do
  @moduledoc """
  An identity key was requested in a transaction with no application
  scope: a standalone `Ecto.Multi`, which the Repo's scope root does not
  wrap (plan r8 section 2.2).
  """
  defexception message:
                 "identity keys requested in a transaction without an application scope " <>
                   "(a standalone Ecto.Multi)"
end

defmodule SdrAgent.Audit.IdentityKeys.ScopeConflict do
  @moduledoc """
  An outermost `SdrAgent.Repo` transaction started while the process
  already holds an application-scope entry; the entry is neither
  overwritten nor deleted (plan r8 section 2.2).
  """
  defexception message: "an application scope is already registered in this process"
end
