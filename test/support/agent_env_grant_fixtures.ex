defmodule SdrAgent.Test.AgentEnvGrantFixtures do
  @moduledoc """
  C2* S2 RED-2 fixtures for delegated provisioning (plan
  `claude-c2star-s2-provisioning-plan-r1.md` §5 "Test support" and §7; Codex
  plan/entity PASS `aa42492e` with its binding OQ rulings; the GREEN-1 PASS
  at `a208a05a`). They compile while the RED-2 subjects do not exist: every
  call into `SdrAgent.AgentEnv.Provisioning`,
  `SdrAgent.Agents.Changes.GrantBundle.Delegated` and
  `SdrAgent.Agents.provision_delegated_grant/2` is resolved at run time
  behind an explicit `c2star-s2:` presence guard, so a missing subject fails
  as an assertion in the test body, never in compilation.

    * `prv/1` — the grant provisioner (PRV) of a tenant,
      `Actor.system(:grant_provisioner, tenant_id, "bin/agent-env authorize")`,
      behind the AC1 guard that the type exists.
    * `test_entry/1`, `put_test_entries!/1` — a synthetic registry entry
      (total 6, per-day 4, `[:claude_cli_opus]`, two disjoint late-October
      `[:b1]` windows, the stand-in caps row `D-999`) and the registry
      test seam (`test_entries:`), restored on exit. Fixtures, never caps.
    * `claim!/3`, `final!/3` — `authorization.claim.json` and
      `authorization.json` through `SdrAgent.AgentEnv.State.create/3`
      (create-only, validated), consistent with the entry and the bound
      environment unless overridden.
    * `provisioning_env!/1` — a configured agent environment (mode
      `:provisioning` by default) with a bound environment of the live test
      database and the sandbox tenant, its lease, one registry entry and
      its claim (`SdrAgent.Test.AgentEnvFixtures`).
    * `provision/2`, `within/2`, `provisioned!/1` — the guarded domain API
      call, the guarded `Provisioning.within/2`, and a provisioned
      environment.
    * `delegated_row!/2` — a delegated grant and its allocations written
      with raw SQL in the test's sandbox: an SQL-level stand-in for a
      delegated parent in the policy tests, satisfying the GREEN-1 CHECKs.
      It is not an application write route and never authority.
    * `inert/1` — runs a function with the agent environment unconfigured,
      then restores the exact configuration.

  Nothing here is production provisioning evidence, and no value here is
  an owner cap or decision row.
  """

  import ExUnit.Assertions

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv.Registry
  alias SdrAgent.AgentEnv.Registry.Entry
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Clock
  alias SdrAgent.Repo
  alias SdrAgent.Test.AgentEnvFixtures

  @provisioning SdrAgent.AgentEnv.Provisioning
  @delegated SdrAgent.Agents.Changes.GrantBundle.Delegated
  @refused SdrAgent.Agents.Errors.ProvisioningRefused
  @config SdrAgent.AgentEnv
  @prv_id "bin/agent-env authorize"

  # Synthetic fixture values, not caps. D-999 stands in for the owner's caps
  # decision row, which is not recorded.
  @refs ["D-999", "D-219", "D-221"]
  @now ~U[2026-10-28 12:00:00.000000Z]
  @starts ~U[2026-10-27 00:00:00.000000Z]
  @expires ~U[2026-10-31 00:00:00.000000Z]
  @w1 {~U[2026-10-28 00:00:00.000000Z], ~U[2026-10-29 00:00:00.000000Z]}
  @w2 {~U[2026-10-29 00:00:00.000000Z], ~U[2026-10-31 00:00:00.000000Z]}

  @doc "The frozen instant of the RED-2 tests (inside the first allocation window)."
  def now, do: @now

  @doc "The synthetic decision refs of `test_entry/1`."
  def refs, do: @refs

  @doc "PRV's actor id."
  def prv_id, do: @prv_id

  @doc "The planned module names (plan §4.3 and §5)."
  def provisioning_module, do: @provisioning
  def delegated_module, do: @delegated
  def refused_module, do: @refused

  ## Presence guards

  @doc "Asserts that `module` is compiled and loadable."
  def require_module!(module) do
    assert Code.ensure_loaded?(module), "c2star-s2: #{inspect(module)} is not implemented"
  end

  @doc "Asserts that `module` exports `fun/arity`."
  def require_function!(module, fun, arity) do
    require_module!(module)

    assert function_exported?(module, fun, arity),
           "c2star-s2: #{inspect(module)}.#{fun}/#{arity} is not implemented"
  end

  @doc "Asserts that `resource` has action `name`; returns the action."
  def require_action!(resource, name) do
    action = Info.action(resource, name)
    assert action, "c2star-s2: #{inspect(resource)} has no #{inspect(name)} action"
    action
  end

  @doc "Calls `module.fun(args...)` at run time (the subject may not exist at RED)."
  def invoke(module, fun, args) when is_list(args), do: apply(module, fun, args)

  ## Actors

  @doc """
  The grant provisioner of `tenant` (a tenant struct or id): PRV, after the
  AC1 guard that `:grant_provisioner` is an `SdrAgent.Actor` type.
  """
  def prv(%{id: tenant_id}), do: prv(tenant_id)

  def prv(tenant_id) when is_binary(tenant_id) do
    assert :grant_provisioner in Actor.types(),
           "c2star-s2: :grant_provisioner is not an SdrAgent.Actor type (AC1)"

    invoke(Actor, :system, [:grant_provisioner, tenant_id, @prv_id])
  end

  ## Registry entries (synthetic)

  @doc "A synthetic `[:b1]` allocation."
  def alloc(key, attempts, {from, until}) do
    %{
      key: key,
      applies_to: [:b1],
      attempts: attempts,
      available_from: from,
      available_until: until
    }
  end

  @doc "A unique registry id (`^[a-z0-9][a-z0-9.-]{0,63}$`)."
  def entry_id(prefix \\ "test-s2"), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "A synthetic registry entry, `overrides` applied."
  def test_entry(overrides \\ %{}) do
    struct!(
      Entry,
      Map.merge(
        %{
          id: entry_id(),
          decision_refs: @refs,
          environment_id: "agentenv-1",
          starts_at: @starts,
          expires_at: @expires,
          funded_scope: Registry.funded_scope(),
          total_attempts: 6,
          per_utc_day_attempts: 4,
          profile_ids: [:claude_cli_opus],
          allocations: [alloc(:rehearsal, 2, @w1), alloc(:daily_use, 4, @w2)]
        },
        Map.new(overrides)
      )
    )
  end

  @doc "Puts `entries` in the registry test seam for the rest of the test."
  def put_test_entries!(entries) when is_list(entries) do
    previous = Application.fetch_env(:sdr_agent, Registry)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, Registry, value)
        :error -> Application.delete_env(:sdr_agent, Registry)
      end
    end)

    Application.put_env(:sdr_agent, Registry, test_entries: entries)
    :ok
  end

  ## Authorization files

  @doc """
  Creates `authorization.claim.json` for `entry` bound to the environment
  under `root` (string-keyed `overrides` replace any key). Returns
  `%{nonce, sha256, data}`.
  """
  def claim!(root, %Entry{} = entry, overrides \\ %{}) do
    data =
      Map.merge(
        %{
          "authorization_id" => entry.id,
          "authorization_sha256" => Registry.sha256(entry),
          "binding_sha256" => AgentEnvFixtures.file_sha256!(root, :environment),
          "nonce" => AgentEnvFixtures.nonce(),
          "claimed_at" => Clock.utc_now()
        },
        stringify(overrides)
      )

    %{nonce: data["nonce"], sha256: create!(root, :claim, data), data: data}
  end

  @doc """
  Creates `authorization.json` consistent with `claim` (`overrides` replace
  any key). Returns `%{sha256, data}`.
  """
  def final!(root, claim, overrides \\ %{}) do
    data =
      Map.merge(
        %{
          "authorization_id" => claim.data["authorization_id"],
          "authorization_sha256" => claim.data["authorization_sha256"],
          "binding_sha256" => claim.data["binding_sha256"],
          "grant_id" => Ecto.UUID.generate(),
          "revision" => 1,
          "event_id" => Ecto.UUID.generate(),
          "nonce" => claim.nonce
        },
        stringify(overrides)
      )

    %{sha256: create!(root, :authorization, data), data: data}
  end

  defp create!(root, name, data) do
    result = State.create(root, name, data)

    assert match?({:ok, _sha256}, result),
           "fixture: #{inspect(name)} not created: #{inspect(result)}"

    elem(result, 1)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  ## Environments

  @doc """
  A configured agent environment with one registry entry and its claim.
  Options: `mode:` (`:provisioning`, default, or `:run`); `lease:` (default
  the mode; `:none`); `nonce:` (default the lease's); `database_oid:`
  (`:live`); `tenant_id:` (the environment's attested tenant; default the
  singleton tenant); `entry:`; `entries:` (default `[entry]`); `claim:`
  (`true`; `false` writes none); `claim_overrides:`. Returns `%{root, bound,
  entry, digest, claim}`.
  """
  def provisioning_env!(opts \\ []) do
    mode = Keyword.get(opts, :mode, :provisioning)
    root = AgentEnvFixtures.root!("s2")

    bound =
      AgentEnvFixtures.bound!(
        root,
        [
          lease: Keyword.get(opts, :lease, mode),
          database_oid: Keyword.get(opts, :database_oid, :live)
        ] ++ Keyword.take(opts, [:tenant_id])
      )

    AgentEnvFixtures.configure!(root, mode: mode, nonce: Keyword.get(opts, :nonce, bound.nonce))
    entry = Keyword.get_lazy(opts, :entry, fn -> test_entry() end)
    put_test_entries!(Keyword.get(opts, :entries, [entry]))

    claim =
      if Keyword.get(opts, :claim, true),
        do: claim!(root, entry, Keyword.get(opts, :claim_overrides, %{}))

    %{root: root, bound: bound, entry: entry, digest: Registry.sha256(entry), claim: claim}
  end

  @doc "Runs `fun` with no agent environment configured, then restores the exact configuration."
  def inert(fun) when is_function(fun, 0) do
    previous = Application.fetch_env(:sdr_agent, @config)
    Application.delete_env(:sdr_agent, @config)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, @config, value)
        :error -> Application.delete_env(:sdr_agent, @config)
      end
    end
  end

  ## Provisioning (guarded)

  @doc "`SdrAgent.Agents.provision_delegated_grant(id, opts)`, guarded."
  def provision(id, opts) do
    require_function!(Agents, :provision_delegated_grant, 2)
    invoke(Agents, :provision_delegated_grant, [id, opts])
  end

  @doc "`SdrAgent.AgentEnv.Provisioning.within(id, fun)`, guarded."
  def within(id, fun) when is_function(fun, 0) do
    require_function!(@provisioning, :within, 2)
    invoke(@provisioning, :within, [id, fun])
  end

  @doc "`SdrAgent.AgentEnv.Provisioning.current/0`, guarded."
  def current do
    require_function!(@provisioning, :current, 0)
    invoke(@provisioning, :current, [])
  end

  @doc "`SdrAgent.AgentEnv.Provisioning.verify/1`, guarded."
  def verify(attestation) do
    require_function!(@provisioning, :verify, 1)
    invoke(@provisioning, :verify, [attestation])
  end

  @doc """
  `provisioning_env!/1`, then the entry provisioned as PRV through the
  domain API. Returns the environment with `prv` and `grant`.
  """
  def provisioned!(opts \\ []) do
    env = provisioning_env!(opts)
    prv = prv(env.bound.tenant_id)
    result = provision(env.entry.id, actor: prv)

    assert match?({:ok, %ModelCallGrant{}}, result),
           "c2star-s2: provisioning the synthetic entry failed: " <>
             inspect(result, limit: 8, printable_limit: 400)

    env |> Map.put(:prv, prv) |> Map.put(:grant, elem(result, 1))
  end

  @doc """
  RED-4: a spend-ready run environment. `provisioned!/1` (options passed
  through), then the run side with S1's fixtures: a run lease of the
  environment's binding, the run configuration with that nonce, and
  `authorization.json` naming the grant and its `model.grant.provisioned`
  event. Returns the environment with `lease_nonce` and `event`.
  """
  def spend_ready!(opts \\ []) do
    env = provisioned!(opts)

    [event] =
      env.bound.tenant_id
      |> then(&SdrAgent.AuditCase.events_of_type(%{id: &1}, "model.grant.provisioned"))
      |> Enum.filter(&(&1.subject_id == env.grant.id))

    run_side!(env, %{"grant_id" => env.grant.id, "event_id" => event.id})
    |> Map.put(:event, event)
  end

  @doc """
  RED-4: a spend-ready run environment whose grant is an SQL-level delegated
  stand-in under the registry entry's id and digest (`delegated_row!/2`),
  for environments provisioning refuses (e.g. `database_oid:` other than the
  live oid). `opts` go to `provisioning_env!/1` (mode `:run`, no lease: the
  run side writes it). Returns the environment with `grant` and `lease_nonce`.
  """
  def stand_in_spend_ready!(%{id: _} = tenant, opts \\ []) do
    env = provisioning_env!([mode: :run, lease: :none] ++ opts)

    grant =
      delegated_row!(tenant,
        authorization_id: env.entry.id,
        authorization_sha256: env.digest
      )

    env
    |> Map.put(:grant, grant)
    |> run_side!(%{"grant_id" => grant.id, "event_id" => Ecto.UUID.generate()})
  end

  # A run lease of the binding, the run configuration with its nonce, and
  # the final file consistent with the claim (`overrides` applied).
  defp run_side!(env, overrides) do
    nonce = AgentEnvFixtures.write_lease!(env.root, :run, env.bound.binding_sha256)
    AgentEnvFixtures.configure!(env.root, mode: :run, nonce: nonce)
    final!(env.root, env.claim, overrides)
    Map.put(env, :lease_nonce, nonce)
  end

  @doc "Whether `result` is a `ProvisioningRefused` refusal with `reason`."
  def refused?({:error, %Ash.Error.Invalid{errors: errors}}, reason),
    do: Enum.any?(errors, &match?(%{__struct__: @refused, reason: ^reason}, &1))

  def refused?(_result, _reason), do: false

  ## Rows

  @doc "Every grant (kernel read, allocations loaded), oldest first."
  def grants do
    ModelCallGrant
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.load(:allocations)
    |> Ash.read!(authorize?: false)
  end

  @doc "Every allocation (kernel read)."
  def allocations, do: Ash.read!(ModelCallAllocation, authorize?: false)

  @doc "The grant `id`, re-read with its allocations (kernel read)."
  def reload!(id), do: Ash.get!(ModelCallGrant, id, load: :allocations, authorize?: false)

  @doc """
  A delegated grant and its allocations, inserted with raw SQL in the
  sandbox (see the moduledoc). Options: `authorization_id:`,
  `authorization_sha256:` (64 lowercase hex), `allocations:` (registry-entry
  shaped maps; default the `test_entry/1` pair), `status:`. Returns the grant
  re-read with its allocations.
  """
  def delegated_row!(%{id: tenant_id}, opts \\ []) do
    id = Ash.UUIDv7.generate()
    revoked? = Keyword.get(opts, :status, :active) == :revoked

    insert!("model_call_grants",
      id: uuid(id),
      tenant_id: uuid(tenant_id),
      name: "c2star-s2 raw delegated stand-in",
      purpose: "Synthetic delegated parent for the RED-2 policy tests",
      status: if(revoked?, do: "revoked", else: "active"),
      profile_ids: ["claude_cli_opus"],
      total_attempts: 6,
      per_utc_day_attempts: 4,
      starts_at: @starts,
      expires_at: @expires,
      revision: if(revoked?, do: 2, else: 1),
      revoked_at: if(revoked?, do: @now),
      trace_id: rand_hex(16),
      span_id: rand_hex(8),
      inserted_at: @now,
      updated_at: @now,
      provisioning: "delegated",
      created_by_id: nil,
      updated_by_id: nil,
      delegated_authorization_id: Keyword.get_lazy(opts, :authorization_id, &entry_id/0),
      delegated_authorization_sha256:
        Keyword.get_lazy(opts, :authorization_sha256, fn -> rand_hex(32) end)
    )

    opts
    |> Keyword.get(:allocations, [alloc(:rehearsal, 2, @w1), alloc(:daily_use, 4, @w2)])
    |> Enum.each(&insert_allocation!(tenant_id, id, &1))

    reload!(id)
  end

  defp insert_allocation!(tenant_id, grant_id, allocation) do
    insert!("model_call_allocations",
      id: uuid(Ash.UUIDv7.generate()),
      tenant_id: uuid(tenant_id),
      grant_id: uuid(grant_id),
      key: Atom.to_string(allocation.key),
      applies_to: Enum.map(allocation.applies_to, &Atom.to_string/1),
      profile_id: nil,
      attempts: allocation.attempts,
      available_from: allocation.available_from,
      available_until: allocation.available_until,
      released_at: nil,
      grant_revision: 1,
      trace_id: rand_hex(16),
      span_id: rand_hex(8),
      inserted_at: @now,
      updated_at: @now
    )
  end

  defp insert!(table, columns) do
    names = Keyword.keys(columns)
    placeholders = Enum.map_join(1..length(names)//1, ", ", &"$#{&1}")
    sql = "INSERT INTO #{table} (#{Enum.join(names, ", ")}) VALUES (#{placeholders})"
    result = SQL.query(Repo, sql, Keyword.values(columns))

    assert match?({:ok, %{num_rows: 1}}, result),
           "fixture: raw #{table} insert refused: " <>
             inspect(result, limit: 6, printable_limit: 300)
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  @doc "`bytes` random bytes as lowercase hex."
  def rand_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
