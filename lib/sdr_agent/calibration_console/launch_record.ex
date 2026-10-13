defmodule SdrAgent.CalibrationConsole.LaunchRecord do
  @moduledoc """
  The calibration console's durable single-flight launch record (R0-07
  slice E, row R11-1; harness round 13, entity PASS at 094caa86; staged E4a
  contract in the packet). File artifact only: the OS probe is E4b, and the
  database rules and the `calibrate` orchestration are E4c.

  Under a private `root`, `run.lock` (created by `mkdir`, mode 0700) holds
  `record.json` (mode 0600) in the closed schema
  `r0-calibration-launch-record/1`: `instance_id`, `owner_pid` and
  `owner_identity` (its start identity), `generation` 1, and a `state`
  with the fields it requires:

    * `claimed` (after preflight) — no launch can have happened;
    * `launch_pending` (`invocation_id`) — written after the invocation is
      `sent` and before the child is spawned;
    * `launched` (`root_pid`, `root_identity`, `session_id`);
    * `finished` — nothing outstanding; `release/2` then removes the lock.

  Every operation first requires private paths: the root, `run.lock`, the
  record and the recovery ticket are not symlinks, and neither is any
  ancestor; directories are mode 0700 and files 0600. Otherwise
  `:launch_record_unsafe`. The record on disk is authoritative: `advance`
  needs the caller's record to equal it (else `:invalid_transition`), and
  a record is rewritten only by atomic replace (temporary file, sync, 0600,
  rename). A failed write is `:launch_record_write_failed` and leaves the
  previous record and the lock. The `replace:` option (the final rename)
  exists for tests and runs only after every check.

  A missing, partial, malformed or wrongly shaped record reads as
  `%{state: "launch_pending", unreadable: true}`, never as "no launch".

  **Recovery.** `recover/2` refuses a live owner (`:owner_alive`: the
  recorded pid alive with the recorded start identity) and an unreadable
  record (`:owner_unknown`) unless the owner passes the typed attestation
  `owner_verified_stopped: "STOPPED"`. It then claims `run.lock/recover`
  by `mkdir`; an existing ticket, even an abandoned one, is
  `:recovery_in_progress` and is never taken over. `verify_recovery/2`
  re-reads the record on disk and requires the recovery's snapshot
  (`:record_changed`); `end_recovery/2` removes only its own ticket
  (`:recovery_changed`), and `release/2` only its own finished lock
  (`:record_changed`).

  **Quiescence** (`quiescence/2`): `claimed` and `finished` have nothing
  outstanding; a `launch_pending` or unreadable record needs the owner's
  attestation (`attest_stopped/3`, typed `STOPPED`); a `launched` record
  needs no process in its session and its root absent or reused. Root death
  alone is never quiescence.

  **Probe** (`probe:`, a module): `self_pid/0` → `{:ok, pid} | {:error,
  _}`, `start_identity/1` → `{:ok, identity} | :absent | {:error, _}`,
  `session_members/1` → `{:ok, pids} | {:error, _}`; a raise is an error.
  An observation failure is never absence or an empty session: claim
  creates nothing, recovery is refused and quiescence is not established
  (`:probe_unavailable`).

  The directory entry is not synced (the runtime has no directory fsync):
  a power loss may lose a just-written record, which then reads as
  `launch_pending` and needs the owner.
  """

  import Bitwise

  @schema "r0-calibration-launch-record/1"
  @confirmation "STOPPED"
  @keys ~w(schema instance_id owner_pid owner_identity generation state invocation_id root_pid
           root_identity session_id owner_attested_at)a
  @order %{claimed: :launch_pending, launch_pending: :launched, launched: :finished}
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @unreadable %{state: "launch_pending", unreadable: true}

  @type launch_record :: %{required(atom()) => term()}

  ## Claim and advance

  @doc """
  Claims the single flight for this console: `{:ok, record}` (`claimed`),
  `{:error, :calibration_in_progress}`, `{:error, :probe_unavailable}`
  (nothing is created), `:launch_record_unsafe` or
  `:launch_record_write_failed`.
  """
  def claim(root, opts) do
    with :ok <- safe_root(root),
         {:ok, pid, identity} <- self_identity(probe(opts)),
         :ok <- make_lock(root) do
      record =
        Map.merge(blank(), %{
          instance_id: Ash.UUIDv7.generate(),
          owner_pid: pid,
          owner_identity: identity,
          state: "claimed"
        })

      with :ok <- write(root, record, opts), do: {:ok, record}
    end
  end

  @doc """
  Moves `record` (which must equal the record on disk) to `state` with its
  `attrs`: `claimed → launch_pending (invocation_id) → launched (root_pid,
  root_identity, session_id) → finished`. `{:ok, record}` or `{:error,
  :invalid_transition | :launch_record_unsafe | :launch_record_write_failed}`.
  """
  def advance(root, record, state, attrs, opts \\ []) do
    with {:ok, current} <- read_safe(root),
         :ok <- same(current, record, :invalid_transition),
         {:ok, next} <- transition(current, state, attrs),
         :ok <- write(root, next, opts) do
      {:ok, next}
    end
  end

  @doc """
  The record on disk: `{:ok, record}`, `{:ok, :none}` without a lock,
  `{:ok, %{state: "launch_pending", unreadable: true}}` for anything
  unreadable, or `{:error, :launch_record_unsafe}`.
  """
  def read(root), do: read_safe(root)

  @doc """
  Removes the lock of `record`, which must be the finished record on disk:
  `:ok`, `{:error, :not_finished}`, `{:error, :record_changed}` (another
  record is there) or `{:error, :launch_record_unsafe}`.
  """
  def release(root, record) do
    with {:ok, current} <- read_safe(root),
         :ok <- same(current, record, :record_changed),
         :ok <- finished(current) do
      lock = lock(root)
      File.rm(record_path(root))
      File.rmdir(lock)
      if File.exists?(lock), do: {:error, :launch_record_write_failed}, else: :ok
    end
  end

  ## Recovery

  @doc """
  Claims recovery of a stale lock: `{:ok, %{record:, ticket:}}`, or
  `{:error, reason}` with `:owner_alive`, `:owner_unknown`,
  `:confirmation_mismatch`, `:probe_unavailable`, `:recovery_in_progress`,
  `:no_launch` or `:launch_record_unsafe`. `owner_verified_stopped:
  "STOPPED"` is the owner's attestation for an unreadable record.
  """
  def recover(root, opts) do
    with {:ok, record} <- read_safe(root),
         :ok <- recoverable(record, opts),
         {:ok, ticket} <- make_ticket(root) do
      {:ok, %{record: record, ticket: ticket}}
    end
  end

  @doc "`:ok` while the record on disk is still the recovery's snapshot, else `{:error, :record_changed}`."
  def verify_recovery(root, %{record: snapshot}) do
    with {:ok, current} <- read_safe(root), do: same(current, snapshot, :record_changed)
  end

  @doc "Removes the recovery's own ticket: `:ok` or `{:error, :recovery_changed | :launch_record_unsafe}`."
  def end_recovery(root, %{ticket: ticket}) do
    dir = ticket_dir(root)

    with :ok <- safe_root(root),
         :ok <- private_dir(lock(root)),
         :ok <- private_dir(dir),
         {:ok, ^ticket} <- read_ticket(dir) do
      File.rm(Path.join(dir, "ticket"))
      File.rmdir(dir)
      :ok
    else
      {:error, :launch_record_unsafe} = unsafe -> unsafe
      _other -> {:error, :recovery_changed}
    end
  end

  ## Quiescence

  @doc """
  `:quiescent`, `:not_quiescent`, `:owner_verification_required` or
  `{:error, :probe_unavailable}` for `record` (see the moduledoc).
  """
  def quiescence(%{unreadable: true}, _opts), do: :owner_verification_required
  def quiescence(%{state: state}, _opts) when state in ["claimed", "finished"], do: :quiescent

  def quiescence(%{state: "launch_pending"} = record, _opts) do
    if is_binary(Map.get(record, :owner_attested_at)),
      do: :quiescent,
      else: :owner_verification_required
  end

  def quiescence(%{state: "launched"} = record, opts) do
    probe = probe(opts)

    with {:ok, members} <- observe(fn -> probe.session_members(record.session_id) end),
         {:ok, root} <- observe(fn -> probe.start_identity(record.root_pid) end) do
      if members == [] and root != {:ok, record.root_identity},
        do: :quiescent,
        else: :not_quiescent
    end
  end

  def quiescence(_record, _opts), do: :owner_verification_required

  @doc """
  Records the owner's typed attestation (`"STOPPED"`) that a
  `launch_pending` record's work is stopped: `{:ok, record}` or `{:error,
  :confirmation_mismatch | :invalid_transition | :launch_record_unsafe |
  :launch_record_write_failed}`.
  """
  def attest_stopped(root, record, confirmation, opts \\ [])

  def attest_stopped(root, record, @confirmation, opts) do
    with {:ok, current} <- read_safe(root),
         :ok <- same(current, record, :invalid_transition),
         %{state: "launch_pending"} <- current do
      attested = %{current | owner_attested_at: now()}
      with :ok <- write(root, attested, opts), do: {:ok, attested}
    else
      {:error, _reason} = error -> error
      _not_pending -> {:error, :invalid_transition}
    end
  end

  def attest_stopped(_root, _record, _confirmation, _opts), do: {:error, :confirmation_mismatch}

  ## Transitions

  # An unreadable record never advances: only recovery may act on it.
  defp transition(%{unreadable: true}, _state, _attrs), do: {:error, :invalid_transition}

  defp transition(%{state: from} = current, state, attrs) when is_atom(state) do
    from = String.to_existing_atom(from)

    with ^state <- Map.get(@order, from),
         {:ok, fields} <- fields(state, attrs) do
      {:ok, current |> Map.merge(fields) |> Map.put(:state, Atom.to_string(state))}
    else
      _ -> {:error, :invalid_transition}
    end
  end

  defp transition(_current, _state, _attrs), do: {:error, :invalid_transition}

  defp fields(:launch_pending, %{invocation_id: id}) when is_binary(id) do
    if id =~ @uuid, do: {:ok, %{invocation_id: id}}, else: :error
  end

  defp fields(:launched, %{root_pid: pid, root_identity: identity, session_id: session})
       when is_integer(pid) and pid > 0 and is_binary(identity) and identity != "" and
              is_integer(session) and session > 0,
       do: {:ok, %{root_pid: pid, root_identity: identity, session_id: session}}

  defp fields(:finished, _attrs), do: {:ok, %{}}
  defp fields(_state, _attrs), do: :error

  defp finished(%{state: "finished"}), do: :ok
  defp finished(_record), do: {:error, :not_finished}

  defp same(%{unreadable: true}, %{unreadable: true}, _error), do: :ok
  defp same(current, record, error), do: if(current == record, do: :ok, else: {:error, error})

  defp blank, do: Map.new(@keys, &{&1, nil}) |> Map.merge(%{schema: @schema, generation: 1})

  ## Recovery checks

  defp recoverable(:none, _opts), do: {:error, :no_launch}

  defp recoverable(%{unreadable: true}, opts) do
    case Keyword.fetch(opts, :owner_verified_stopped) do
      {:ok, @confirmation} -> :ok
      {:ok, _other} -> {:error, :confirmation_mismatch}
      :error -> {:error, :owner_unknown}
    end
  end

  defp recoverable(record, opts) do
    case observe(fn -> probe(opts).start_identity(record.owner_pid) end) do
      {:ok, {:ok, identity}} when identity == record.owner_identity -> {:error, :owner_alive}
      {:ok, _absent_or_reused} -> :ok
      {:error, :probe_unavailable} = error -> error
    end
  end

  defp make_ticket(root) do
    dir = ticket_dir(root)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> {:error, :recovery_in_progress}
      {:ok, _symlink_or_other} -> {:error, :launch_record_unsafe}
      {:error, :enoent} -> create_ticket(dir)
      {:error, _reason} -> {:error, :launch_record_unsafe}
    end
  end

  defp create_ticket(dir) do
    ticket = Ash.UUIDv7.generate()

    case File.mkdir(dir) do
      :ok ->
        with :ok <- File.chmod(dir, 0o700),
             :ok <- write_file(dir, "ticket", ticket, &File.rename/2) do
          {:ok, ticket}
        else
          _ -> {:error, :launch_record_write_failed}
        end

      {:error, :eexist} ->
        {:error, :recovery_in_progress}

      {:error, _reason} ->
        {:error, :launch_record_write_failed}
    end
  end

  defp read_ticket(dir) do
    path = Path.join(dir, "ticket")

    with :ok <- private_file(path), do: File.read(path)
  end

  ## Reading

  defp read_safe(root) do
    with :ok <- safe_root(root) do
      lock = lock(root)

      case File.lstat(lock) do
        {:error, :enoent} -> {:ok, :none}
        {:ok, _stat} -> read_lock(lock)
        {:error, _reason} -> {:error, :launch_record_unsafe}
      end
    end
  end

  defp read_lock(lock) do
    path = Path.join(lock, "record.json")

    with :ok <- private_dir(lock) do
      case File.lstat(path) do
        {:error, :enoent} -> {:ok, @unreadable}
        {:ok, _stat} -> read_record(path)
        {:error, _reason} -> {:error, :launch_record_unsafe}
      end
    end
  end

  defp read_record(path) do
    with :ok <- private_file(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, parse(bytes)}
    else
      {:error, :launch_record_unsafe} = unsafe -> unsafe
      _unreadable -> {:ok, @unreadable}
    end
  end

  defp parse(bytes) do
    with {:ok, %{} = decoded} <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(decoded)) == Enum.sort(Enum.map(@keys, &Atom.to_string/1)),
         record = Map.new(@keys, &{&1, Map.fetch!(decoded, Atom.to_string(&1))}),
         true <- valid?(record) do
      record
    else
      _ -> @unreadable
    end
  end

  defp valid?(record) do
    record.schema == @schema and uuid?(record.instance_id) and pos_int?(record.owner_pid) and
      text?(record.owner_identity) and record.generation == 1 and
      (is_nil(record.owner_attested_at) or text?(record.owner_attested_at)) and
      state_fields?(record)
  end

  defp state_fields?(%{state: "claimed"} = r),
    do: is_nil(r.invocation_id) and launch_fields_nil?(r) and is_nil(r.owner_attested_at)

  defp state_fields?(%{state: "launch_pending"} = r),
    do: uuid?(r.invocation_id) and launch_fields_nil?(r)

  defp state_fields?(%{state: state} = r) when state in ["launched", "finished"],
    do:
      uuid?(r.invocation_id) and pos_int?(r.root_pid) and text?(r.root_identity) and
        pos_int?(r.session_id)

  defp state_fields?(_record), do: false

  defp launch_fields_nil?(r),
    do: is_nil(r.root_pid) and is_nil(r.root_identity) and is_nil(r.session_id)

  defp uuid?(value), do: is_binary(value) and value =~ @uuid
  defp pos_int?(value), do: is_integer(value) and value > 0
  defp text?(value), do: is_binary(value) and value != ""

  ## Writing

  defp make_lock(root) do
    lock = lock(root)

    case File.mkdir(lock) do
      :ok ->
        if File.chmod(lock, 0o700) == :ok, do: :ok, else: {:error, :launch_record_write_failed}

      {:error, :eexist} ->
        case File.lstat(lock) do
          {:ok, %File.Stat{type: :directory}} -> {:error, :calibration_in_progress}
          _symlink_or_other -> {:error, :launch_record_unsafe}
        end

      {:error, _reason} ->
        {:error, :launch_record_write_failed}
    end
  end

  # An atomic replace of the record, after the lock is checked private.
  defp write(root, record, opts) do
    lock = lock(root)
    replace = Keyword.get(opts, :replace, &File.rename/2)

    with :ok <- private_dir(lock) do
      case write_file(lock, "record.json", Jason.encode!(Map.new(record)), replace) do
        :ok -> :ok
        _failed -> {:error, :launch_record_write_failed}
      end
    end
  end

  defp write_file(dir, name, bytes, replace) do
    temp = Path.join(dir, ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))

    try do
      with {:ok, file} <- :file.open(temp, [:write, :exclusive, :binary, :raw]),
           :ok <- synced(file, bytes),
           :ok <- File.chmod(temp, 0o600) do
        replace.(temp, Path.join(dir, name))
      end
    after
      File.rm(temp)
    end
  end

  defp synced(file, bytes) do
    with :ok <- :file.write(file, bytes), do: :file.sync(file)
  after
    :file.close(file)
  end

  ## Private paths

  defp safe_root(root) do
    expanded = Path.expand(root)

    if no_symlink?(expanded) and private_dir(expanded) == :ok,
      do: :ok,
      else: {:error, :launch_record_unsafe}
  end

  defp no_symlink?(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))
  end

  defp private_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& 0o777) == 0o700 -> :ok
      _ -> {:error, :launch_record_unsafe}
    end
  end

  defp private_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o777) == 0o600 -> :ok
      _ -> {:error, :launch_record_unsafe}
    end
  end

  defp lock(root), do: Path.join(Path.expand(root), "run.lock")
  defp record_path(root), do: Path.join(lock(root), "record.json")
  defp ticket_dir(root), do: Path.join(lock(root), "recover")

  ## The probe

  defp probe(opts), do: Keyword.fetch!(opts, :probe)

  defp self_identity(probe) do
    with {:ok, {:ok, pid}} when is_integer(pid) and pid > 0 <- observe(&probe.self_pid/0),
         {:ok, {:ok, identity}} when is_binary(identity) and identity != "" <-
           observe(fn -> probe.start_identity(pid) end) do
      {:ok, pid, identity}
    else
      _ -> {:error, :probe_unavailable}
    end
  end

  # `{:ok, observation}` for a definite answer, `{:error, :probe_unavailable}`
  # for a failure or a raise. `session_members/1` and `self_pid/0` answers
  # are unwrapped by their callers.
  defp observe(fun) do
    case fun.() do
      {:error, _reason} -> {:error, :probe_unavailable}
      {:ok, members} when is_list(members) -> {:ok, members}
      answer -> {:ok, answer}
    end
  rescue
    _error -> {:error, :probe_unavailable}
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
