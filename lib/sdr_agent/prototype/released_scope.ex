# D-237: the verified released-output read scope exists only in builds that
# set `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs
# and config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ReleasedScope do
    @moduledoc """
    The verified read scope of a `released_unverified` output (ADR-0005
    D-237 amendment item 6; mechanism note r3 section A; b2c β packet r1
    sections 3.1-3.3 and delta r2 section 1; Codex 3122b0d4, be36b5df).

    `run/3` is the only way to read such an output: it checks, in order,
    and only then registers a scope and runs the given function with it.

      1. One raw state probe of the current transaction
         (`SdrAgent.Prototype.Admission.state_probe/0`, `SELECT 1`). Its
         typed error is returned at once: no further statement, no
         function call, no scope (an aborted owner then rolls back).
      2. The invocation, read AS THE CALLER (its row policy) with
         `tenant_id == actor.tenant_id`; absent is `{:error, :not_found}`.
      3. The release row (kernel, tenant-filtered): exactly this
         invocation's `released_unverified` release, else
         `{:error, :not_released}`.
      4. The ORIGINAL event (`original_basis/2`): every
         `model.result.released_unverified` event of the tenant whose
         subject is the release OR whose invocation is this one, read with
         no other filter; exactly one, with the release's subject resource,
         subject, action `"decide"`, invocation, run and tenant, and
         arguments with exactly the keys `basis` and `basis_sha256`.
      5. The stored run and the one original reservation event's recorded
         authority (`SdrAgent.Prototype.Admission.recorded/1`).
      6. `SdrAgent.Prototype.Basis.verify_historical/2`: the original basis
         against those stored facts only. Never the current grant,
         revision, status, funding, window or policy configuration.
      7. Current use: prototype runtime, `SdrAgent.Prototype.check_live/0`
         and the live boot snapshot's prototype section equal to the
         basis's; otherwise `{:error, :binding_mismatch}` (after one state
         probe, so an aborted transaction keeps its own typed error).
      8. Registration: a transaction-local marker is set and the
         transaction id read; only after both succeed is the scope put in
         this process's registry. `fun.(scope)` then runs and `run/3`
         returns `{:ok, result}`; `after` removes only that scope's own
         entry (return, raise, throw or exit). A raise re-raises.

    Any other result of steps 2-6 is `{:error, :basis_invalid}`, and a
    technical read error is returned with its identity (an `Ash.read!`
    raise in the recorded-authority read propagates). Refusals are
    returned WITHOUT `Repo.rollback`: a caller's transaction and its work
    continue. Inside a caller's transaction `run/3` runs inline (no nested
    transaction, no savepoint); otherwise it opens one
    `SdrAgent.Audit.transaction/1`.

    **The single historical trust owner (B1; β delta r2 section 1; Codex
    be36b5df).** Steps 4-6 are `original_basis/2`: it returns only a FULLY
    historically verified original, and both consumers use it, `run/3`
    (then current use and registration) and the raw existing-release
    decision (`SdrAgent.Agents.Changes.ReleaseDecision`, which then only
    compares the requested basis with it). An invalid original is never a
    replay or a `ReleaseConflict` there.

    `verify/1` accepts a scope only in its own process, while registered,
    when it equals the registered one, inside a transaction whose id and
    marker are the registered ones; a plain map, a forged, copied, stale or
    another process's struct is refused before any SQL. `context/1` is the
    query context that carries a scope to
    `SdrAgent.Prototype.Checks.VerifiedReleasedRead`. Like
    `SdrAgent.Agents.ReleaseDecision.Prelocked`, this is a trusted
    in-process convention, not a capability against server code.

    Consumers (pinned by `ReleaseGuardTest` and the β partition probe):
    `run/3` only by `SdrAgent.Agents.ReleasedOutput` and, for the worker
    predicates (D-237 b2d, a function that reads nothing),
    `SdrAgent.Agents.ResultGate`; `original_basis/2` only by
    `SdrAgent.Agents.Changes.ReleaseDecision`.
    """

    require Ash.Query

    alias SdrAgent.Agents.AgentRun
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ModelResultRelease
    alias SdrAgent.Audit
    alias SdrAgent.Audit.AuditEvent
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.Admission
    alias SdrAgent.Prototype.Basis
    alias SdrAgent.Repo

    @enforce_keys [
      :tenant_id,
      :model_invocation_id,
      :release_id,
      :basis_sha256,
      :ref,
      :xact_id,
      :savepoint_marker
    ]
    defstruct @enforce_keys

    @registry {__MODULE__, :registry}
    @event_type "model.result.released_unverified"
    @subject "SdrAgent.Agents.ModelResultRelease"
    @argument_keys ["basis", "basis_sha256"]

    @type t :: %__MODULE__{
            tenant_id: Ecto.UUID.t(),
            model_invocation_id: Ecto.UUID.t(),
            release_id: Ecto.UUID.t(),
            basis_sha256: String.t(),
            ref: reference(),
            xact_id: String.t(),
            savepoint_marker: String.t()
          }

    @typedoc "An original basis and its digest, as recorded by the event."
    @type original :: %{basis: term(), basis_sha256: term()}

    @doc """
    Checks `invocation` (a struct or id) for `actor` as described in the
    moduledoc, then runs `fun.(scope)`: `{:ok, fun_result}`,
    `{:error, :not_found | :not_released | :basis_invalid | :binding_mismatch}`,
    or a technical error with its identity.
    """
    @spec run(struct() | Ecto.UUID.t(), term(), (t() -> result)) ::
            {:ok, result}
            | {:error, :not_found | :not_released | :basis_invalid | :binding_mismatch}
            | {:error, term()}
          when result: term()
    def run(invocation, actor, fun) when is_function(fun, 1) do
      if Repo.in_transaction?(),
        do: scoped(invocation, actor, fun),
        else: owned(invocation, actor, fun)
    end

    @doc """
    The ORIGINAL arguments of `release`'s one
    `model.result.released_unverified` event, FULLY historically verified
    (moduledoc steps 4-6): the event's identity, then the stored run, the
    one original reservation authority and
    `SdrAgent.Prototype.Basis.verify_historical/2`; never the current grant,
    revision, status, funding, window or `verify_new/2`.
    `{:ok, %{basis:, basis_sha256:}}`, `{:error, :basis_invalid}`, or a read
    error with its identity.
    """
    @spec original_basis(struct(), struct()) ::
            {:ok, original()} | {:error, :basis_invalid} | {:error, term()}
    def original_basis(release, invocation) do
      with {:ok, events} <- candidates(release, invocation),
           {:ok, original} <- original(events, release, invocation),
           {:ok, run} <- stored_run(invocation),
           {:ok, recorded} <- recorded(invocation),
           :ok <- historical(original, release, invocation, run, recorded) do
        {:ok, original}
      end
    end

    @doc "The query context that carries `scope` to the field policy."
    @spec context(t()) :: %{sdr_prototype_released_scope: t()}
    def context(%__MODULE__{} = scope), do: %{sdr_prototype_released_scope: scope}

    @doc """
    The registered scope `scope` stands for, used in its own process and
    transaction, while registered, with every field unchanged:
    `{:ok, registered}`, otherwise `{:error, :scope_invalid}`. Read-only:
    nothing is consumed or changed.
    """
    @spec verify(term()) :: {:ok, t()} | {:error, :scope_invalid}
    def verify(%__MODULE__{ref: ref} = scope) when is_reference(ref) do
      with %__MODULE__{} = registered <- Map.get(registry(), ref),
           true <- registered == scope,
           true <- Repo.in_transaction?(),
           {:ok, state} <- transaction_state(registered.savepoint_marker),
           true <- state == {registered.xact_id, "1"} do
        {:ok, registered}
      else
        _refused -> {:error, :scope_invalid}
      end
    end

    def verify(_scope), do: {:error, :scope_invalid}

    ## run/3

    # At top level: one owning transaction (a refusal commits nothing).
    defp owned(invocation, actor, fun) do
      case Audit.transaction(fn -> scoped(invocation, actor, fun) end) do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end

    defp scoped(invocation, actor, fun) do
      with {:ok, invocation, release, original} <- checked(invocation, actor) do
        register_and_run(invocation, release, original, fun)
      end
    end

    # run/3's checks, in order; a scope is registered only after all pass.
    defp checked(invocation_or_id, actor) do
      with :ok <- probe(),
           {:ok, invocation} <- caller_invocation(invocation_or_id, actor),
           {:ok, release} <- released_row(invocation),
           {:ok, original} <- original_basis(release, invocation),
           :ok <- current_use(original) do
        {:ok, invocation, release, original}
      end
    end

    defp probe, do: Admission.state_probe()

    defp caller_invocation(%ModelInvocation{id: id}, actor), do: caller_invocation(id, actor)

    defp caller_invocation(id, %{tenant_id: tenant_id} = actor)
         when is_binary(id) and is_binary(tenant_id) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.read_one()
      |> case do
        {:ok, %ModelInvocation{} = invocation} -> {:ok, invocation}
        {:ok, nil} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end

    defp caller_invocation(_invocation, _actor), do: {:error, :not_found}

    defp released_row(invocation) do
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
      )
      |> Ash.read_one()
      |> case do
        {:ok, %ModelResultRelease{disposition: :released_unverified} = release} -> {:ok, release}
        {:ok, _none_or_other} -> {:error, :not_released}
        {:error, error} -> {:error, error}
      end
    end

    # Every candidate original of the tenant, by the release OR the
    # invocation, with no other filter: competing or malformed candidates
    # are never silently dropped.
    defp candidates(release, invocation) do
      event_type = @event_type
      release_id = release.id
      invocation_id = invocation.id

      AuditEvent
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(release.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^release.tenant_id and event_type == ^event_type and
          (subject_id == ^release_id or model_invocation_id == ^invocation_id)
      )
      |> Ash.read()
    end

    defp original([event], release, invocation) do
      if original_event?(event, release, invocation),
        do: arguments(event),
        else: {:error, :basis_invalid}
    end

    defp original(_none_or_several, _release, _invocation), do: {:error, :basis_invalid}

    defp original_event?(event, release, invocation) do
      event.subject_resource == @subject and event.subject_id == release.id and
        event.action == "decide" and event.model_invocation_id == invocation.id and
        event.agent_run_id == invocation.agent_run_id and event.tenant_id == release.tenant_id and
        release.tenant_id == invocation.tenant_id and release.model_invocation_id == invocation.id
    end

    defp arguments(%{payload: %{"arguments" => %{} = arguments}}) do
      if Enum.sort(Map.keys(arguments)) == @argument_keys,
        do: {:ok, %{basis: arguments["basis"], basis_sha256: arguments["basis_sha256"]}},
        else: {:error, :basis_invalid}
    end

    defp arguments(_event), do: {:error, :basis_invalid}

    defp stored_run(invocation) do
      AgentRun
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(id == ^invocation.agent_run_id and tenant_id == ^invocation.tenant_id)
      |> Ash.read_one()
      |> case do
        {:ok, %AgentRun{} = run} -> {:ok, run}
        {:ok, nil} -> {:error, :basis_invalid}
        {:error, error} -> {:error, error}
      end
    end

    # The one original reservation event's authority; a missing, duplicated
    # or malformed record is an invalid original.
    defp recorded(invocation) do
      case Admission.recorded(invocation) do
        {:ok, %{} = recorded} -> {:ok, recorded}
        {:error, _reason, :authority_unrecorded} -> {:error, :basis_invalid}
      end
    end

    defp historical(original, release, invocation, run, recorded) do
      Basis.verify_historical(original, %{
        release: release,
        invocation: invocation,
        run: run,
        recorded: recorded
      })
    end

    # Current use, separate from historical truth: prototype runtime, the
    # live binding, and the live boot snapshot's prototype section equal to
    # the basis's. A mismatch first passes one state probe, so a live read
    # that aborted the transaction is returned as its own typed error, never
    # relabelled a refusal.
    defp current_use(%{basis: basis}) do
      if live?(basis) do
        :ok
      else
        with :ok <- probe(), do: {:error, :binding_mismatch}
      end
    end

    defp live?(%{"prototype" => prototype}) do
      with :prototype <- Prototype.runtime(),
           :ok <- Prototype.check_live(),
           {:ok, binding} <- Prototype.binding() do
        prototype == prototype_section(binding)
      else
        _not_live -> false
      end
    end

    # The basis's prototype section as `SdrAgent.Prototype.Basis` builds it
    # from the boot snapshot.
    defp prototype_section(binding) do
      %{
        "binding_id" => binding.id,
        "instance_id" => binding.instance_id,
        "tenant_id" => binding.tenant_id,
        "dataset_class" => binding.dataset_class,
        "database" => binding.database,
        "database_oid" => binding.database_oid,
        "system_identifier" => decimal(binding.system_identifier)
      }
    end

    defp decimal(value) when is_integer(value), do: Integer.to_string(value)
    defp decimal(_other), do: nil

    ## The registry

    defp register_and_run(invocation, release, original, fun) do
      marker =
        "sdr_released_scope.c" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      with {:ok, _set} <- Repo.query("SELECT set_config($1, '1', true)", [marker]),
           {:ok, {xact_id, "1"}} <- transaction_state(marker) do
        scope = %__MODULE__{
          tenant_id: invocation.tenant_id,
          model_invocation_id: invocation.id,
          release_id: release.id,
          basis_sha256: original.basis_sha256,
          ref: make_ref(),
          xact_id: xact_id,
          savepoint_marker: marker
        }

        register(scope)

        try do
          {:ok, fun.(scope)}
        after
          unregister(scope.ref)
        end
      else
        {:error, error} -> {:error, error}
        {:ok, _unset} -> {:error, :scope_invalid}
      end
    end

    # The current transaction id and the marker's value, in one query (no
    # lock clause); a query error is returned as it is.
    defp transaction_state(marker) do
      case Repo.query("SELECT pg_current_xact_id()::text, current_setting($1, true)", [marker]) do
        {:ok, %{rows: [[xact_id, value]]}} -> {:ok, {xact_id, value}}
        {:ok, _unexpected} -> {:error, :scope_invalid}
        {:error, error} -> {:error, error}
      end
    end

    defp registry, do: Process.get(@registry, %{})

    defp register(scope), do: Process.put(@registry, Map.put(registry(), scope.ref, scope))

    defp unregister(ref) do
      case Map.delete(registry(), ref) do
        empty when empty == %{} -> Process.delete(@registry)
        rest -> Process.put(@registry, rest)
      end
    end
  end
end
