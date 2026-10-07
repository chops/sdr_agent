defmodule SdrAgent.Outreach.Changes.ConsumeUnit do
  @moduledoc """
  SendQuotaDay `:consume`: on the row re-read `FOR UPDATE`, takes one unit
  when `consumed < cap`, otherwise refuses with a `consumed` error (the
  caller defers the delivery to the next local day).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      %{consumed: consumed, cap: cap} = changeset.data

      if consumed < cap,
        do: Ash.Changeset.force_change_attribute(changeset, :consumed, consumed + 1),
        else:
          Ash.Changeset.add_error(changeset,
            field: :consumed,
            message: "the daily cap is reached"
          )
    end)
  end
end
