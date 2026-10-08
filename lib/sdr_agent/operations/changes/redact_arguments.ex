defmodule SdrAgent.Operations.Changes.RedactArguments do
  @moduledoc """
  Redacts free-text action arguments (`SdrAgent.Operations.Redactor`)
  before they reach any persistence — in particular the immutable AuditEvent
  `arguments` of `AppendEvent` (ADR-0001: never persist secret values; S13b
  review #31). List it before the changes that read the arguments.

  Option `:arguments` — the string arguments to redact.
  """
  use Ash.Resource.Change

  alias SdrAgent.Operations.Redactor

  @impl true
  def change(changeset, opts, _context) do
    Enum.reduce(opts[:arguments], changeset, fn name, acc ->
      case Ash.Changeset.get_argument(acc, name) do
        value when is_binary(value) ->
          Ash.Changeset.set_argument(acc, name, Redactor.redact(value))

        _ ->
          acc
      end
    end)
  end
end
