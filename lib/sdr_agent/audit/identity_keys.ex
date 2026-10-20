defmodule SdrAgent.Audit.IdentityKeys do
  @moduledoc """
  Shared identity keys (ADR-0009 C3 amendment and C3-02 amendment; plan r8
  section 2): the only way this project takes a transaction advisory lock.

  **Ids.** `id(tenant_id, kind, raw)` is the key id of a raw key input:
  `K_domain(raw) = H("domain", tenant, strip(key_value(:domain, raw)))`
  and `K_email(raw) = H("email", tenant, key_value(:email, raw))`, where
  `H(kind, tenant, bytes)` is the first 8 bytes of
  `sha256("sdr-identity-key/1\\0" <> kind <> "\\0" <> tenant_id <> "\\0" <>
  bytes)` read as a signed 64-bit integer (`Normalize`, section 2.7).
  Callers pass the raw key input (the compared value), never a stripped
  value and never a digest.

  **One pass per application scope.** `pass(tenant_id, keys)` takes the
  application transaction's whole key set (`[{kind, raw}]`) at its entry
  point: the ids not yet held are locked one statement each, ascending
  (`pg_advisory_xact_lock($1::bigint)`, the id an integer parameter), then
  the membership record `sdr.identity_pass = "v1;<token>;<backend
  pid>;<ids>"` (the whole deduplicated requested set, ascending; ids only)
  is published in the same (sub)transaction, so a rollback that releases
  the locks reverts the record too. A later `pass/2` or `require_held/2`
  in the scope is allowed only for ids inside the recorded set, and only
  while the whole set is physically held (`pg_locks`); a new id raises
  `LateAcquisition`. `require_held/2` never acquires: without a pass it
  raises `MissingPass`. Both return `:ok`.

  **Scope and state.** The application scope is the outermost
  `SdrAgent.Repo` transaction (`IdentityKeys.Scope`, registered by
  `SdrAgent.Repo.prepare_transaction/2`). Every request reads the one
  state query of section 2.4 and applies the pure
  `IdentityKeys.Decision`. A failure while acquiring or publishing
  poisons the scope (`AcquisitionFailed`, carrying its class only); every
  later request in that scope raises `PassInconsistent`.

  **Preconditions.** A request outside any transaction raises
  `NotInTransaction`; inside a transaction without a scope (a standalone
  `Ecto.Multi`) it raises `UnscopedTransaction`.

  Every exception carries kinds, counts or fixed reasons only: no value,
  tenant or id. Only this module (and `IdentityKeys.*`) names the
  membership setting: a trusted-writer convention guarded by a static test,
  not a security boundary (plan r8 section 2.3, Q-C12).

  Test-seam builds only (`:claude_cli_test_seams`, config/test.exs):
  `IdentityKeys.TestFaults.with_fault/2` raises at a chosen acquisition
  point (section 2.5 fault cases); builds without the seam do not compile
  that branch.
  """

  alias SdrAgent.Audit.IdentityKeys.AcquisitionFailed
  alias SdrAgent.Audit.IdentityKeys.Decision
  alias SdrAgent.Audit.IdentityKeys.InvalidKeyValue
  alias SdrAgent.Audit.IdentityKeys.MissingPass
  alias SdrAgent.Audit.IdentityKeys.Normalize
  alias SdrAgent.Audit.IdentityKeys.NotInTransaction
  alias SdrAgent.Audit.IdentityKeys.Scope
  alias SdrAgent.Audit.IdentityKeys.UnscopedTransaction
  alias SdrAgent.Repo

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @kinds [:domain, :email]

  # Section 2.4: the one state query, no lock clause.
  @state_sql """
  SELECT current_setting('sdr.identity_pass', true),
         pg_backend_pid(),
         coalesce(array_agg((l.classid::bigint << 32) | l.objid::bigint)
                  FILTER (WHERE l.pid IS NOT NULL), '{}')
  FROM (SELECT 1) AS one
  LEFT JOIN pg_locks l
    ON  l.locktype = 'advisory'
    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND l.pid      = pg_backend_pid()
    AND l.objsubid = 1
    AND l.mode     = 'ExclusiveLock'
    AND l.granted
  """
  @lock_sql "SELECT pg_advisory_xact_lock($1::bigint)"
  @publish_sql "SELECT set_config('sdr.identity_pass', $1, true)"

  @type kind :: :domain | :email
  @type key :: {kind(), String.t()}

  @doc "The key id of a raw key input of `kind` for `tenant_id` (see the moduledoc)."
  @spec id(String.t(), kind(), String.t()) :: integer()
  def id(tenant_id, :domain, raw) when is_binary(tenant_id),
    do: digest("domain", tenant_id, Normalize.strip(Normalize.key_value(:domain, raw)))

  def id(tenant_id, :email, raw) when is_binary(tenant_id),
    do: digest("email", tenant_id, Normalize.key_value(:email, raw))

  def id(_tenant_id, kind, _raw) when kind in @kinds, do: raise(InvalidKeyValue, kind: kind)
  def id(_tenant_id, _kind, _raw), do: raise(InvalidKeyValue, kind: :unknown)

  @doc """
  The application scope's one pass over `keys` (`[{kind, raw}]`, possibly
  empty); `:ok`, or a raise (see the moduledoc).
  """
  @spec pass(String.t(), [key()]) :: :ok
  def pass(tenant_id, keys), do: request(:pass, tenant_id, keys)

  @doc """
  `:ok` when every id of `keys` is in this scope's pass and the pass is
  physically held; never acquires (see the moduledoc).
  """
  @spec require_held(String.t(), [key()]) :: :ok
  def require_held(tenant_id, keys), do: request(:require_held, tenant_id, keys)

  defp request(mode, tenant_id, keys) when is_list(keys) do
    scope = scope!()
    requested = MapSet.new(keys, &key_id(tenant_id, &1))
    {setting, backend, held} = state()

    case Decision.decide(scope, setting, backend, held, requested) do
      :ok ->
        :ok

      {:acquiring, _prior, _planned} when mode == :require_held ->
        raise MissingPass, count: MapSet.size(requested)

      {:acquiring, prior, planned} ->
        acquire(scope.token, prior, planned, requested, backend)
    end
  end

  defp scope! do
    if not Repo.in_transaction?(), do: raise(NotInTransaction)

    case Scope.current() do
      %Scope{} = scope -> scope
      _none -> raise UnscopedTransaction
    end
  end

  defp key_id(tenant_id, {kind, raw}), do: id(tenant_id, kind, raw)
  defp key_id(_tenant_id, _malformed), do: raise(InvalidKeyValue, kind: :unknown)

  defp state do
    %{rows: [[setting, backend, held]]} = Repo.query!(@state_sql, [])
    {setting, backend, MapSet.new(held)}
  end

  # Section 2.5: acquiring before the first lock, locks ascending, the
  # record, then passed; any failure poisons the scope and is re-raised as
  # AcquisitionFailed carrying its class only.
  defp acquire(token, prior, planned, requested, backend) do
    Scope.put_state(token, {:acquiring, prior, planned})

    try do
      fault!(:before_first_lock)

      planned
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.each(fn {id, count} ->
        Repo.query!(@lock_sql, [id])
        fault!({:after_locks, count})
      end)

      fault!(:at_publication)
      Repo.query!(@publish_sql, [record(token, backend, requested)])
    rescue
      _error -> poison!(token, :error)
    catch
      class, _reason -> poison!(token, class)
    end

    Scope.put_state(token, {:passed, prior, planned})
    :ok
  end

  defp poison!(token, class) do
    Scope.put_state(token, :poisoned)
    raise AcquisitionFailed, class: class
  end

  defp record(token, backend, ids),
    do: "v1;#{token};#{backend};#{ids |> Enum.sort() |> Enum.join(",")}"

  defp digest(kind, tenant_id, bytes) do
    <<id::signed-64, _rest::binary>> =
      :crypto.hash(:sha256, "sdr-identity-key/1\0" <> kind <> "\0" <> tenant_id <> "\0" <> bytes)

    id
  end

  if @test_seams do
    defp fault!(point), do: SdrAgent.Audit.IdentityKeys.TestFaults.trip!(point)
  else
    defp fault!(_point), do: :ok
  end
end
