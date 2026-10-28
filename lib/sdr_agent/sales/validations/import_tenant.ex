defmodule SdrAgent.Sales.Validations.ImportTenant do
  @moduledoc """
  The tenant-bound relationship guard of the D-237 `:import_prototype`
  actions of Contact and Lead (Codex 9a6dba0a R1). Every referenced row
  (a contact's `account_id`; a lead's `contact_id` and `account_id`) must
  exist in the NEW row's own tenant, the `tenant_id` that
  `SdrAgent.Audit.Changes.SetTenant` derived from the acting operator.

  It is declared with `before_action?: true`, so it runs after
  authorization (a refused caller stays `Forbidden`) and inside the
  action's transaction, when `tenant_id` is already set; a nil tenant or a
  nil reference is refused. Each lookup is a kernel read filtered by both
  the id AND that tenant (a kernel read alone imposes no tenant filter);
  nothing is returned. A refusal is `{field, "is not a row of this
  tenant"}`, with no value. Option: `:refs`, a keyword of attribute to
  resource.

  Only the two import actions use it; the ordinary create paths and
  `SdrAgent.Sales.Changes.LeadAccount` (which still requires a lead's
  account to be its contact's, and active) are unchanged.

  Test-seam builds only (Codex 683a74e6): the reference read is
  instrumented for fault controls. A scope a test put under
  `{__MODULE__, :read_fault}` in the calling process, `{edge, ref, kind}`,
  applies only when `edge` is exactly this read's `%{field:, resource:,
  id:, tenant_id:}`; it then sends `{__MODULE__, :reached, ref}` to the
  calling process and: `{:error, error}` returns that error, running no
  SQL; `:abort` runs one `SELECT 1 / 0` tagged `{:import_tenant, ref}` and
  then the real read; `:raise` raises a fixed synthetic `ArgumentError`. No
  scope, or another edge's scope, is the real read; every other build is
  the plain real read. What a read's result means is unchanged here.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias SdrAgent.Audit.Kernel

  @impl true
  def init(opts) do
    if refs?(opts[:refs]),
      do: {:ok, opts},
      else: {:error, "ImportTenant requires :refs, a keyword of attribute to resource"}
  end

  defp refs?([_ | _] = refs), do: Enum.all?(refs, &ref?/1)
  defp refs?(_refs), do: false

  defp ref?({field, resource}), do: is_atom(field) and is_atom(resource)
  defp ref?(_other), do: false

  @impl true
  def validate(changeset, opts, _context) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    Enum.find_value(opts[:refs], :ok, fn {field, resource} ->
      id = Ash.Changeset.get_attribute(changeset, field)

      unless in_tenant?(field, resource, id, tenant_id),
        do: {:error, field: field, message: "is not a row of this tenant"}
    end)
  end

  defp in_tenant?(field, resource, id, tenant_id) when is_binary(id) and is_binary(tenant_id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> reference_read(%{field: field, resource: resource, id: id, tenant_id: tenant_id})
    |> case do
      {:ok, %{tenant_id: ^tenant_id}} -> true
      _none_or_error -> false
    end
  end

  defp in_tenant?(_field, _resource, _id, _tenant_id), do: false

  # The reference read (see the moduledoc for the test-seam scope).
  if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
    defp reference_read(query, edge) do
      case Process.get({__MODULE__, :read_fault}) do
        {^edge, ref, kind} when is_reference(ref) -> fault(kind, query, ref)
        _absent_or_other_edge -> Ash.read_one(query)
      end
    end

    defp fault(kind, query, ref) do
      send(self(), {__MODULE__, :reached, ref})

      case kind do
        {:error, error} ->
          {:error, error}

        :abort ->
          _aborted =
            SdrAgent.Repo.query("SELECT 1 / 0", [],
              telemetry_options: [d237_s3_fault: {:import_tenant, ref}]
            )

          Ash.read_one(query)

        :raise ->
          raise ArgumentError, "test seam: import tenant reference read"
      end
    end
  else
    defp reference_read(query, _edge), do: Ash.read_one(query)
  end
end
