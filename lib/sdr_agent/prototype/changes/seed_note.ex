defmodule SdrAgent.Prototype.Changes.SeedNote do
  @moduledoc """
  The provenance note of the D-237 seed revision
  (`SdrAgent.Agents.SettingsRevision :seed_prototype`; the seed design
  ruling b8d624fe D1(a), 969bf261): a closed, machine-built reference, not
  settings text. It is exactly

      "d237 seed provenance sha256:" <> 64 lowercase hex

  (92 bytes; no trimming, no other case, prefix, suffix, whitespace or
  control character), and it must name a Payload stored in the new row's
  own tenant. A 64-hex digest is secret-shaped under the shared settings
  text rule, so this one closed shape is handled here, action-locally; the
  shared `SdrAgent.Agents.Changes.SettingsRevisionChain`, `ContentRules` and
  the Redactor are unchanged, and `:create_revision`'s free-text note keeps
  its rule.

  Declared before the shared chain, it takes the `note` argument when the
  changeset is built and clears it, so the chain's note cast sees none;
  content still passes the chain's own rules exactly. A note of any other
  shape is a value-free error on `note`. The accepted value travels only in
  this change's own `before_action` closure (no context key or private
  argument a caller could supply). That hook, after authorization and inside
  the action's transaction, reads the Payload through the kernel, filtered
  by its sha256 AND the new row's tenant, and only then sets the `note`
  attribute to the original bytes; otherwise it adds a value-free error on
  `note`. A missing note is the action's required-argument error.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload

  @prefix "d237 seed provenance sha256:"
  @shape ~r/\Ad237 seed provenance sha256:([0-9a-f]{64})\z/
  @size byte_size(@prefix) + 64

  @doc "The fixed prefix of the reference."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @impl true
  def change(changeset, _opts, _context) do
    note = Ash.Changeset.get_argument(changeset, :note)
    changeset = Ash.Changeset.set_argument(changeset, :note, nil)

    case reference(note) do
      {:ok, sha256} -> Ash.Changeset.before_action(changeset, &bind(&1, note, sha256))
      :missing -> changeset
      :error -> refuse(changeset, "is not a seed provenance reference")
    end
  end

  defp reference(nil), do: :missing

  defp reference(note) when is_binary(note) and byte_size(note) == @size do
    case Regex.run(@shape, note, capture: :all_but_first) do
      [hex] -> {:ok, Base.decode16!(hex, case: :lower)}
      nil -> :error
    end
  end

  defp reference(_note), do: :error

  defp bind(changeset, note, sha256) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    if stored?(sha256, tenant_id),
      do: Ash.Changeset.force_change_attribute(changeset, :note, note),
      else: refuse(changeset, "does not name a provenance Payload of this tenant")
  end

  defp stored?(sha256, tenant_id) when is_binary(tenant_id) do
    Payload
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(sha256 == ^sha256 and tenant_id == ^tenant_id)
    |> Ash.Query.select([:sha256, :tenant_id])
    |> read_one()
    |> case do
      {:ok, %Payload{sha256: ^sha256, tenant_id: ^tenant_id}} -> true
      _none_or_error -> false
    end
  end

  defp stored?(_sha256, _tenant_id), do: false

  # Test-seam builds only: a read result a test put under
  # `{__MODULE__, :read_fault}` in the calling process replaces the read, so
  # no query runs (fault controls, Codex 3ad0a105). Other builds always read.
  if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
    defp read_one(query) do
      case Process.get({__MODULE__, :read_fault}) do
        nil -> Ash.read_one(query)
        fault -> fault
      end
    end
  else
    defp read_one(query), do: Ash.read_one(query)
  end

  defp refuse(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :note, message: message)
end
