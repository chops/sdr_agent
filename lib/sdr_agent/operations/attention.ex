defmodule SdrAgent.Operations.Attention do
  @moduledoc """
  Same-transaction helpers for the S2 "Operator attention" convention, used
  from action hooks of the domains above Operations (Agents, Sales) and by
  the model-provider facade: open a Failure for the state change being
  written, or resolve the open/acknowledged Failures of a subject when its
  condition clears. They call the Failure actions directly (no guard), so
  they join the caller's transaction; the caller's actor must be allowed to
  run the Failure action (system actors open, ADM/REV/system actors
  resolve).
  """

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @doc "Opens a Failure (`SdrAgent.Operations.Failure` `:open` attributes) as `actor`."
  @spec open(map(), struct()) :: {:ok, Failure.t()} | {:error, term()}
  def open(attrs, actor) do
    Failure
    |> Ash.Changeset.for_create(:open, attrs, actor: actor)
    |> Ash.create()
  end

  @doc """
  Resolves every open or acknowledged Failure of `subject_resource` /
  `subject_id` in `tenant_id` with `note`, as `actor`. Returns the resolved
  Failures.
  """
  @spec resolve_subject(String.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), struct()) ::
          {:ok, [Failure.t()]} | {:error, term()}
  def resolve_subject(subject_resource, subject_id, tenant_id, note, actor) do
    Failure
    |> Ash.Query.for_read(:attention, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and subject_resource == ^subject_resource and
        subject_id == ^subject_id
    )
    |> Ash.read()
    |> case do
      {:ok, failures} -> resolve_all(failures, note, actor)
      error -> error
    end
  end

  defp resolve_all(failures, note, actor) do
    Enum.reduce_while(failures, {:ok, []}, fn failure, {:ok, acc} ->
      failure
      |> Ash.Changeset.for_update(:resolve, %{resolution_note: note}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
