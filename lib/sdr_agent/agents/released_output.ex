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

  **D-237 b2c β (amendment item 6; packet r1 section 3.6).** In prototype
  runtime, when the invocation's release is `released_unverified` (a kernel
  existence read), the output is read only under
  `SdrAgent.Prototype.ReleasedScope.run/3`, with ONLY that scope's context
  (`SdrAgent.Prototype.Checks.VerifiedReleasedRead` authorizes exactly
  that row): `{:ok, output}`, `{:error, :result_not_released}` for a
  forbidden field, or the scope's refusal (`:not_found`, `:not_released`,
  `:basis_invalid`, `:binding_mismatch`) or technical error unchanged.
  Ordinary runtime and every other disposition are unchanged, so outside
  prototype runtime a `released_unverified` output stays
  `{:error, :result_not_released}`. Compiled only with the prototype
  authority; the production build has the marked read only.
  """

  require Ash.Query

  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Agents.Checks.ReleasedOutputRead
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Audit.Kernel

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @doc """
  `{:ok, output}`, `{:error, :result_not_released}` or `{:error, :not_found}`.
  C2* operation snapshot entry `:released_output_fetch` (ADR-0005 C2* item
  2): nested under its callers it inherits.
  """
  @spec fetch(struct() | Ecto.UUID.t(), term()) ::
          {:ok, term()} | {:error, :result_not_released | :not_found | term()}
  def fetch(invocation, actor),
    do: OperationSnapshot.enter(:released_output_fetch, fn -> read(invocation, actor) end)

  defp read(%ModelInvocation{id: id}, actor), do: read(id, actor)

  if @prototype_compiled do
    defp read(id, %{tenant_id: tenant_id} = actor) when is_binary(id) and is_binary(tenant_id) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: prototype_read(id, actor),
        else: marked_read(id, actor)
    end
  else
    defp read(id, %{tenant_id: tenant_id} = actor) when is_binary(id) and is_binary(tenant_id),
      do: marked_read(id, actor)
  end

  defp read(_id, _actor), do: {:error, :not_found}

  if @prototype_compiled do
    # D-237 b2c β: a released_unverified output only through the verified
    # scope; anything else through the marked read.
    defp prototype_read(id, actor) do
      case unverified_release(id, actor.tenant_id) do
        {:ok, true} -> verified_read(id, actor)
        {:ok, false} -> marked_read(id, actor)
        {:error, error} -> {:error, error}
      end
    end

    defp unverified_release(id, tenant_id) do
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^tenant_id and model_invocation_id == ^id and
          disposition == :released_unverified
      )
      |> Ash.exists()
    end

    defp verified_read(id, actor) do
      case SdrAgent.Prototype.ReleasedScope.run(id, actor, &scoped_output(id, actor, &1)) do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end

    # ONLY the scope's context: the Boolean marker is neither needed nor
    # sufficient for a released_unverified row.
    defp scoped_output(id, %{tenant_id: tenant_id} = actor, scope) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{},
        actor: actor,
        context: SdrAgent.Prototype.ReleasedScope.context(scope)
      )
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.read_one()
      |> case do
        {:ok, %ModelInvocation{parsed_output: %Ash.ForbiddenField{}}} ->
          {:error, :result_not_released}

        {:ok, %ModelInvocation{parsed_output: output}} ->
          {:ok, output}

        {:ok, nil} ->
          {:error, :not_found}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp marked_read(id, %{tenant_id: tenant_id} = actor) do
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
