defmodule SdrAgent.CalibrationConsole.LaunchRecord do
  @moduledoc """
  The calibration console's durable single-flight launch record (R0-07
  slice E, row R11-1; harness round 13, entity PASS at 094caa86; staged E4a
  contract in the packet). File artifact only: the OS probe is E4b, and the
  database rules and the `calibrate` orchestration are E4c.

  Under a private `root`, `run.lock` (created by `mkdir`, mode 0700) holds
  `record.json` (mode 0600) in the closed schema
  `r0-calibration-launch-record/2`: `instance_id`, `owner_pid` and
  `owner_identity` (its start identity), `generation` 1, and a `state`
  with the fields it requires:

    * `claimed` (after preflight) — no launch can have happened;
    * `launch_pending` (`invocation_id`) — written after the invocation is
      `sent` and before the child is spawned;
    * `launched` (`root_pid`, `root_identity`, `process_group_id` — the
      CLI's own process group: macOS `ps` reports no session id);
    * `finished` — nothing outstanding; `release/3` then removes the lock.

  `owner_attested_at`, when present, is a canonical UTC timestamp. A
  schema-1 record (`session_id`) is never reinterpreted: it reads as
  unreadable and needs the owner.

  **Private, owner-local paths.** Every operation first requires that the
  root, `run.lock`, the record and any recovery ticket (`run.lock/recover`
  and its `ticket` file) are this user's, are not symlinks (nor is any
  ancestor), and are mode 0700 (directories) or 0600 (files). Otherwise
  `:launch_record_unsafe`.

  **The record on disk is authoritative.** `advance` needs the caller's
  record to equal it (`:invalid_transition`); `release` needs the finished
  record on disk, no recovery ticket (`:recovery_in_progress`) and nothing
  else in the lock (`:launch_record_unsafe`) before it deletes anything. A
  record is rewritten only by atomic replace (temporary file, sync, 0600,
  rename). A failed write or removal is `:launch_record_write_failed` and
  never reported as done.

  A missing, partial, malformed or wrongly shaped record reads as
  `%{state: "launch_pending", unreadable: true, fingerprint: _}` — never
  "no launch" — and never advances. The fingerprint (the SHA-256 of the
  bytes, or `"missing"`) lets a recoverer notice that it changed.

  **Recovery.** `recover/2` refuses a live owner (`:owner_alive`: the
  recorded pid alive with the recorded start identity) and an unreadable
  record (`:owner_unknown`) unless the owner passes the typed attestation
  `owner_verified_stopped: "STOPPED"`. It then claims `run.lock/recover`
  by `mkdir` and writes a ticket id into it; an existing ticket, even a
  partial or abandoned one, is `:recovery_in_progress` and is never taken
  over: the claim is the exclusive `mkdir` itself, so an existing
  directory, even an empty one, is never replaced. A contender that meets
  the new directory before it is made 0700 is refused as
  `:launch_record_unsafe` (fail-closed). `verify_recovery/3` re-reads the
  ticket (`:recovery_changed`) and
  the record (`:record_changed`); `end_recovery/3` removes only its own,
  complete ticket.

  **Quiescence** (`quiescence/2`): `claimed` and `finished` have nothing
  outstanding; a `launch_pending` or unreadable record needs the owner's
  attestation (`attest_stopped/4`, typed `STOPPED`); a `launched` record
  needs its process group successfully observed empty and its root absent
  or reused. Root death alone is never quiescence, and group emptiness is
  not a whole-descendant proof (a descendant can change its group; packet
  R11-1, staged E4b delta).

  **Probe** (`probe:`, a module): `self_pid/0` → `{:ok, pid}`,
  `start_identity/1` → `{:ok, identity}` or `:absent`, `group_members/1`
  → `{:ok, pids}` (`SdrAgent.CalibrationConsole.ProcessProbe` on macOS). Anything else — an error, a raise, or a malformed reply —
  is `:probe_unavailable`, never absence or an empty group: claim creates
  nothing, recovery is refused and quiescence is not established.

  **Test seams.** Only in test-seam builds are the `replace:` option (the
  final rename, run after every check) and the `owner_uid:` option (the
  expected owner) honoured; other builds always rename and compare with
  this process's uid.

  The directory entry is not synced (the runtime has no directory fsync):
  a power loss may lose a just-written record, which then reads as
  `launch_pending` and needs the owner.
  """

  import Bitwise

  @schema "r0-calibration-launch-record/2"
  @confirmation "STOPPED"
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @keys ~w(schema instance_id owner_pid owner_identity generation state invocation_id root_pid
           root_identity process_group_id owner_attested_at)a
  @order %{claimed: :launch_pending, launch_pending: :launched, launched: :finished}
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

  @type launch_record :: %{required(atom()) => term()}

  ## Claim and advance

  @doc """
  Claims the single flight for this console: `{:ok, record}` (`claimed`),
  `{:error, :calibration_in_progress}`, `{:error, :probe_unavailable}`
  (nothing is created), `:launch_record_unsafe` or
  `:launch_record_write_failed`.
  """
  def claim(root, opts) do
    with {:ok, env} <- env(opts),
         :ok <- safe_root(root, env),
         {:ok, pid, identity} <- self_identity(probe(opts)),
         :ok <- make_lock(root, env) do
      record =
        Map.merge(blank(), %{
          instance_id: Ash.UUIDv7.generate(),
          owner_pid: pid,
          owner_identity: identity,
          state: "claimed"
        })

      with :ok <- write(root, record, env), do: {:ok, record}
    end
  end

  @doc """
  Moves `record` (which must equal the record on disk) to `state` with its
  `attrs`: `claimed → launch_pending (invocation_id) → launched (root_pid,
  root_identity, process_group_id) → finished`. `{:ok, record}` or `{:error,
  :invalid_transition | :launch_record_unsafe | :launch_record_write_failed}`.
  """
  def advance(root, record, state, attrs, opts \\ []) do
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- same(current, record, :invalid_transition),
         {:ok, next} <- transition(current, state, attrs),
         :ok <- write(root, next, env) do
      {:ok, next}
    end
  end

  @doc """
  The record on disk: `{:ok, record}`, `{:ok, :none}` without a lock,
  `{:ok, %{state: "launch_pending", unreadable: true, fingerprint: _}}` for
  anything unreadable, or `{:error, :launch_record_unsafe}`.
  """
  def read(root, opts \\ []) do
    with {:ok, env} <- env(opts), do: read_safe(root, env)
  end

  @doc """
  Removes the lock of `record`, which must be the finished record on disk,
  with no recovery ticket and nothing else in the lock: `:ok`, or `{:error,
  :not_finished | :record_changed | :recovery_in_progress |
  :launch_record_unsafe | :launch_record_write_failed}`. Nothing is
  deleted on a refusal.
  """
  def release(root, record, opts \\ []) do
    lock = lock(root)

    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- same(current, record, :record_changed),
         :ok <- finished(current),
         :ok <- only(lock, ["record.json"], "recover") do
      removed(File.rm(record_path(root)), File.rmdir(lock))
    end
  end

  ## Recovery

  @doc """
  Claims recovery of a stale lock: `{:ok, %{record:, ticket:}}`, or
  `{:error, reason}` with `:owner_alive`, `:owner_unknown`,
  `:confirmation_mismatch`, `:probe_unavailable`, `:recovery_in_progress`,
  `:no_launch`, `:launch_record_unsafe` or `:launch_record_write_failed`.
  `owner_verified_stopped: "STOPPED"` is the owner's attestation for an
  unreadable record.
  """
  def recover(root, opts) do
    with {:ok, env} <- env(opts),
         {:ok, record} <- read_safe(root, env),
         :ok <- recoverable(record, opts),
         {:ok, ticket} <- make_ticket(root, env) do
      {:ok, %{record: record, ticket: ticket}}
    end
  end

  @doc """
  `:ok` while the recovery's own ticket and record are still on disk;
  `{:error, :recovery_changed | :record_changed | :launch_record_unsafe}`.
  """
  def verify_recovery(root, %{record: snapshot, ticket: ticket}, opts \\ []) do
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- own_ticket(root, ticket, env) do
      same(current, snapshot, :record_changed)
    end
  end

  @doc """
  Removes the recovery's own, complete ticket: `:ok`, or `{:error,
  :recovery_changed | :launch_record_unsafe | :launch_record_write_failed}`
  (the ticket stays).
  """
  def end_recovery(root, %{ticket: ticket}, opts \\ []) do
    dir = ticket_dir(root)

    with {:ok, env} <- env(opts),
         {:ok, _record} <- read_safe(root, env),
         :ok <- own_ticket(root, ticket, env) do
      case only(dir, ["ticket"], nil) do
        :ok -> removed(File.rm(Path.join(dir, "ticket")), File.rmdir(dir))
        {:error, _unexpected} -> {:error, :launch_record_write_failed}
      end
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
    if timestamp?(Map.get(record, :owner_attested_at)),
      do: :quiescent,
      else: :owner_verification_required
  end

  def quiescence(%{state: "launched"} = record, opts) do
    probe = probe(opts)

    with {:ok, members} <- observe(:group, fn -> probe.group_members(record.process_group_id) end),
         {:ok, root} <- observe(:identity, fn -> probe.start_identity(record.root_pid) end) do
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
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- same(current, record, :invalid_transition),
         :ok <- pending(current) do
      attested = %{current | owner_attested_at: now()}
      with :ok <- write(root, attested, env), do: {:ok, attested}
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

  defp fields(:launched, %{root_pid: pid, root_identity: identity, process_group_id: group})
       when is_integer(pid) and pid > 0 and is_binary(identity) and identity != "" and
              is_integer(group) and group > 0,
       do: {:ok, %{root_pid: pid, root_identity: identity, process_group_id: group}}

  defp fields(:finished, _attrs), do: {:ok, %{}}
  defp fields(_state, _attrs), do: :error

  defp finished(%{state: "finished"}), do: :ok
  defp finished(_record), do: {:error, :not_finished}

  defp pending(%{state: "launch_pending", unreadable: true}), do: {:error, :invalid_transition}
  defp pending(%{state: "launch_pending"}), do: :ok
  defp pending(_record), do: {:error, :invalid_transition}

  # Whole-map equality, the unreadable fingerprint included.
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
    case observe(:identity, fn -> probe(opts).start_identity(record.owner_pid) end) do
      {:ok, {:ok, identity}} when identity == record.owner_identity -> {:error, :owner_alive}
      {:ok, _absent_or_reused} -> :ok
      {:error, :probe_unavailable} = error -> error
    end
  end

  defp make_ticket(root, env) do
    dir = ticket_dir(root)

    case File.lstat(dir) do
      {:ok, _stat} -> {:error, :recovery_in_progress}
      {:error, :enoent} -> create_ticket(dir, env)
      {:error, _reason} -> {:error, :launch_record_unsafe}
    end
  end

  # The claim is the kernel-exclusive `mkdir` of `recover` itself: an
  # existing directory, even an empty partial one, is never replaced. The
  # directory is then made 0700 and its ticket written; a contender that
  # meets it before the chmod sees it unsafe and is refused (fail-closed).
  defp create_ticket(dir, env) do
    ticket = Ash.UUIDv7.generate()

    case File.mkdir(dir) do
      :ok -> fill_ticket(dir, ticket, env)
      {:error, :eexist} -> {:error, :recovery_in_progress}
      {:error, _reason} -> {:error, :launch_record_write_failed}
    end
  end

  defp fill_ticket(dir, ticket, env) do
    with :ok <- File.chmod(dir, 0o700),
         :ok <- write_file(dir, "ticket", ticket, env) do
      {:ok, ticket}
    else
      _failed ->
        # Our own, still ticketless directory: removed only if empty.
        File.rmdir(dir)
        {:error, :launch_record_write_failed}
    end
  end

  defp own_ticket(root, ticket, env) do
    path = Path.join(ticket_dir(root), "ticket")

    with :ok <- private_file(path, env),
         {:ok, ^ticket} <- File.read(path) do
      :ok
    else
      _missing_changed_or_unsafe -> {:error, :recovery_changed}
    end
  end

  ## Reading

  defp read_safe(root, env) do
    with :ok <- safe_root(root, env) do
      lock = lock(root)

      case File.lstat(lock) do
        {:error, :enoent} -> {:ok, :none}
        {:ok, _stat} -> read_lock(lock, env)
        {:error, _reason} -> {:error, :launch_record_unsafe}
      end
    end
  end

  defp read_lock(lock, env) do
    with :ok <- private_dir(lock, env),
         :ok <- private_recovery(Path.join(lock, "recover"), env) do
      path = Path.join(lock, "record.json")

      case File.lstat(path) do
        {:error, :enoent} -> {:ok, unreadable("missing")}
        {:ok, _stat} -> read_record(path, env)
        {:error, _reason} -> {:error, :launch_record_unsafe}
      end
    end
  end

  # A present recovery directory, and its ticket file when written, must be
  # private; an absent ticket file is a partial ticket (still blocking).
  defp private_recovery(dir, env) do
    case File.lstat(dir) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> with :ok <- private_dir(dir, env), do: private_ticket(dir, env)
      {:error, _reason} -> {:error, :launch_record_unsafe}
    end
  end

  defp private_ticket(dir, env) do
    ticket = Path.join(dir, "ticket")

    case File.lstat(ticket) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> private_file(ticket, env)
      {:error, _reason} -> {:error, :launch_record_unsafe}
    end
  end

  defp read_record(path, env) do
    with :ok <- private_file(path, env),
         {:ok, bytes} <- File.read(path) do
      {:ok, parse(bytes)}
    else
      {:error, :launch_record_unsafe} = unsafe -> unsafe
      _unreadable -> {:ok, unreadable("unreadable")}
    end
  end

  defp parse(bytes) do
    with {:ok, %{} = decoded} <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(decoded)) == Enum.sort(Enum.map(@keys, &Atom.to_string/1)),
         record = Map.new(@keys, &{&1, Map.fetch!(decoded, Atom.to_string(&1))}),
         true <- valid?(record) do
      record
    else
      _ -> unreadable(Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))
    end
  end

  defp unreadable(fingerprint),
    do: %{state: "launch_pending", unreadable: true, fingerprint: fingerprint}

  defp valid?(record) do
    record.schema == @schema and uuid?(record.instance_id) and pos_int?(record.owner_pid) and
      text?(record.owner_identity) and record.generation == 1 and
      (is_nil(record.owner_attested_at) or timestamp?(record.owner_attested_at)) and
      state_fields?(record)
  end

  defp state_fields?(%{state: "claimed"} = r),
    do: is_nil(r.invocation_id) and launch_fields_nil?(r) and is_nil(r.owner_attested_at)

  defp state_fields?(%{state: "launch_pending"} = r),
    do: uuid?(r.invocation_id) and launch_fields_nil?(r)

  defp state_fields?(%{state: state} = r) when state in ["launched", "finished"],
    do:
      uuid?(r.invocation_id) and pos_int?(r.root_pid) and text?(r.root_identity) and
        pos_int?(r.process_group_id)

  defp state_fields?(_record), do: false

  defp launch_fields_nil?(r),
    do: is_nil(r.root_pid) and is_nil(r.root_identity) and is_nil(r.process_group_id)

  defp uuid?(value), do: is_binary(value) and value =~ @uuid
  defp pos_int?(value), do: is_integer(value) and value > 0
  defp text?(value), do: is_binary(value) and value != ""

  # A canonical UTC timestamp that round-trips exactly.
  defp timestamp?(value) when is_binary(value) do
    with true <- value =~ @timestamp,
         {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
      DateTime.to_iso8601(datetime) == value
    else
      _ -> false
    end
  end

  defp timestamp?(_value), do: false

  ## Writing and removing

  defp make_lock(root, env) do
    lock = lock(root)

    case File.mkdir(lock) do
      :ok ->
        if File.chmod(lock, 0o700) == :ok, do: :ok, else: {:error, :launch_record_write_failed}

      {:error, :eexist} ->
        with :ok <- private_dir(lock, env), do: {:error, :calibration_in_progress}

      {:error, _reason} ->
        {:error, :launch_record_write_failed}
    end
  end

  # An atomic replace of the record, after the lock is checked private.
  defp write(root, record, env) do
    lock = lock(root)

    with :ok <- private_dir(lock, env) do
      case write_file(lock, "record.json", Jason.encode!(Map.new(record)), env) do
        :ok -> :ok
        _failed -> {:error, :launch_record_write_failed}
      end
    end
  end

  defp write_file(dir, name, bytes, env) do
    temp = Path.join(dir, ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))

    try do
      with {:ok, file} <- :file.open(temp, [:write, :exclusive, :binary, :raw]),
           :ok <- synced(file, bytes),
           :ok <- File.chmod(temp, 0o600) do
        env.replace.(temp, Path.join(dir, name))
      end
    rescue
      _error -> {:error, :write_raised}
    after
      File.rm(temp)
    end
  end

  defp synced(file, bytes) do
    with :ok <- :file.write(file, bytes), do: :file.sync(file)
  after
    :file.close(file)
  end

  # `dir` holds exactly `expected` (a `busy` entry is `:recovery_in_progress`;
  # anything else `:launch_record_unsafe`), checked before any removal.
  defp only(dir, expected, busy) do
    case File.ls(dir) do
      {:ok, entries} -> entries_are(entries, expected, busy)
      {:error, _reason} -> {:error, :launch_record_unsafe}
    end
  end

  defp entries_are(entries, expected, busy) do
    cond do
      busy && busy in entries -> {:error, :recovery_in_progress}
      Enum.sort(entries) == Enum.sort(expected) -> :ok
      true -> {:error, :launch_record_unsafe}
    end
  end

  defp removed(:ok, :ok), do: :ok
  defp removed(_file, _dir), do: {:error, :launch_record_write_failed}

  ## Private, owner-local paths

  # The expected owner and the final rename. Only test-seam builds honour
  # the `owner_uid:` and `replace:` options.
  defp env(opts) do
    with {:ok, uid} <- expected_uid(opts) do
      {:ok, %{uid: uid, replace: replace(opts)}}
    end
  end

  if @test_seams do
    defp expected_uid(opts) do
      case Keyword.fetch(opts, :owner_uid) do
        {:ok, uid} when is_integer(uid) -> {:ok, uid}
        _absent -> own_uid()
      end
    end

    defp replace(opts), do: Keyword.get(opts, :replace, &File.rename/2)
  else
    defp expected_uid(_opts), do: own_uid()
    defp replace(_opts), do: &File.rename/2
  end

  # This process's uid: the owner of a file it has just created (no
  # external command is launched).
  defp own_uid do
    probe =
      Path.join(
        System.tmp_dir!(),
        ".sdr-uid-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    case :file.open(probe, [:write, :exclusive, :raw]) do
      {:ok, file} ->
        :file.close(file)
        probe_owner(probe)

      _cannot_create ->
        {:error, :launch_record_unsafe}
    end
  end

  defp probe_owner(probe) do
    case File.lstat(probe) do
      {:ok, %File.Stat{uid: uid}} -> {:ok, uid}
      _ -> {:error, :launch_record_unsafe}
    end
  after
    File.rm(probe)
  end

  defp safe_root(root, env) do
    expanded = Path.expand(root)

    if no_symlink?(expanded) and private_dir(expanded, env) == :ok,
      do: :ok,
      else: {:error, :launch_record_unsafe}
  end

  defp no_symlink?(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))
  end

  defp private_dir(path, %{uid: uid}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode, uid: ^uid}} when (mode &&& 0o777) == 0o700 ->
        :ok

      _ ->
        {:error, :launch_record_unsafe}
    end
  end

  defp private_file(path, %{uid: uid}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode, uid: ^uid}} when (mode &&& 0o777) == 0o600 ->
        :ok

      _ ->
        {:error, :launch_record_unsafe}
    end
  end

  defp lock(root), do: Path.join(Path.expand(root), "run.lock")
  defp record_path(root), do: Path.join(lock(root), "record.json")
  defp ticket_dir(root), do: Path.join(lock(root), "recover")

  ## The probe

  defp probe(opts), do: Keyword.fetch!(opts, :probe)

  defp self_identity(probe) do
    with {:ok, pid} <- observe(:pid, &probe.self_pid/0),
         {:ok, {:ok, identity}} <- observe(:identity, fn -> probe.start_identity(pid) end) do
      {:ok, pid, identity}
    else
      _ -> {:error, :probe_unavailable}
    end
  end

  # Only a well-formed answer of the asked kind is an observation; an
  # error, a raise or anything malformed is `{:error, :probe_unavailable}`.
  defp observe(kind, fun) do
    case classify(kind, fun.()) do
      {:ok, _observation} = observation -> observation
      :error -> {:error, :probe_unavailable}
    end
  rescue
    _error -> {:error, :probe_unavailable}
  end

  defp classify(:pid, {:ok, pid}) when is_integer(pid) and pid > 0, do: {:ok, pid}
  defp classify(:identity, :absent), do: {:ok, :absent}

  defp classify(:identity, {:ok, identity}) when is_binary(identity) and identity != "",
    do: {:ok, {:ok, identity}}

  defp classify(:group, {:ok, pids}) when is_list(pids) do
    if Enum.all?(pids, &(is_integer(&1) and &1 > 0)), do: {:ok, pids}, else: :error
  end

  defp classify(_kind, _reply), do: :error

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
