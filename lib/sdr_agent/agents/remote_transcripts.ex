defmodule SdrAgent.Agents.RemoteTranscripts do
  @moduledoc """
  Explicit hosted-owner diagnostic disclosure of a remote transcript.
  Metadata lists contain no bytes. A content read rechecks the live owner
  after the audit head lock, reads through an exact private Ash scope, and
  records AuditAccess with the actual User before its transaction commits.
  No business output is released or validated by this diagnostic path.

  Direct named-action reads cannot bypass access recording: only this
  module registers the process/transaction/actor/call-bound reader scope.
  Caller transactions are refused so bytes never leave before this API's
  own access transaction commits. No exception text or transcript is logged.
  """

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Agents.RemoteCallResult
    alias SdrAgent.Agents.RemoteModelCall
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Prototype.Checks.OperatorAction
    alias SdrAgent.Repo

    @registry {__MODULE__, :scope}
    @marker :sdr_hosted_transcript_scope

    @doc "Current-owner metadata for the requested run, never transcript content."
    def list(run_id, opts) do
      case Ecto.UUID.cast(run_id) do
        {:ok, id} ->
          RemoteModelCall
          |> Ash.Query.for_read(:owner_metadata, %{run_id: id}, actor: Keyword.get(opts, :actor))
          |> Ash.Query.sort(claim_deadline: :asc, id: :asc)
          |> Ash.read()

        _refused ->
          forbidden()
      end
    end

    @doc "One audited explicit read, returned only after its independent transaction commits."
    def read(call_id, opts) do
      actor = Keyword.get(opts, :actor)

      with false <- Repo.in_transaction?(),
           true <- owner?(actor),
           {:ok, id} <- Ecto.UUID.cast(call_id) do
        Audit.transaction(fn -> read_locked(id, actor) end)
      else
        _refused -> forbidden()
      end
    rescue
      _error -> {:error, :remote_transcript_unavailable}
    end

    defp read_locked(id, actor) do
      with {:ok, _head} <- Kernel.lock_head(actor.tenant_id),
           true <- owner?(actor) do
        with_scope(id, actor, &read_scoped(id, actor, &1))
      else
        {:error, error} -> Repo.rollback(error)
        _refused -> Repo.rollback(Ash.Error.Forbidden.exception([]))
      end
    end

    defp read_scoped(id, actor, context) do
      with {:ok, %RemoteCallResult{} = result} <- read_row(id, actor, context),
           true <- is_binary(result.transcript),
           {:ok, _access} <-
             Audit.record_access(
               :record_view,
               inspect(RemoteCallResult),
               id,
               "remote model transcript diagnostic",
               actor: actor
             ) do
        result
      else
        {:error, error} -> Repo.rollback(error)
        _refused -> Repo.rollback(Ash.Error.Forbidden.exception([]))
      end
    end

    defp read_row(id, actor, context) do
      RemoteCallResult
      |> Ash.Query.for_read(:owner_transcript, %{call_id: id}, actor: actor, context: context)
      |> Ash.read_one()
    end

    defp with_scope(id, actor, fun) do
      previous = Process.get(@registry)
      ref = make_ref()
      Process.put(@registry, %{ref: ref, actor: actor, call_id: id})

      try do
        fun.(%{@marker => ref})
      after
        if is_nil(previous), do: Process.delete(@registry), else: Process.put(@registry, previous)
      end
    end

    @doc "Whether this exact query carries the current private scope; this never creates a scope."
    def scoped?(
          actor,
          %Ash.Query{resource: RemoteCallResult, action: %{name: :owner_transcript}} = query
        ) do
      with %{ref: ref, actor: ^actor, call_id: id} <- Process.get(@registry),
           true <- is_reference(ref) and Repo.in_transaction?(),
           true <- Map.get(query.context, @marker) == ref,
           true <- Ash.Query.get_argument(query, :call_id) == id do
        owner?(actor)
      else
        _refused -> false
      end
    end

    def scoped?(_actor, _subject), do: false

    defp owner?(actor), do: OperatorAction.match?(actor, %{}, action: :transcript_read)
    defp forbidden, do: {:error, Ash.Error.Forbidden.exception([])}
  else
    @doc "No hosted diagnostic authority in an ordinary production build."
    def list(_run_id, _opts), do: {:error, Ash.Error.Forbidden.exception([])}

    @doc "No hosted diagnostic authority in an ordinary production build."
    def read(_call_id, _opts), do: {:error, Ash.Error.Forbidden.exception([])}

    @doc "No hosted transcript scope in an ordinary production build."
    def scoped?(_actor, _subject), do: false
  end
end
