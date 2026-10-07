defmodule SdrAgent.Sales.Validations.Reserved do
  @moduledoc """
  Validates that an attribute satisfies the synthetic-data guard
  (`SdrAgent.Sales.Synthetic`). Options: `:attribute`, `:kind` (`:domain`,
  `:email` or `:url`). A nil value is left to `allow_nil?`.
  """
  use Ash.Resource.Validation

  alias SdrAgent.Sales.Synthetic

  @impl true
  def init(opts) do
    if opts[:kind] in [:domain, :email, :url] and is_atom(opts[:attribute]),
      do: {:ok, opts},
      else: {:error, "Reserved requires :attribute and :kind (:domain, :email or :url)"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    case Ash.Changeset.get_attribute(changeset, opts[:attribute]) do
      nil ->
        :ok

      value ->
        if reserved?(opts[:kind], to_string(value)),
          do: :ok,
          else: {:error, field: opts[:attribute], message: Synthetic.rule()}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp reserved?(:domain, value), do: Synthetic.reserved_domain?(value)
  defp reserved?(:email, value), do: Synthetic.reserved_email?(value)
  defp reserved?(:url, value), do: Synthetic.fixture_url?(value)
end
