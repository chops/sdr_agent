defmodule SdrAgent.Sales.Validations.Timezone do
  @moduledoc """
  Validates that an attribute is shaped like an IANA time zone name
  (`Area/Location[/Sublocation]`, or `UTC`/`Etc/UTC`).

  Elixir ships only a UTC time zone database and S5 adds no dependency, so
  the zone's existence is not checked here; the slice that first evaluates
  local time (S8: quiet hours, send quota, follow-up dates) adds a time zone
  database by ADR and tightens this check. Option: `:attribute`.
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
        if Regex.match?(@shape, zone),
          do: :ok,
          else: {:error, field: opts[:attribute], message: "must be an IANA time zone name"}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end
