defmodule SdrAgent.Audit.Changes.Stamp do
  @moduledoc """
  Sets timestamp attributes to `SdrAgent.Clock.utc_now/0` (works in atomic
  updates). Option `:fields` — the attributes to stamp. With
  `duration_ms_since: field`, also sets `duration_ms` to the milliseconds
  elapsed since that (immutable) attribute.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Enum.reduce(values(changeset, opts), changeset, fn {field, value}, acc ->
      Ash.Changeset.force_change_attribute(acc, field, value)
    end)
  end

  @impl true
  def atomic(changeset, opts, _context), do: {:atomic, values(changeset, opts)}

  defp values(changeset, opts) do
    now = SdrAgent.Clock.utc_now()
    stamps = Map.new(opts[:fields], &{&1, now})

    case opts[:duration_ms_since] do
      nil ->
        stamps

      field ->
        case Map.get(changeset.data, field) do
          %DateTime{} = since ->
            Map.put(stamps, :duration_ms, DateTime.diff(now, since, :millisecond))

          _ ->
            stamps
        end
    end
  end
end
