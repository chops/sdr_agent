defmodule SdrAgent.Sales.Validations.DatasetDomain do
  @moduledoc """
  The domain and address guard of the three `:import_prototype` actions
  (Account, Contact; interfaces r6 IF-6 "Dataset class", plan r3
  "Domain validator"). In ordinary runtime it is exactly
  `SdrAgent.Sales.Validations.Reserved`: only reserved (synthetic) names.
  In prototype runtime the binding's dataset class is `real_prototype`, so
  an imported account domain may be a public host and a contact address a
  work address on it: the value must be a lower-case host name of at least
  two labels, and an address's host must equal its account's domain. (The
  dossier parser has already applied its stricter host rule to the row.) The import coordinator
  passes the parsed dossier row's own values, so each equals its entry.
  The campaign sender address and the booking link keep `Reserved`; this
  validator is never used anywhere else. Options: `:attribute`, `:kind`
  (`:domain` or `:email`).
  """
  use Ash.Resource.Validation

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Prototype
  alias SdrAgent.Sales.Validations.Reserved

  @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @host ~r/\A(?=.{1,253}\z)#{@label}(?:\.#{@label})+\z/
  @local ~r/\A[a-z0-9.!#$%&'*+\/=?^_`{|}~-]{1,64}\z/

  @impl true
  def init(opts) do
    if opts[:kind] in [:domain, :email] and is_atom(opts[:attribute]),
      do: {:ok, opts},
      else: {:error, "DatasetDomain requires :attribute and :kind (:domain or :email)"}
  end

  @impl true
  def validate(changeset, opts, context) do
    if Prototype.runtime() == :prototype,
      do: prototype(changeset, opts),
      else: Reserved.validate(changeset, opts, context)
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

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

  defp account_domain(changeset) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :account_id),
         tenant_id when is_binary(tenant_id) <- Ash.Changeset.get_attribute(changeset, :tenant_id),
         {:ok, account} <- Ash.get(SdrAgent.Sales.Account, id, Kernel.opts(tenant_id)) do
      to_string(account.domain)
    else
      _ -> nil
    end
  end

  defp refuse(field), do: {:error, field: field, message: "is not a dossier host or work address"}
end
