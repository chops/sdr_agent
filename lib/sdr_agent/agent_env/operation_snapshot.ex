defmodule SdrAgent.AgentEnv.OperationSnapshot do
  @moduledoc """
  The operation snapshot (ADR-0005 C2* amendment item 2 and its addendum 1,
  D-227; plan `claude-c2star-s1-environment-plan-r2.md` sections 4.3 and
  5.2): one observation of the agent environment's lease,
  `environment.json` and `authorization.json`, owned by the outermost
  logical operation of a process and inherited by every entry nested in it.

  `enter/2` wraps each entry in `entries/0` (a closed set; another atom
  raises `ArgumentError`):

  | Mode | Active snapshot here | Transaction open | Effect |
  |---|---|---|---|
  | `:none` | — | — | `fun.()`; nothing observed or emitted |
  | `:run` | yes | any | inherit: `fun.()`; never replaced or invalidated |
  | `:run` | no | no | own: observe, register, run, then unregister and invalidate (on return or raise) |
  | `:run` | no | yes | refuse: `fun.()` with nothing registered; nothing observed (no file I/O under locks) |
  | `:check`, `:bootstrap`, `:provisioning` | — | — | raise `SdrAgent.AgentEnv.ModeRefusedError` before `fun` |

  A snapshot belongs to one process (its registration is in the process
  dictionary). Its `generation` is strictly increasing within the VM;
  `observed_at` is `SdrAgent.Clock.utc_now/0`. Observation never raises: an
  unreadable or invalid file is an `{:invalid, reason}` view.

  Consumers (S2-S4) read `current/0` (`:inert` first), re-validate a bound
  snapshot with `verify/1` (a pure comparison with this process's active
  registration: a caller-built or completed snapshot never verifies) and
  read its facts with `valid?/1`, `check_lease/1`, `environment/1` and
  `authorization/1`, all pure. None of them observes files or calls
  `enter/2`; this module owns every wrap (R1). In S1 nothing consults a
  snapshot, so no outcome changes.

  Validity: the lease's mode and nonce equal the configuration's and its
  target is the environment's digest; the environment names the configured
  database; `valid?/1` also needs mode `:run`. An authorization is valid
  when the environment is and its `binding_sha256` is the environment's
  digest. `sha256` is `authorization.json`'s file digest and
  `authorization_sha256` the registry-entry digest it records (R3 (a)).

  Telemetry (metadata only, no file content): the
  `[:sdr_agent, :agent_env, :snapshot, :observe]` span (start `%{entry,
  in_transaction?}`, stop `%{entry, generation}`), and
  `[:sdr_agent, :agent_env, :snapshot, :inherit | :invalidate]` (`%{entry,
  generation}`) and `[…, :refuse]` (`%{entry}`).
  """

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.ModeRefusedError
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Clock
  alias SdrAgent.Repo

  @entries [
    :sdr_action,
    :perform_score_lead,
    :perform_build_evidence_bundle,
    :perform_draft_email,
    :perform_classify_reply,
    :perform_hand_off_proposal,
    :model_provider_complete,
    :reserve_model_invocation,
    :admit_launch,
    :result_gate,
    :result_gate_recovery,
    :released_output,
    :released_output_fetch,
    :decision_rules,
    :sdr_proposal,
    :edit_draft,
    :approve,
    :inbox_command,
    :delivery_attempt,
    :capture_deliver,
    :record_receipt,
    :agent_finish,
    :stale_run_recover
  ]
  @active {__MODULE__, :active}
  @observe [:sdr_agent, :agent_env, :snapshot, :observe]
  @inherit [:sdr_agent, :agent_env, :snapshot, :inherit]
  @refuse [:sdr_agent, :agent_env, :snapshot, :refuse]
  @invalidate [:sdr_agent, :agent_env, :snapshot, :invalidate]

  @enforce_keys [:ref, :owner, :generation, :observed_at, :lease, :environment, :authorization]
  defstruct @enforce_keys

  @type entry ::
          :sdr_action
          | :perform_score_lead
          | :perform_build_evidence_bundle
          | :perform_draft_email
          | :perform_classify_reply
          | :perform_hand_off_proposal
          | :model_provider_complete
          | :reserve_model_invocation
          | :admit_launch
          | :result_gate
          | :result_gate_recovery
          | :released_output
          | :released_output_fetch
          | :decision_rules
          | :sdr_proposal
          | :edit_draft
          | :approve
          | :inbox_command
          | :delivery_attempt
          | :capture_deliver
          | :record_receipt
          | :agent_finish
          | :stale_run_recover
  @type view(data) :: {:valid, sha256 :: String.t(), data} | :absent | {:invalid, atom()}
  @type t :: %__MODULE__{
          ref: reference(),
          owner: pid(),
          generation: pos_integer(),
          observed_at: DateTime.t(),
          lease: view(map()),
          environment: view(map()),
          authorization: view(map())
        }

  @doc "The closed set of entry atoms."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Runs `fun` as operation snapshot entry `entry` (see the moduledoc)."
  @spec enter(entry(), (-> result)) :: result when result: var
  def enter(entry, fun) when entry in @entries and is_function(fun, 0) do
    case AgentEnv.mode() do
      :none -> fun.()
      :run -> apply_rule(entry, fun)
      mode -> raise ModeRefusedError, mode: mode, entry: entry
    end
  end

  def enter(entry, _fun),
    do: raise(ArgumentError, "not an operation snapshot entry: #{inspect(entry)}")

  defp apply_rule(entry, fun) do
    case Process.get(@active) do
      %__MODULE__{generation: generation} ->
        :telemetry.execute(@inherit, %{}, %{entry: entry, generation: generation})
        fun.()

      _none ->
        if in_transaction?(), do: refuse(entry, fun), else: own(entry, fun)
    end
  end

  defp refuse(entry, fun) do
    :telemetry.execute(@refuse, %{}, %{entry: entry})
    fun.()
  end

  defp own(entry, fun) do
    snapshot = observe(entry)
    Process.put(@active, snapshot)

    try do
      fun.()
    after
      unregister(snapshot)
      :telemetry.execute(@invalidate, %{}, %{entry: entry, generation: snapshot.generation})
    end
  end

  defp unregister(%__MODULE__{ref: ref}) do
    if match?(%__MODULE__{ref: ^ref}, Process.get(@active)), do: Process.delete(@active)
    :ok
  end

  # An unknown transaction state counts as open: refuse, never observe.
  defp in_transaction? do
    Repo.in_transaction?()
  rescue
    _error -> true
  end

  defp observe(entry) do
    :telemetry.span(@observe, %{entry: entry, in_transaction?: false}, fn ->
      snapshot = sample()
      {snapshot, %{entry: entry, generation: snapshot.generation}}
    end)
  end

  defp sample do
    {lease, environment, authorization} = views()

    %__MODULE__{
      ref: make_ref(),
      owner: self(),
      generation: System.unique_integer([:monotonic, :positive]),
      observed_at: Clock.utc_now(),
      lease: lease,
      environment: environment,
      authorization: authorization
    }
  end

  defp views do
    case State.root() do
      {:ok, root} ->
        {State.read(root, :lease), State.read(root, :environment),
         State.read(root, :authorization)}

      {:error, reason} ->
        {{:invalid, reason}, {:invalid, reason}, {:invalid, reason}}
    end
  end

  @doc """
  This process's active snapshot: `{:ok, snapshot}`; `:inert` when no
  agent environment is configured; otherwise `{:error, :snapshot_not_in_use}`.
  """
  @spec current() :: {:ok, t()} | :inert | {:error, :snapshot_not_in_use}
  def current do
    case AgentEnv.mode() do
      :none -> :inert
      _mode -> active()
    end
  end

  defp active do
    case Process.get(@active) do
      %__MODULE__{} = snapshot -> {:ok, snapshot}
      _none -> {:error, :snapshot_not_in_use}
    end
  end

  @doc """
  `{:ok, snapshot}` only when `term` is exactly this process's active
  registration; anything else (a completed, forged or other-process
  snapshot) is `{:error, :snapshot_not_in_use}`.
  """
  @spec verify(term()) :: {:ok, t()} | {:error, :snapshot_not_in_use}
  def verify(%__MODULE__{} = snapshot) do
    case Process.get(@active) do
      %__MODULE__{} = active when active == snapshot -> {:ok, active}
      _other -> {:error, :snapshot_not_in_use}
    end
  end

  def verify(_term), do: {:error, :snapshot_not_in_use}

  @doc "Whether `snapshot`'s lease and environment are valid in run mode."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = snapshot),
    do: AgentEnv.mode() == :run and lease_valid?(snapshot) and environment_valid?(snapshot)

  def valid?(_term), do: false

  @doc "`:ok` when `snapshot`'s lease is valid for this boot's mode, nonce and environment."
  @spec check_lease(t()) :: :ok | {:error, :agent_env_lease_mismatch}
  def check_lease(%__MODULE__{} = snapshot) do
    if lease_valid?(snapshot), do: :ok, else: {:error, :agent_env_lease_mismatch}
  end

  def check_lease(_term), do: {:error, :agent_env_lease_mismatch}

  @doc "The bound environment of a valid `snapshot`, or `{:error, :environment_unattested}`."
  @spec environment(t()) ::
          {:ok,
           %{
             binding_sha256: String.t(),
             database: String.t(),
             database_oid: pos_integer(),
             tenant_id: String.t(),
             nonce: String.t(),
             created_at: String.t()
           }}
          | {:error, :environment_unattested}
  def environment(%__MODULE__{environment: {:valid, binding, data}} = snapshot) do
    if valid?(snapshot) do
      {:ok,
       %{
         binding_sha256: binding,
         database: data["database"],
         database_oid: data["database_oid"],
         tenant_id: data["tenant_id"],
         nonce: data["nonce"],
         created_at: data["created_at"]
       }}
    else
      {:error, :environment_unattested}
    end
  end

  def environment(_term), do: {:error, :environment_unattested}

  @doc """
  `snapshot`'s authorization binding: `sha256` is `authorization.json`'s file
  digest and `authorization_sha256` the registry-entry digest it records.
  """
  @spec authorization(t()) ::
          {:ok,
           %{
             sha256: String.t(),
             authorization_sha256: String.t(),
             authorization_id: String.t(),
             binding_sha256: String.t(),
             grant_id: String.t(),
             revision: 1,
             event_id: String.t(),
             nonce: String.t()
           }}
          | {:error, :authorization_absent | :authorization_invalid}
  def authorization(%__MODULE__{authorization: :absent}), do: {:error, :authorization_absent}

  def authorization(
        %__MODULE__{authorization: {:valid, sha256, data}, environment: {:valid, binding, _}} =
          snapshot
      ) do
    if environment_valid?(snapshot) and data["binding_sha256"] == binding do
      {:ok,
       %{
         sha256: sha256,
         authorization_sha256: data["authorization_sha256"],
         authorization_id: data["authorization_id"],
         binding_sha256: data["binding_sha256"],
         grant_id: data["grant_id"],
         revision: data["revision"],
         event_id: data["event_id"],
         nonce: data["nonce"]
       }}
    else
      {:error, :authorization_invalid}
    end
  end

  def authorization(_term), do: {:error, :authorization_invalid}

  defp lease_valid?(%__MODULE__{
         lease: {:valid, _sha256, lease},
         environment: {:valid, binding, _}
       }) do
    config = AgentEnv.config()

    lease["mode"] == Atom.to_string(AgentEnv.mode()) and
      lease["nonce"] == Keyword.get(config, :nonce) and
      lease["target"] == %{"binding_sha256" => binding}
  end

  defp lease_valid?(_snapshot), do: false

  defp environment_valid?(%__MODULE__{environment: environment}) do
    database = Keyword.get(AgentEnv.config(), :database)
    is_binary(database) and match?({:valid, _binding, %{"database" => ^database}}, environment)
  end
end
