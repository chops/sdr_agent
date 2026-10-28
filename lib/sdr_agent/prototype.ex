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
  callers handle it.

  RED stage (D-237 S1): the contract surface only. `runtime/0` is
  `:ordinary`, `label/0` is the constant, `operator?/1` is `false`, and
  every other function returns `{:error, :not_implemented}`.
  """

  alias SdrAgent.Prototype.Binding

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

  @doc "The VM's runtime, fixed once by `SdrAgent.Prototype.BootCheck.verify!/0`."
  @spec runtime() :: runtime()
  def runtime, do: red(:ordinary)

  @doc "The boot snapshot of the binding, in prototype runtime only."
  @spec binding() :: {:ok, Binding.t()} | {:error, :not_prototype_runtime}
  def binding, do: not_implemented()

  @doc "Re-reads the binding row and the live database identity and compares them with the snapshot."
  @spec check_live() :: :ok | {:error, :not_prototype_runtime | :binding_mismatch}
  def check_live, do: not_implemented()

  @doc "The assurance label, a constant in every build."
  @spec label() :: String.t()
  def label, do: @label

  @doc "The IF-5 assurance block."
  @spec assurance() :: {:ok, map()} | {:error, :not_prototype_runtime}
  def assurance, do: not_implemented()

  @doc "Creates or replays this agent session's delegation; returns its id."
  @spec enter_session(:claude_code | :codex_cli, String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, enter_error()}
  def enter_session(_agent, _session_correlation), do: not_implemented()

  @doc "Resolves the operator actor of `delegation_id` against the live binding."
  @spec operator_actor(Ecto.UUID.t()) :: {:ok, SdrAgent.Actor.t()} | {:error, resolve_error()}
  def operator_actor(_delegation_id), do: not_implemented()

  @doc "True only when `operator_actor(actor.id)` succeeds and `actor.tenant_id` matches."
  @spec operator?(term()) :: boolean()
  def operator?(_actor), do: red(false)

  @doc "The compiled `d237-prototype/1` policy entry, exactly."
  @spec policy_entry() :: {:ok, map()} | {:error, :not_prototype_runtime}
  def policy_entry, do: not_implemented()

  @doc "The compiled `d237-funding/1` funding entry, exactly."
  @spec funding_entry() :: {:ok, map()} | {:error, :not_prototype_runtime}
  def funding_entry, do: not_implemented()

  defp not_implemented, do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
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
