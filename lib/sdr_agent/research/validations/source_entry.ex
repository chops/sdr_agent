defmodule SdrAgent.Research.Validations.SourceEntry do
  @moduledoc """
  The entry-to-lead consistency of `SdrAgent.Research.DossierSource
  :import` (D-237; Codex 9ada21de): the source's `entry_id` must name a
  `SdrAgent.Research.DossierEntry` of the acting operator's tenant, of the
  same lead as the source, imported by the same delegation (the acting
  operator). Anything else is refused on `entry_id` with the rule
  `:entry_mismatch`, value-free, before the write.

  The entry is re-read through the audit kernel inside the row's
  transaction (the entry written earlier in the same transaction is
  visible); no caller-supplied tenant, lead or delegation is trusted.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Research.DossierEntry

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, %{actor: %SdrAgent.Actor{id: id, tenant_id: tenant_id}})
      when is_binary(id) and is_binary(tenant_id) do
    entry_id = Ash.Changeset.get_attribute(changeset, :entry_id)
    lead_id = Ash.Changeset.get_attribute(changeset, :lead_id)

    with true <- is_binary(entry_id) and is_binary(lead_id),
         {:ok, %DossierEntry{lead_id: ^lead_id, delegation_id: ^id, tenant_id: ^tenant_id}} <-
           entry(entry_id, tenant_id) do
      :ok
    else
      _mismatch -> refuse()
    end
  end

  def validate(_changeset, _opts, _context), do: refuse()

  defp entry(entry_id, tenant_id) do
    DossierEntry
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^entry_id and tenant_id == ^tenant_id)
    |> Ash.read_one()
  end

  defp refuse,
    do:
      {:error,
       field: :entry_id,
       message: "is not an entry of this lead and delegation (%{rule})",
       rule: :entry_mismatch}
end
