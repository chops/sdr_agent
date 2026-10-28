defmodule SdrAgent.Prototype.BootCheck do
  @moduledoc """
  The one D-237 boot check (interfaces r6 IF-2; amendment item 2 "Boot"),
  used by every process kind: setup (after the phase-2 commit), the task
  entry (before any read and before Oban), and serve and every other start
  (as a supervision child after the Repo and before the model provider).

  | Switch | Binding | Witness store root | Result |
  |---|---|---|---|
  | off | absent | (ordinary rules) | ordinary runtime |
  | on | present and exact | unset | prototype runtime |
  | on | present and exact | set | refuse |
  | on | absent | any | refuse |
  | off | present | any | refuse |

  "Exact": the binding row exists exactly once; its instance and policy
  digest equal the switch and the compiled entry; the live database name,
  oid and `system_identifier` equal the row's; the suppression check is the
  Store implementation; the users are exactly the anchor plus at most the
  one bound auditor; no agent-environment (C2*) configuration is set.

  - `check/1` decides one switch value (`:off` or
    `%{policy_id: String.t(), instance_id: String.t()}`) and returns
    `{:ok, :ordinary}`, `{:ok, :prototype, SdrAgent.Prototype.Binding.t()}`
    or `{:error, code}` with a code of `reasons/0`;
  - `verify!/0` runs `check/1` on the configured switch and, on success,
    fixes `SdrAgent.Prototype.runtime/0` for the VM; on failure it raises
    `SdrAgent.Prototype.BootCheck.Refusal` carrying one fixed code;
  - `start_link/1` (the supervision child) runs `verify!/0` and returns
    `:ignore` on success or `{:error, code}`, which fails the start.

  `check/1`, `verify!/0`, `verify!/1` and `start_link/1` are supported only
  outside an already-open caller transaction (Codex 3f7d6c86). Task
  callers must use `SdrAgent.Prototype.Session.enter/1`; the supervision
  start and setup-after-phase-2-commit paths must likewise run top level.
  Direct calls inside a foreign transaction are unsupported: a failed
  data-layer read can roll back that caller's transaction by throw, rather
  than returning a boot code. These functions do not catch rollback throws
  or provide nested rollback isolation.

  The runtime is fixed ONCE (G1, Codex 23b4603a): unfixed, then `:ordinary`
  or `{:prototype, snapshot}`. An exact repeat of the fixed result is
  idempotent; ordinary → prototype, prototype → another prototype and an
  ordinary check after a prototype fix refuse `:binding_not_exact` and
  change nothing; an initial refusal fixes nothing
  (`SdrAgent.Prototype.Authority.fix_runtime/1`). In a test-seam build the
  fix is the calling process's seam state, and `verify!/0` reads the
  process's own boot-switch override (`TestSeam.put_boot_switch/1`) when
  set, else the configured switch; an explicit `switch:` wins. Real builds
  read `config :sdr_agent, SdrAgent.Prototype, switch:` only.

  In a build without the prototype authority (the production build) any
  switch other than `:off` is `:switch_outside_dev` before its shape is
  examined or the binding table is read (Codex 422c47dc R1); `:off` keeps
  the ordinary row and the binding refusal, and the runtime stays ordinary.
  """

  alias SdrAgent.Operations.PrototypeDatabaseBinding

  @doc "The closed set of boot refusal codes (`SdrAgent.Prototype.SafeLog.reasons(:boot)`)."
  @spec reasons() :: [atom()]
  def reasons, do: SdrAgent.Prototype.SafeLog.reasons(:boot) -- [:none]

  @doc "Decides one switch value; see the moduledoc."
  @spec check(term()) ::
          {:ok, :ordinary}
          | {:ok, :prototype, SdrAgent.Prototype.Binding.t()}
          | {:error, atom()}
  def check(switch) do
    with {:ok, switch} <- admit(switch),
         {:ok, rows} <- binding_rows() do
      decide(switch, rows)
    end
  end

  @doc "Runs the check on the configured switch and fixes the runtime, or raises one code."
  @spec verify!() :: :ok
  def verify!, do: verify!([])

  @doc "As `verify!/0`; `switch:` replaces the configured switch (the child and tests)."
  @spec verify!(keyword()) :: :ok
  def verify!(opts) when is_list(opts) do
    switch = Keyword.get_lazy(opts, :switch, &configured_switch/0)

    with {:ok, _} = result <- normalize(check(switch)),
         :ok <- fix(result) do
      :ok
    else
      {:error, code} -> raise SdrAgent.Prototype.BootCheck.Refusal, code: code
    end
  end

  @doc "The supervision child spec (see `start_link/1`)."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary, type: :worker}
  end

  @doc "Runs `verify!/1`; `:ignore` on success, `{:error, code}` on refusal."
  @spec start_link(term()) :: :ignore | {:error, atom()}
  def start_link(arg) do
    verify!(if Keyword.keyword?(arg), do: arg, else: [])
    :ignore
  rescue
    error in SdrAgent.Prototype.BootCheck.Refusal -> {:error, error.code}
  end

  # The boot check's own read of the binding rows (at most two), as the
  # audit kernel; a failed read is a closed refusal, never a dump.
  defp binding_rows do
    PrototypeDatabaseBinding
    |> Ash.Query.for_read(:read, %{}, SdrAgent.Audit.Kernel.opts())
    |> Ash.Query.limit(2)
    |> Ash.read()
    |> case do
      {:ok, rows} -> {:ok, rows}
      {:error, _error} -> {:error, :binding_not_exact}
    end
  rescue
    _error -> {:error, :binding_not_exact}
  end

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Prototype.Authority

    @policy_id "d237-prototype/1"
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    defp admit(:off), do: {:ok, :off}

    defp admit(%{policy_id: @policy_id, instance_id: instance_id} = switch)
         when map_size(switch) == 2 and is_binary(instance_id) do
      if Regex.match?(@uuid, instance_id), do: {:ok, switch}, else: {:error, :switch_invalid}
    end

    defp admit(_switch), do: {:error, :switch_invalid}

    defp decide(:off, []), do: {:ok, :ordinary}
    defp decide(:off, [_ | _]), do: {:error, :binding_without_switch}
    defp decide(_switch, []), do: {:error, :binding_absent}
    defp decide(switch, [row]), do: exact(switch, row)
    defp decide(_switch, _rows), do: {:error, :binding_not_exact}

    defp exact(switch, row) do
      with :ok <- expect(row.instance_id == switch.instance_id, :instance_mismatch),
           :ok <-
             expect(row.policy_entry_sha256 == Authority.policy_entry_sha256(), :policy_mismatch),
           :ok <- live(row),
           :ok <- expect(SdrAgent.Agents.Witness.store_root() == nil, :witness_store_configured),
           :ok <-
             expect(
               SdrAgent.SDR.SuppressionCheck.impl() == SdrAgent.SDR.SuppressionCheck.Store,
               :suppression_not_store
             ),
           :ok <-
             expect(
               Application.get_env(:sdr_agent, SdrAgent.AgentEnv) in [nil, []],
               :agent_env_configured
             ),
           :ok <- users_exact(row),
           {:ok, snapshot} <- Authority.snapshot(row) do
        {:ok, :prototype, snapshot}
      else
        {:error, :not_a_binding} -> {:error, :binding_not_exact}
        {:error, code} -> {:error, code}
      end
    end

    defp live(row) do
      case Authority.live_identity() do
        {:ok, live} ->
          expect(
            live == %{
              database: row.database,
              database_oid: row.database_oid,
              system_identifier: row.system_identifier
            },
            :database_mismatch
          )

        {:error, _unavailable} ->
          {:error, :live_identity_unavailable}
      end
    end

    # Exactly the credential-less active anchor plus, at most, the one bound
    # active auditor of the binding's tenant (G2), from one tenant-filtered
    # read; any other user, role, status or credential refuses.
    defp users_exact(row) do
      expected =
        Enum.sort([
          {row.operator_user_id, "agent_operator", "active", true}
          | if(row.auditor_user_id,
              do: [{row.auditor_user_id, "auditor", "active", false}],
              else: []
            )
        ])

      case SdrAgent.Repo.query(
             "SELECT id::text, role, status, hashed_password IS NULL FROM users WHERE tenant_id = $1",
             [Ecto.UUID.dump!(row.tenant_id)]
           ) do
        {:ok, %{rows: rows}} ->
          expect(Enum.sort(Enum.map(rows, &List.to_tuple/1)) == expected, :users_not_exact)

        {:error, _error} ->
          {:error, :users_not_exact}
      end
    rescue
      _error -> {:error, :users_not_exact}
    end

    defp normalize({:ok, :ordinary}), do: {:ok, :ordinary}
    defp normalize({:ok, :prototype, snapshot}), do: {:ok, {:prototype, snapshot}}
    defp normalize({:error, code}), do: {:error, code}

    defp expect(true, _code), do: :ok
    defp expect(_false, code), do: {:error, code}

    defp fix(result), do: Authority.fix_runtime(result)

    if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do
      # Test-seam build (Codex 026058ec): the process's own boot-switch
      # override when set, independent of the fixed runtime; else the
      # configured switch.
      defp configured_switch do
        case Authority.TestSeam.boot_switch() do
          nil -> app_switch()
          switch -> switch
        end
      end
    else
      defp configured_switch, do: app_switch()
    end
  else
    # The production build (Codex 422c47dc R1): any switch other than `:off`
    # is refused here, before its shape is examined or the binding table is
    # read, so a malformed, unbound or unreadable switch has the one code.
    defp admit(:off), do: {:ok, :off}
    defp admit(_switch), do: {:error, :switch_outside_dev}

    defp decide(:off, []), do: {:ok, :ordinary}
    defp decide(:off, [_ | _]), do: {:error, :binding_without_switch}

    defp normalize({:ok, :ordinary}), do: {:ok, :ordinary}
    defp normalize({:error, code}), do: {:error, code}
    defp fix({:ok, :ordinary}), do: :ok
    defp configured_switch, do: app_switch()
  end

  defp app_switch,
    do: Keyword.get(Application.get_env(:sdr_agent, SdrAgent.Prototype, []), :switch, :off)
end

defmodule SdrAgent.Prototype.BootCheck.Refusal do
  @moduledoc """
  Raised by `SdrAgent.Prototype.BootCheck.verify!/0` with one fixed boot
  refusal `code`; its message is `"prototype boot refused: <code>"` and holds
  no value.
  """
  defexception [:code]

  @impl true
  def message(%{code: code}), do: "prototype boot refused: #{code}"
end
