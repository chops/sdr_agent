defmodule SdrAgent.Sales.Changes.NormalizeDomain do
  @moduledoc """
  Stores an account `domain` in its company-identity form,
  `SdrAgent.Sales.Domain.canonical/1` (packet section 3 Account; plan r8
  section 2.7; D-174 Q-O6): trimmed and lowercase, with one trailing `.` and
  one leading `www.` removed, accepted only as a valid company fixed point.
  Input that form refuses (a repeated leading `www.`, consecutive dots or an
  empty label, more than one trailing dot, fewer than two labels after the
  strip, a scheme, port, path, address or non-ASCII host) is refused with a
  fixed `InvalidAttribute` on `:domain` that carries no value, so the
  refused input never appears in the error, a log or a span. Existing rows
  are never rewritten; a value that is already the canonical form is stored
  unchanged (fixed point).

  The reserved-name guard (`SdrAgent.Sales.Validations.Reserved`) still
  applies to the stored form.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Sales.Domain

  @refusal "is not a valid company domain"

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :domain) do
      {:ok, domain} when not is_nil(domain) -> normalize(changeset, to_string(domain))
      _unchanged -> changeset
    end
  end

  defp normalize(changeset, raw) do
    case Domain.canonical(raw) do
      {:ok, canonical} ->
        Ash.Changeset.force_change_attribute(changeset, :domain, canonical)

      {:error, :invalid_domain} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: :domain, message: @refusal)
        )
    end
  end
end
