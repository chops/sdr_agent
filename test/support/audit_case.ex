defmodule SdrAgent.AuditCase do
  @moduledoc """
  Test case for the audit kernel and Agents domain: sandboxed database,
  actor builders, and raw-SQL helpers that simulate an administrator
  bypassing the application (used only to prove tamper detection and
  trigger enforcement).
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL

  using do
    quote do
      import SdrAgent.AuditCase
      alias SdrAgent.Repo
    end
  end

  setup tags do
    SdrAgent.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Bootstraps the singleton tenant through the kernel and returns it."
  def bootstrap! do
    {:ok, tenant} = SdrAgent.Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    tenant
  end

  @doc "Builds a system actor of `type` for `tenant`."
  def system_actor(type, tenant), do: struct(SdrAgent.Actor, type: type, tenant_id: tenant.id)

  @doc "Builds a human operator stand-in with `role` for `tenant`."
  def human(role, tenant) do
    %SdrAgent.Test.Human{id: Ecto.UUID.generate(), role: role, tenant_id: tenant.id}
  end

  @doc "All audit events of the tenant in sequence order, read as an admin."
  def events(tenant) do
    {:ok, events} = SdrAgent.Audit.list_events(actor: human(:admin, tenant))
    events
  end

  @doc "Events of one event type."
  def events_of_type(tenant, type), do: Enum.filter(events(tenant), &(&1.event_type == type))

  @doc "Runs raw SQL with triggers disabled, simulating a database administrator."
  def tamper!(sql, params \\ []) do
    SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])
    result = SQL.query!(SdrAgent.Repo, sql, params)
    SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = origin", [])
    result
  end

  @doc "Runs raw SQL in a savepoint and returns the Postgres error it raises."
  def raw_error(sql, params \\ []) do
    SdrAgent.Repo.transaction(fn ->
      case SQL.query(SdrAgent.Repo, sql, params) do
        {:ok, result} -> SdrAgent.Repo.rollback({:unexpected_success, result})
        {:error, error} -> SdrAgent.Repo.rollback(error)
      end
    end)
  end

  @doc "A fixed 32-byte digest for fixtures."
  def digest(label), do: :crypto.hash(:sha256, label)

  @doc "Lowercase hex of a binary."
  def hex(bin), do: Base.encode16(bin, case: :lower)
end
