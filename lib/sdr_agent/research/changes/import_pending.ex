defmodule SdrAgent.Research.Changes.ImportPending do
  @moduledoc """
  The explicit pending refusal of the D-237 `:import` shells on
  `SdrAgent.Research.DossierEntry` and `SdrAgent.Research.DossierSource`
  (Codex d4196c02 ownership ruling): S1 declares the shell (name, an
  explicit empty accept list, the server-derived tenant, trace ids and the
  operator policy); S3 delivers the body (accepted inputs, arguments,
  validated changes, audit, replay and cap) in its own reviewed commits.

  Until S3 replaces this change, every `:import` is invalid, even for a
  valid operator: no row is ever written by the shell, and nothing relies on
  incidental missing fields to refuse.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :id,
      message: "the D-237 dossier import body is pending (S3)"
    )
  end
end
