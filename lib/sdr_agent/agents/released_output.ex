defmodule SdrAgent.Agents.ReleasedOutput do
  @moduledoc """
  The released-output read (R0-07 REQ-07-5; ADR-0005 R0 amendment item 4,
  "No bypass"): the only business read of a model output, behind
  `SdrAgent.Agents.released_output/2` and the output consumers (decisions,
  reply assessments, the OutreachProposal replay).

  `fetch/2` re-reads the invocation by id in the actor's tenant, as the
  actor, with the `SdrAgent.Agents.Checks.ReleasedOutputRead` mark. A
  generation-2 ClaudeCLI output is returned only when the invocation has a
  `:released` `SdrAgent.Agents.ModelResultRelease` (checked explicitly, so a
  witness-seam actor that may read the raw field gets no business output
  either); otherwise `{:error, :result_not_released}`. Generation-1 and
  Fake outputs are outside the gate and returned as stored. A read in no
  tenant, or of another tenant's invocation, is `{:error, :not_found}`.
  """

  require Ash.Query

  alias SdrAgent.Agents.Checks.ReleasedOutputRead
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Audit.Kernel

  @doc "`{:ok, output}`, `{:error, :result_not_released}` or `{:error, :not_found}`."
  @spec fetch(struct() | Ecto.UUID.t(), term()) ::
          {:ok, term()} | {:error, :result_not_released | :not_found | term()}
  def fetch(%ModelInvocation{id: id}, actor), do: fetch(id, actor)

  def fetch(id, %{tenant_id: tenant_id} = actor) when is_binary(id) and is_binary(tenant_id) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor, context: ReleasedOutputRead.context())
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelInvocation{} = invocation} -> output(invocation)
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  def fetch(_id, _actor), do: {:error, :not_found}

  @doc "Whether `invocation`'s output is behind the result gate (generation-2 ClaudeCLI)."
  @spec gated?(struct()) :: boolean()
  def gated?(%ModelInvocation{ledger_generation: 2, provider: :claude_cli}), do: true
  def gated?(%ModelInvocation{}), do: false

  defp output(%ModelInvocation{parsed_output: %Ash.ForbiddenField{}}),
    do: {:error, :result_not_released}

  defp output(invocation) do
    if gated?(invocation) and not released?(invocation),
      do: {:error, :result_not_released},
      else: {:ok, invocation.parsed_output}
  end

  defp released?(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        disposition == :released
    )
    |> Ash.exists?()
  end
end
