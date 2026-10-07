defmodule SdrAgent.Operations.Changes.RedactFailure do
  @moduledoc """
  Failure create change: redacts `message` (`SdrAgent.Operations.Redactor`)
  and, when the `detail` argument is given, stores its redacted text in the
  Payload store through the kernel and sets `detail_sha256` — inside the
  create transaction.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Operations.Redactor

  @impl true
  def change(changeset, _opts, _context) do
    changeset =
      case Ash.Changeset.get_attribute(changeset, :message) do
        message when is_binary(message) ->
          Ash.Changeset.force_change_attribute(changeset, :message, Redactor.redact(message))

        _ ->
          changeset
      end

    case Ash.Changeset.get_argument(changeset, :detail) do
      detail when is_binary(detail) ->
        Ash.Changeset.before_action(changeset, &store_detail(&1, Redactor.redact(detail)))

      _ ->
        changeset
    end
  end

  defp store_detail(changeset, detail) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    Payload
    |> Ash.Changeset.for_create(
      :store,
      %{content: detail, content_type: "text/plain"},
      Kernel.opts(tenant_id)
    )
    |> Ash.create()
    |> case do
      {:ok, payload} ->
        Ash.Changeset.force_change_attribute(changeset, :detail_sha256, payload.sha256)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
