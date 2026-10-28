defmodule SdrAgent.Sales.Validations.DatasetDomain do
  @moduledoc """
  The domain and address guard of the three `:import_prototype` actions
  (Account, Contact; interfaces r6 IF-6 "Dataset class", plan r3
  "Domain validator"). In ordinary runtime it is exactly
  `SdrAgent.Sales.Validations.Reserved`: only reserved (synthetic) names.
  In prototype runtime the binding's dataset class is `real_prototype`, so
  an imported account domain may be a public host and a contact address a
  work address on it: the value must be a lower-case host name of at least
  two labels, and an address's host must equal the domain of its account
  IN THE NEW ROW'S TENANT (a tenant-filtered read; Codex 9a6dba0a R1), so
  the address check is declared `before_action?: true`, after SetTenant
  and authorization. (The dossier parser has already applied its stricter
  host rule to the row.) The import coordinator passes the parsed dossier
  row's own values, so each equals its entry.
  The campaign sender address and the booking link keep `Reserved`; this
  validator is never used anywhere else. Options: `:attribute`, `:kind`
  (`:domain` or `:email`). The prototype rule is compiled only with the
  prototype authority (`:prototype_authority_compiled`); the production
  build has the `Reserved` rule only.
  """
  use Ash.Resource.Validation

  alias SdrAgent.Sales.Validations.Reserved

  # D-237: the prototype rule exists only in builds with the prototype
  # authority (config/dev.exs and config/test.exs); the production build has
  # the reserved-name rule only.
  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl true
  def init(opts) do
    if opts[:kind] in [:domain, :email] and is_atom(opts[:attribute]),
      do: {:ok, opts},
      else: {:error, "DatasetDomain requires :attribute and :kind (:domain or :email)"}
  end

  @impl true
  def validate(changeset, opts, context), do: dispatch(changeset, opts, context)

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  if @prototype_compiled do
    require Ash.Query

    alias SdrAgent.Audit.Kernel

    @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    @host ~r/\A(?=.{1,253}\z)#{@label}(?:\.#{@label})+\z/
    @local ~r/\A[a-z0-9.!#$%&'*+\/=?^_`{|}~-]{1,64}\z/

    defp dispatch(changeset, opts, context) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: prototype(changeset, opts),
        else: Reserved.validate(changeset, opts, context)
    end

    defp prototype(changeset, opts) do
      case Ash.Changeset.get_attribute(changeset, opts[:attribute]) do
        nil -> :ok
        value -> check(opts[:kind], to_string(value), changeset, opts[:attribute])
      end
    end

    defp check(:domain, value, _changeset, field),
      do: if(host?(value), do: :ok, else: refuse(field))

    defp check(:email, value, changeset, field) do
      with [local, host] <- String.split(value, "@"),
           true <- Regex.match?(@local, local) and host?(host),
           true <- host == account_domain(changeset) do
        :ok
      else
        _ -> refuse(field)
      end
    end

    defp host?(value), do: value == String.downcase(value) and Regex.match?(@host, value)

    # The account of the new contact's own tenant (Codex 9a6dba0a R1). The
    # address check is declared `before_action?: true`, so `tenant_id` is the
    # one SetTenant derived from the actor; the kernel read imposes no tenant
    # filter of its own, so the filter names both the id and that tenant.
    defp account_domain(changeset) do
      with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :account_id),
           tenant_id when is_binary(tenant_id) <-
             Ash.Changeset.get_attribute(changeset, :tenant_id),
           {:ok, %{tenant_id: ^tenant_id} = account} <-
             SdrAgent.Sales.Account
             |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
             |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
             |> Ash.read_one() do
        to_string(account.domain)
      else
        _ -> nil
      end
    end

    defp refuse(field),
      do: {:error, field: field, message: "is not a dossier host or work address"}
  else
    # The production build has no prototype runtime: the reserved-name rule.
    defp dispatch(changeset, opts, context), do: Reserved.validate(changeset, opts, context)
  end
end
