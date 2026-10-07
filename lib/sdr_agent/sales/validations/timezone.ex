defmodule SdrAgent.Sales.Validations.Timezone do
  @moduledoc """
  Validates that an attribute is an IANA time zone name: shaped like one
  (`Area/Location[/Sublocation]`, or `UTC`/`Etc/UTC`) *and* known to the time
  zone database (`SdrAgent.Sales.LocalTime.valid_zone?/1`, ADR-0011 — S8
  tightened the S5 shape-only check). Option: `:attribute`.
  """
  use Ash.Resource.Validation

  @shape ~r/^(UTC|Etc\/UTC|[A-Z][A-Za-z_-]+(\/[A-Za-z0-9_+-]+){1,2})$/

  @impl true
  def init(opts),
    do: if(is_atom(opts[:attribute]), do: {:ok, opts}, else: {:error, "requires :attribute"})

  @impl true
  def validate(changeset, opts, _context) do
    case Ash.Changeset.get_attribute(changeset, opts[:attribute]) do
      nil ->
        :ok

      zone when is_binary(zone) ->
        if Regex.match?(@shape, zone) and SdrAgent.Sales.LocalTime.valid_zone?(zone),
          do: :ok,
          else: {:error, field: opts[:attribute], message: "must be an IANA time zone name"}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end
