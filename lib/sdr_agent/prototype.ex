defmodule SdrAgent.Prototype do
  @moduledoc """
  The D-237 local prototype facade (ADR-0005 D-237 amendment; interfaces r6
  IF-1). It is present in every build; every other slice reaches the
  prototype authority only through it.

  - `runtime/0` is `:ordinary` or `:prototype`, fixed once per VM by
    `SdrAgent.Prototype.BootCheck.verify!/0` (IF-2). A production build is
    always `:ordinary`.
  - `binding/0` returns the boot snapshot (`SdrAgent.Prototype.Binding`);
    `check_live/0` re-reads the singleton binding row and the live database
    identity and compares every field with that snapshot.
  - `operator_actor/1` is the authoritative operator resolver: it runs on
    every call, caches nothing, and never accepts an `SdrAgent.Actor`
    struct as proof. `operator?/1` is true only when it resolves the
    actor's id and the actor's tenant matches.
  - `enter_session/2` creates (or replays) the acting agent session's
    `PrototypeDelegation`, from the boot snapshot only.
  - `label/0` is the constant `"UNVERIFIED (PROTOTYPE)"` in every build;
    `assurance/0`, `policy_entry/0` and `funding_entry/0` return the IF-5
    block and the compiled `d237-prototype/1` and `d237-funding/1`
    entries.

  Every function other than `runtime/0`, `label/0` and `operator?/1`
  returns `{:error, :not_prototype_runtime}` outside prototype runtime, and
  callers handle it. `check_fence/0` (S-B1, ADR-0024 decision 1), the
  identity-scoped relocation fence every audit append re-checks after the
  chain-head lock, is `:ok` outside prototype runtime and in a build
  without the authority.

  In a build with the authority (`:prototype_authority_compiled`, set only
  by config/dev.exs and config/test.exs) the facade reads
  `SdrAgent.Prototype.Authority`. Otherwise (the production build) it holds
  refusal stubs only and references no authority module: `runtime/0` is
  `:ordinary`, `operator?/1` is `false`, and every other function but
  `label/0` returns `{:error, :not_prototype_runtime}`.

  Stage (D-237 S1): `runtime/0`, `binding/0`, `label/0` and the
  ordinary-runtime refusals (B1a), `check_live/0`, `operator_actor/1` and
  `operator?/1` (B2b), and `policy_entry/0`, `funding_entry/0` and
  `assurance/0` are implemented. In prototype runtime `enter_session/2`
  still returns `{:error, :not_implemented}`.
  """

  alias SdrAgent.Prototype.Binding

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)
  @label "UNVERIFIED (PROTOTYPE)"

  @type runtime :: :ordinary | :prototype
  @type resolve_error ::
          :not_prototype_runtime
          | :binding_mismatch
          | :delegation_not_found
          | :delegation_foreign_tenant
          | :delegation_wrong_binding
          | :anchor_mismatch
  @type enter_error ::
          :not_prototype_runtime | :binding_mismatch | :invalid_agent | :invalid_correlation

  @doc "The assurance label, a constant in every build."
  @spec label() :: String.t()
  def label, do: @label

  if @compiled do
    alias SdrAgent.Prototype.Authority

    @doc "The VM's runtime, fixed once by `SdrAgent.Prototype.BootCheck.verify!/0`."
    @spec runtime() :: runtime()
    defdelegate runtime(), to: Authority

    @doc "The boot snapshot of the binding, in prototype runtime only."
    @spec binding() :: {:ok, Binding.t()} | {:error, :not_prototype_runtime}
    defdelegate binding(), to: Authority

    @doc "Re-reads the binding row and the live database identity and compares them with the snapshot."
    @spec check_live() :: :ok | {:error, :not_prototype_runtime | :binding_mismatch}
    defdelegate check_live(), to: Authority

    @doc "The identity-scoped relocation fence (ADR-0024 decision 1); `:ok` outside prototype runtime."
    @spec check_fence() :: :ok | {:error, :relocation_fenced}
    defdelegate check_fence(), to: Authority

    @doc "The IF-5 assurance block."
    @spec assurance() :: {:ok, map()} | {:error, :not_prototype_runtime}
    defdelegate assurance(), to: Authority

    @doc "Creates or replays this agent session's delegation; returns its id."
    @spec enter_session(:claude_code | :codex_cli, String.t()) ::
            {:ok, Ecto.UUID.t()} | {:error, enter_error()}
    defdelegate enter_session(agent, session_correlation), to: Authority

    @doc "Resolves the operator actor of `delegation_id` against the live binding."
    @spec operator_actor(Ecto.UUID.t()) :: {:ok, SdrAgent.Actor.t()} | {:error, resolve_error()}
    defdelegate operator_actor(delegation_id), to: Authority

    @doc "True only when `operator_actor(actor.id)` resolves to exactly `actor`."
    @spec operator?(term()) :: boolean()
    defdelegate operator?(actor), to: Authority

    @doc "The compiled `d237-prototype/1` policy entry, exactly."
    @spec policy_entry() :: {:ok, map()} | {:error, :not_prototype_runtime}
    def policy_entry, do: in_runtime(&Authority.policy_entry/0)

    @doc "The compiled `d237-funding/1` funding entry, exactly."
    @spec funding_entry() :: {:ok, map()} | {:error, :not_prototype_runtime}
    def funding_entry, do: in_runtime(&Authority.funding_entry/0)

    # A compiled constant, in prototype runtime only.
    defp in_runtime(entry) do
      case Authority.runtime() do
        :prototype -> {:ok, entry.()}
        :ordinary -> {:error, :not_prototype_runtime}
      end
    end
  else
    @doc "The VM's runtime: always `:ordinary` in this build."
    @spec runtime() :: runtime()
    def runtime, do: :ordinary

    @doc "Refused: no prototype authority in this build."
    @spec binding() :: {:ok, Binding.t()} | {:error, :not_prototype_runtime}
    def binding, do: {:error, :not_prototype_runtime}

    @doc "Refused: no prototype authority in this build."
    @spec check_live() :: :ok | {:error, :not_prototype_runtime | :binding_mismatch}
    def check_live, do: {:error, :not_prototype_runtime}

    @doc "The relocation fence: always `:ok` in this build (no relocation authority)."
    @spec check_fence() :: :ok
    def check_fence, do: :ok

    @doc "Refused: no prototype authority in this build."
    @spec assurance() :: {:ok, map()} | {:error, :not_prototype_runtime}
    def assurance, do: {:error, :not_prototype_runtime}

    @doc "Refused: no prototype authority in this build."
    @spec enter_session(:claude_code | :codex_cli, String.t()) ::
            {:ok, Ecto.UUID.t()} | {:error, enter_error()}
    def enter_session(_agent, _session_correlation), do: {:error, :not_prototype_runtime}

    @doc "Refused: no prototype authority in this build."
    @spec operator_actor(Ecto.UUID.t()) :: {:ok, SdrAgent.Actor.t()} | {:error, resolve_error()}
    def operator_actor(_delegation_id), do: {:error, :not_prototype_runtime}

    @doc "Always `false` in this build."
    @spec operator?(term()) :: boolean()
    def operator?(_actor), do: false

    @doc "Refused: no prototype authority in this build."
    @spec policy_entry() :: {:ok, map()} | {:error, :not_prototype_runtime}
    def policy_entry, do: {:error, :not_prototype_runtime}

    @doc "Refused: no prototype authority in this build."
    @spec funding_entry() :: {:ok, map()} | {:error, :not_prototype_runtime}
    def funding_entry, do: {:error, :not_prototype_runtime}
  end
end

defmodule SdrAgent.Prototype.Binding do
  @moduledoc """
  The boot snapshot of the singleton `PrototypeDatabaseBinding` row
  (interfaces r6 IF-1). `SdrAgent.Prototype.BootCheck.verify!/0` builds it
  once per VM; callers read it through `SdrAgent.Prototype.binding/0` and
  never rebuild it. `SdrAgent.Prototype.check_live/0` compares every field
  with the live row and the live database identity.
  """

  @enforce_keys [
    :id,
    :tenant_id,
    :instance_id,
    :operator_user_id,
    :auditor_user_id,
    :dataset_class,
    :policy_id,
    :policy_entry_sha256,
    :funding_id,
    :witness_mode,
    :database,
    :database_oid,
    :system_identifier,
    :bound_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          operator_user_id: Ecto.UUID.t(),
          auditor_user_id: Ecto.UUID.t() | nil,
          dataset_class: String.t(),
          policy_id: String.t(),
          policy_entry_sha256: String.t(),
          funding_id: String.t(),
          witness_mode: String.t(),
          database: String.t(),
          database_oid: pos_integer(),
          system_identifier: integer(),
          bound_at: DateTime.t()
        }

  @doc "The snapshot fields, in their fixed order."
  @spec fields() :: [atom()]
  def fields, do: @enforce_keys
end
