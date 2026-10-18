defmodule SdrAgent.AuditCase do
  @moduledoc """
  Test case for the audit kernel and the domains built on it: sandboxed
  database, actor builders (real `SdrAgent.Accounts.User` operators and
  system actors), and raw-SQL helpers that simulate an administrator
  bypassing the application (used only to prove tamper detection and
  trigger enforcement).
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL

  using do
    quote do
      import SdrAgent.AuditCase
      alias SdrAgent.Repo
    end
  end

  setup tags do
    SdrAgent.DataCase.setup_sandbox(tags)
    :ok
  end

  @provenance_cache {SdrAgent.Audit.Provenance, :current}
  @provenance_nonce :__test_provenance_nonce__
  @absent {__MODULE__, :absent}

  @doc """
  #178: makes this test's bootstraps record a *new* provenance snapshot.
  `SdrAgent.Audit.Provenance.current/0` is cached once per VM, and a
  committed fixture that ran earlier in the VM keeps the snapshot of that
  cached identity, so a later sandboxed bootstrap would find it and append
  no `system.provenance.recorded` event.

  It puts a unique test-only nonce into the `:sdr_agent` environment (part
  of the provenance config hash) and drops the cache, so the next
  `current/0` recollects; the new snapshot is created inside the test's
  sandbox and rolled back. The nonce's previous value or absence and the
  cache's exact previous value or absence are restored on exit; the
  cleanup is registered before the first change, so a failing step still
  restores both. Returns the fresh attributes.

  Opt-in, for synchronous (`async: false`) tests only, with no surviving
  workers of the test subject: the cache and the environment are global.
  """
  def fresh_provenance! do
    previous_nonce = Application.fetch_env(:sdr_agent, @provenance_nonce)
    previous_cache = :persistent_term.get(@provenance_cache, @absent)
    ExUnit.Callbacks.on_exit(fn -> restore_provenance(previous_nonce, previous_cache) end)

    baseline =
      case previous_cache do
        %{snapshot_sha256: sha} -> sha
        @absent -> SdrAgent.Audit.Provenance.collect().snapshot_sha256
      end

    nonce = "nonce-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    Application.put_env(:sdr_agent, @provenance_nonce, nonce)
    :persistent_term.erase(@provenance_cache)
    fresh = SdrAgent.Audit.Provenance.current()

    ExUnit.Assertions.assert(
      fresh.snapshot_sha256 != baseline,
      "fresh_provenance!/0: the provenance identity did not change"
    )

    fresh
  end

  @doc false
  # The restoration `fresh_provenance!/0` registers (public for its tests).
  def restore_provenance(previous_nonce, previous_cache) do
    case previous_nonce do
      {:ok, value} -> Application.put_env(:sdr_agent, @provenance_nonce, value)
      :error -> Application.delete_env(:sdr_agent, @provenance_nonce)
    end

    case previous_cache do
      @absent -> :persistent_term.erase(@provenance_cache)
      cache -> :persistent_term.put(@provenance_cache, cache)
    end

    :ok
  end

  @doc false
  def provenance_absent, do: @absent

  @doc "Bootstraps the singleton tenant through the kernel and returns it."
  def bootstrap! do
    {:ok, tenant} = SdrAgent.Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    tenant
  end

  @doc "Builds a system actor of `type` for `tenant`."
  def system_actor(type, tenant), do: struct(SdrAgent.Actor, type: type, tenant_id: tenant.id)

  # Test-only password for the operators built below.
  @password "test-password-1234"

  @doc "The password of every operator built by `human/2` and `new_human/3`."
  def test_password, do: @password

  @doc """
  A real operator (`SdrAgent.Accounts.User`) with `role` in `tenant`, created
  through the seeder on first use and reused for the rest of the test process.
  Creating it appends a `user.created` event.
  """
  def human(role, tenant) do
    key = {__MODULE__, :human, tenant.id, role}

    case Process.get(key) do
      nil ->
        user = new_human(role, tenant)
        Process.put(key, user)
        user

      user ->
        user
    end
  end

  @doc "Always creates a new operator with `role` (see `human/2`)."
  def new_human(role, tenant, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      SdrAgent.Accounts.seed_user(
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            email: "#{role}-#{n}@example.test",
            display_name: "Test #{role} #{n}",
            role: role,
            password: @password,
            password_confirmation: @password
          },
          attrs
        ),
        actor: system_actor(:seeder, tenant)
      )

    user
  end

  @doc "All audit events of the tenant in sequence order, read by the auditor CLI."
  def events(tenant) do
    {:ok, events} = SdrAgent.Audit.list_events(actor: system_actor(:auditor_cli, tenant))
    events
  end

  @doc "Events of one event type."
  def events_of_type(tenant, type), do: Enum.filter(events(tenant), &(&1.event_type == type))

  @doc "Runs raw SQL with triggers disabled, simulating a database administrator."
  def tamper!(sql, params \\ []) do
    SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])
    result = SQL.query!(SdrAgent.Repo, sql, params)
    SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = origin", [])
    result
  end

  @doc "Runs raw SQL in a savepoint and returns the Postgres error it raises."
  def raw_error(sql, params \\ []) do
    SdrAgent.Repo.transaction(fn ->
      case SQL.query(SdrAgent.Repo, sql, params) do
        {:ok, result} -> SdrAgent.Repo.rollback({:unexpected_success, result})
        {:error, error} -> SdrAgent.Repo.rollback(error)
      end
    end)
  end

  @doc "A fixed 32-byte digest for fixtures."
  def digest(label), do: :crypto.hash(:sha256, label)

  @doc "Lowercase hex of a binary."
  def hex(bin), do: Base.encode16(bin, case: :lower)
end
