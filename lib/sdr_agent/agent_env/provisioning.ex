defmodule SdrAgent.AgentEnv.Provisioning do
  @moduledoc """
  The provisioning attestation (C2* S2; plan
  `claude-c2star-s2-provisioning-plan-r1.md` §2 AC8, §4.3 and §5; Codex
  OQ12: a separate no-spend registration in the calling process, not an
  operation-snapshot entry).

  `within(authorization_id, fun)` observes the agent environment's state
  files **outside any transaction**, registers that observation in the
  calling process, runs `fun` and returns its result. The registration
  ends when `fun` returns or raises. Inside a transaction it returns
  `{:error, :in_transaction}` without reading a file or calling `fun`.

  The registration is a map of exactly the keys `ref`, `owner`, `level`,
  `authorization_id`, `authorization_sha256` (the compiled registry
  ENTRY digest, `SdrAgent.AgentEnv.Registry.sha256/1`, never a file's
  content digest), `binding_sha256`, `tenant_id`, `database`,
  `database_oid`, `claim_nonce`, `lease_nonce` and `observed_at`. Its
  `level` is:

    * `:provisioning` — mode `:provisioning`; `instance.lease` of that mode,
      the configured nonce and the environment's binding; a valid
      `environment.json` of `agentenv-1`; `Registry.current/0` is the entry
      `authorization_id` names; `authorization.claim.json` names that id, its
      digest and the binding;
    * `:spend_ready` — the same in mode `:run`, with a run lease and an
      `authorization.json` whose id, digest, binding and nonce equal the
      claim's;
    * `:none` — anything else (Q1). It confers no authority, and its
      observed fields are nil.

  The level says nothing about the entry's validity, its expiry or the live
  database: `ModelCallGrant :provision_delegated` checks those under its
  transaction (`SdrAgent.Agents.Changes.DelegatedProvisioning`).

  `current/0` is the calling process's registration (`{:ok, t}` inside
  `within/2`, else `:none`; no I/O). `verify/1` accepts only that exact
  registration, in its owner process, while it is registered: a copy with
  any field changed, a registration that has ended, or one used from
  another process is `{:error, :provisioning_unattested}`. This is a
  trusted in-process convention, like
  `SdrAgent.Agents.ReleaseDecision.Prelocked`: it proves nothing against
  arbitrary server code.
  """

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Registry
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Clock
  alias SdrAgent.Repo

  @registration {__MODULE__, :registration}
  @observed [
    :authorization_id,
    :authorization_sha256,
    :binding_sha256,
    :tenant_id,
    :database,
    :database_oid,
    :claim_nonce,
    :lease_nonce
  ]

  @type level :: :none | :provisioning | :spend_ready
  @type t :: %{
          ref: reference(),
          owner: pid(),
          level: level(),
          authorization_id: String.t() | nil,
          authorization_sha256: String.t() | nil,
          binding_sha256: String.t() | nil,
          tenant_id: String.t() | nil,
          database: String.t() | nil,
          database_oid: pos_integer() | nil,
          claim_nonce: String.t() | nil,
          lease_nonce: String.t() | nil,
          observed_at: DateTime.t()
        }

  @doc """
  Observes the environment for `authorization_id` (outside a transaction),
  registers the observation in this process for the duration of `fun`, and
  returns `fun`'s result; `{:error, :in_transaction}` inside a transaction.
  """
  @spec within(String.t(), (-> result)) :: result | {:error, :in_transaction}
        when result: term()
  def within(authorization_id, fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      {:error, :in_transaction}
    else
      registration = observe(authorization_id)
      previous = Process.get(@registration)
      Process.put(@registration, registration)

      try do
        fun.()
      after
        restore(previous)
      end
    end
  end

  @doc "The calling process's registration (no I/O): `{:ok, t}` or `:none`."
  @spec current() :: {:ok, t()} | :none
  def current do
    case Process.get(@registration) do
      %{owner: owner} = registration when owner == self() -> {:ok, registration}
      _other -> :none
    end
  end

  @doc """
  `{:ok, registration}` when `registration` is exactly this process's active
  registration, else `{:error, :provisioning_unattested}`.
  """
  @spec verify(term()) :: {:ok, t()} | {:error, :provisioning_unattested}
  def verify(%{ref: ref} = registration) when is_reference(ref) do
    case current() do
      {:ok, ^registration} -> {:ok, registration}
      _other -> {:error, :provisioning_unattested}
    end
  end

  def verify(_registration), do: {:error, :provisioning_unattested}

  defp restore(nil), do: Process.delete(@registration)
  defp restore(previous), do: Process.put(@registration, previous)

  defp observe(authorization_id) do
    base =
      Map.merge(Map.new(@observed, &{&1, nil}), %{
        ref: make_ref(),
        owner: self(),
        level: :none,
        observed_at: Clock.utc_now()
      })

    case observed(authorization_id, AgentEnv.mode()) do
      {:ok, level, fields} -> Map.merge(base, Map.put(fields, :level, level))
      :none -> base
    end
  end

  defp observed(authorization_id, mode) when mode in [:provisioning, :run] do
    with {:ok, root} <- State.root(),
         {:valid, binding, environment} <- State.read(root, :environment),
         true <- environment["environment_id"] == AgentEnv.environment_id(),
         {:valid, _sha256, lease} <- State.read(root, :lease),
         true <- lease?(lease, mode, binding),
         {:ok, entry} <- Registry.current(),
         true <- entry.id == authorization_id,
         digest = Registry.sha256(entry),
         {:valid, _sha256, claim} <- State.read(root, :claim),
         true <- claim?(claim, entry.id, digest, binding),
         {:ok, level} <- level(root, mode, claim) do
      {:ok, level,
       %{
         authorization_id: entry.id,
         authorization_sha256: digest,
         binding_sha256: binding,
         tenant_id: environment["tenant_id"],
         database: environment["database"],
         database_oid: environment["database_oid"],
         claim_nonce: claim["nonce"],
         lease_nonce: lease["nonce"]
       }}
    else
      _other -> :none
    end
  end

  defp observed(_authorization_id, _mode), do: :none

  defp lease?(lease, mode, binding) do
    lease["environment_id"] == AgentEnv.environment_id() and
      lease["mode"] == Atom.to_string(mode) and
      lease["nonce"] == Keyword.get(AgentEnv.config(), :nonce) and
      lease["target"] == %{"binding_sha256" => binding}
  end

  defp claim?(claim, id, digest, binding) do
    claim["authorization_id"] == id and claim["authorization_sha256"] == digest and
      claim["binding_sha256"] == binding
  end

  defp level(_root, :provisioning, _claim), do: {:ok, :provisioning}

  defp level(root, :run, claim) do
    with {:valid, _sha256, final} <- State.read(root, :authorization),
         true <-
           Enum.all?(
             ["authorization_id", "authorization_sha256", "binding_sha256", "nonce"],
             &(final[&1] == claim[&1])
           ) do
      {:ok, :spend_ready}
    else
      _other -> :none
    end
  end
end
