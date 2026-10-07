defmodule SdrAgent.Audit.GuardedCall do
  @moduledoc """
  Shared helpers for domain code interfaces: run one Ash create, update or
  read through `SdrAgent.Audit.Guard`, so refused auditor (AUR) mutations and
  denials of guarded actions are audited (S2 "Denial audit contract").

  Domain modules (`SdrAgent.Accounts`, `SdrAgent.Sales`,
  `SdrAgent.Research`) call these with an explicit `actor:`; reads are
  scoped to the actor's tenant.
  """

  require Ash.Query

  alias SdrAgent.Audit.Guard

  @doc """
  Runs create `action` of `resource` with `attrs`. Options: `actor:`,
  `guarded?:` (a guarded action: every denial is audited), `subject_id:`.
  """
  def create(resource, action, attrs, opts) do
    actor = Keyword.get(opts, :actor)

    run(resource, action, opts[:subject_id], opts, fn ->
      resource
      |> Ash.Changeset.for_create(action, attrs, actor: actor)
      |> Ash.create()
    end)
  end

  @doc "Runs update `action` on `record` with `attrs` (options as `create/4`)."
  def update(%resource{} = record, action, attrs, opts) do
    actor = Keyword.get(opts, :actor)

    run(resource, action, record.id, opts, fn ->
      record
      |> Ash.Changeset.for_update(action, attrs, actor: actor)
      |> Ash.update()
    end)
  end

  @doc "Reads one row of `resource` by id, scoped to the actor's tenant."
  def get(resource, id, opts) do
    resource
    |> read_query(opts)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: resource)}
      other -> other
    end
  end

  @doc """
  Lists rows of `resource` in the actor's tenant. Options: `actor:`,
  `filter:` (keyword of attribute equalities), `sort:` (default
  `inserted_at: :asc`).
  """
  def list(resource, opts) do
    resource
    |> read_query(opts)
    |> Ash.Query.do_filter(Keyword.get(opts, :filter, []))
    |> Ash.Query.sort(Keyword.get(opts, :sort, inserted_at: :asc, id: :asc))
    |> Ash.read()
  end

  @doc "A read query for `resource` as the actor, scoped to the actor's tenant."
  def read_query(resource, opts) do
    actor = Keyword.get(opts, :actor)

    resource
    |> Ash.Query.for_read(Keyword.get(opts, :action, :read), %{}, actor: actor)
    |> tenant_scope(actor)
  end

  defp run(resource, action, subject_id, opts, fun) do
    meta = %{
      resource: resource,
      action: action,
      guarded?: Keyword.get(opts, :guarded?, false),
      subject_id: subject_id
    }

    Guard.run(meta, Keyword.get(opts, :actor), fun)
  end

  defp tenant_scope(query, %{tenant_id: tenant_id}) when is_binary(tenant_id),
    do: Ash.Query.filter(query, tenant_id == ^tenant_id)

  # An operator without a tenant reads nothing (fail closed).
  defp tenant_scope(query, %SdrAgent.Accounts.User{}), do: Ash.Query.filter(query, false)
  defp tenant_scope(query, _actor), do: query
end
