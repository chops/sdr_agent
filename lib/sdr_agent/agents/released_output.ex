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
  either), or a `:demo_exception` release while
  `SdrAgent.Agents.DemoException.use_authority/3` holds at the current
  instant, read under a process-bound
  `SdrAgent.Agents.Checks.DemoExceptionUse` registration; otherwise
  `{:error, :result_not_released}`. Generation-1 and
  Fake outputs are outside the gate and returned as stored. A read in no
  tenant, or of another tenant's invocation, is `{:error, :not_found}`.
  """

  require Ash.Query

  alias SdrAgent.Agents.Checks.DemoExceptionUse
  alias SdrAgent.Agents.Checks.ReleasedOutputRead
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock

  @doc "`{:ok, output}`, `{:error, :result_not_released}` or `{:error, :not_found}`."
  @spec fetch(struct() | Ecto.UUID.t(), term()) ::
          {:ok, term()} | {:error, :result_not_released | :not_found | term()}
  def fetch(%ModelInvocation{id: id}, actor), do: fetch(id, actor)

  def fetch(id, %{tenant_id: tenant_id} = actor) when is_binary(id) and is_binary(tenant_id) do
    id
    |> read(actor, ReleasedOutputRead.context())
    |> case do
      {:ok, %ModelInvocation{} = invocation} -> output(invocation, actor)
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  def fetch(_id, _actor), do: {:error, :not_found}

  @doc "Whether `invocation`'s output is behind the result gate (generation-2 ClaudeCLI)."
  @spec gated?(struct()) :: boolean()
  def gated?(%ModelInvocation{ledger_generation: 2, provider: :claude_cli}), do: true
  def gated?(%ModelInvocation{}), do: false

  defp read(id, %{tenant_id: tenant_id} = actor, context) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor, context: context)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one()
  end

  defp output(invocation, actor) do
    if gated?(invocation) do
      case release(invocation) do
        %ModelResultRelease{disposition: :released} ->
          visible(invocation)

        %ModelResultRelease{disposition: :demo_exception} = release ->
          demo(release, invocation, actor)

        _none_or_withheld ->
          {:error, :result_not_released}
      end
    else
      visible(invocation)
    end
  end

  defp visible(%ModelInvocation{parsed_output: %Ash.ForbiddenField{}}),
    do: {:error, :result_not_released}

  defp visible(invocation), do: {:ok, invocation.parsed_output}

  # C2* (OQ1; ADR-0005 item 9): present use authority first, then the
  # protected read under this process's registered use, removed on every
  # exit. No integrity-read or raw fallback.
  defp demo(release, invocation, actor) do
    with :ok <- DemoException.use_authority(release, invocation, Clock.utc_now()),
         {:ok, %ModelInvocation{} = used} <-
           DemoExceptionUse.with_use(invocation.tenant_id, invocation.id, fn ref ->
             read(
               invocation.id,
               actor,
               Map.merge(ReleasedOutputRead.context(), DemoExceptionUse.context(ref))
             )
           end) do
      visible(used)
    else
      _no_use -> {:error, :result_not_released}
    end
  end

  defp release(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
    )
    |> Ash.read_one!()
  end
end
