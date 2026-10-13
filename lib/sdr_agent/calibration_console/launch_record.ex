defmodule SdrAgent.CalibrationConsole.LaunchRecord do
  @moduledoc """
  The calibration console's durable single-flight launch record (R0-07
  slice E, row R11-1; harness round 13, entity PASS at 094caa86; staged E4a
  contract; schema 3 from the E4c delta, entity PASS at 25c1b18). File
  artifact only: the OS probe is E4b, and the database rules and the
  `calibrate` orchestration are the rest of E4c.

  Under a private `root`, `run.lock` (created by `mkdir`, mode 0700) holds
  `record.json` (mode 0600) in the closed schema
  `r0-calibration-launch-record/3`: `instance_id`, `owner_pid` and
  `owner_identity` (its start identity), `generation` 1, and a `state`
  with exactly the fields it allows (every other field null):

    * `claimed` (after preflight) — no launch can have happened;
    * `launch_pending` (`invocation_id`) — written before the invocation is
      `sent` and the child is spawned;
    * `launched` (`invocation_id`, `root_pid`, `root_identity`,
      `process_group_id` — the CLI's own process group: macOS `ps` reports
      no session id);
    * `finished` (the launched fields) — after the cleanup receipt;
    * `aborted` (from `claimed` or `launch_pending`; `invocation_id` kept
      when present, no launch fields) — no launch happened;
    * `recovered` (only under a recovery handle) — from `launch_pending`
      with the `attestation_id` of the ticket's owner attestation, or from
      `launched` (fields kept) by observed quiescence (`attestation_id`
      null) or by attestation, where observed live work still refuses.

  Only `aborted`, `finished` and `recovered` release. `owner_attested_at`
  is always null (superseded by the attestation artifact), and
  `attestation_id` is set only by an attested `recovered` finalization.
  Schema-1 and schema-2 records are never reinterpreted: they read as
  unreadable.

  **Private, owner-local paths.** Every operation first requires that the
  root, `run.lock`, the record and any recovery ticket (`run.lock/recover`
  and its `ticket` file) are this user's, are not symlinks (nor is any
  ancestor), and are mode 0700 (directories) or 0600 (files). Otherwise
  `:launch_record_unsafe`.

  **The record on disk is authoritative.** `advance` needs the caller's
  record to equal it (`:invalid_transition`). A record is rewritten only by
  atomic replace (temporary file, sync, 0600, rename). A failed write is
  `:launch_record_write_failed` and never reported as done.

  **Authority.** `aborted` and a release are the live owner's (`probe:`
  confirms this process is the recorded owner: `:not_owner` otherwise,
  `:recovery_in_progress` while any ticket exists), or the recovery
  handle's (`recovery:`, whose own ticket and claim must still be on disk:
  `:recovery_changed`, `:record_changed`). `recovered` is the handle's only
  (`:recovery_required`).

  **Release** re-checks the evidence bound to the final state before it
  removes anything: `finished` its quiescence again, `recovered` its
  attestation (`:attestation_mismatch`) and, with launch fields, no
  observed live work (`:not_quiescent`). The lock may hold only the record
  and, under a handle, the handle's ticket directory. The record is
  removed first, so a partial release leaves an unreadable remnant:
  `:calibration_owner_conflict`, a hard stop that never resumes. A failure
  before anything is removed is `:launch_record_write_failed` and leaves
  the record whole.

  A missing, partial, malformed or wrongly shaped record reads as
  `%{state: "launch_pending", unreadable: true, fingerprint: _}` — never
  "no launch" — and never advances. The fingerprint (the SHA-256 of the
  bytes, or `"missing"`) lets a recoverer notice that it changed.

  **Recovery.** `recover/2` refuses a live owner (`:owner_alive`: the
  recorded pid alive with the recorded start identity) and an unreadable
  record (`:owner_unknown`, a hard owner conflict that no typed answer
  unlocks: E4c round 4). It then claims `run.lock/recover`
  by `mkdir` and writes a ticket id into it; an existing ticket, even a
  partial or abandoned one, is `:recovery_in_progress` and is never taken
  over: the claim is the exclusive `mkdir` itself, so an existing
  directory, even an empty one, is never replaced. A contender that meets
  the new directory before it is made 0700 is refused as
  `:launch_record_unsafe` (fail-closed). `verify_recovery/3` re-reads the
  ticket (`:recovery_changed`) and
  the record (`:record_changed`); `end_recovery/3` removes only its own,
  complete ticket. A ticket is never adopted or erased by another process:
  a recoverer that dies leaves a hard owner conflict.

  **Attestation** (E4c-4): `new_attestation/1` builds the owner's
  attestation for a handle (`launch_pending` or `launched` only), bound to
  its claim, invocation, ticket and observation; the console appends its
  audit event first, then `write_attestation/4` writes `attestation.json`
  (0600) in the ticket. The same attestation again is a replay; another is
  `:attestation_conflict`.

  **Quiescence** (`quiescence/2`): `claimed` and `aborted` have nothing
  outstanding; a `launch_pending` or unreadable record needs the owner; a
  `launched`, `finished` or launched-`recovered` record needs its process
  group successfully observed empty and its root absent or reused. Root
  death alone is never quiescence, and group emptiness is not a
  whole-descendant proof (a descendant can change its group; packet R11-1,
  staged E4b delta).

  **Probe** (`probe:`, a module): `self_pid/0` → `{:ok, pid}`,
  `start_identity/1` → `{:ok, identity}` or `:absent`, `group_members/1`
  → `{:ok, pids}` (`SdrAgent.CalibrationConsole.ProcessProbe` on macOS). Anything else — an error, a raise, or a malformed reply —
  is `:probe_unavailable`, never absence or an empty group: claim creates
  nothing, recovery is refused and quiescence is not established.

  **Test seams.** Only in test-seam builds are the `replace:` option (the
  final rename, run after every check), the `remove:` option (each release
  removal) and the `owner_uid:` option (the expected owner) honoured; other
  builds always rename, remove and compare with this process's uid.

  The directory entry is not synced (the runtime has no directory fsync):
  a power loss may lose a just-written record, which then reads as
  `launch_pending` and needs the owner.
  """

  import Bitwise

  @schema "r0-calibration-launch-record/3"
  @attestation_schema "r0-calibration-attestation/1"
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @keys ~w(schema instance_id owner_pid owner_identity generation state invocation_id root_pid
           root_identity process_group_id owner_attested_at attestation_id)a
  @attestation_keys ~w(schema attestation_id instance_id invocation_id ticket_id observation
                       confirmed_at)a
  @observation_keys ~w(state root_pid process_group_id)a
  @next %{
    claimed: [:launch_pending, :aborted],
    launch_pending: [:launched, :aborted, :recovered],
    launched: [:finished, :recovered]
  }
  @final ~w(aborted finished recovered)
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
  root_identity, process_group_id) → finished`; `aborted` (no attrs) from
  `claimed` or `launch_pending`; `recovered` (`attestation_id`, nil or the
  ticket's attestation) from `launch_pending` or `launched`, under the
  recovery handle. `{:ok, record}` or `{:error, :invalid_transition |
  :not_owner | :recovery_required | :recovery_in_progress |
  :recovery_changed | :attestation_mismatch | :owner_verification_required
  | :not_quiescent | :probe_unavailable | :launch_record_unsafe |
  :launch_record_write_failed}`.
  """
  def advance(root, record, state, attrs, opts \\ []) do
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- same(current, record, :invalid_transition),
         {:ok, next} <- transition(current, state, attrs),
         :ok <- authorized(root, current, state, opts, env),
         :ok <- evidence(root, current, next, opts, env),
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
  Removes the lock of `record`, which must be the final (`aborted`,
  `finished` or `recovered`) record on disk, by its live owner or its
  recovery handle (`recovery:`), after re-checking the state's evidence:
  `:ok`, or `{:error, :not_finished | :record_changed | :not_owner |
  :recovery_in_progress | :recovery_required | :recovery_changed |
  :attestation_mismatch | :not_quiescent | :probe_unavailable |
  :launch_record_unsafe | :launch_record_write_failed |
  :calibration_owner_conflict}`. Nothing is deleted on a refusal.
  """
  def release(root, record, opts \\ []) do
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- same(current, record, :record_changed),
         :ok <- final(current),
         :ok <- authorized(root, current, :release, opts, env),
         :ok <- release_entries(root, opts),
         :ok <- still_stopped(root, current, opts, env) do
      remove_all(root, env)
    end
  end

  ## Recovery

  @doc """
  Claims recovery of a stale lock: `{:ok, %{record:, ticket:}}`, or
  `{:error, reason}` with `:owner_alive`, `:owner_unknown` (unreadable: a
  hard owner conflict), `:probe_unavailable`, `:recovery_in_progress`,
  `:no_launch`, `:launch_record_unsafe` or `:launch_record_write_failed`.
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

  def quiescence(%{state: state}, _opts) when state in ["claimed", "aborted"], do: :quiescent

  def quiescence(%{state: "launch_pending"}, _opts), do: :owner_verification_required

  def quiescence(%{state: state} = record, opts)
      when state in ["launched", "finished", "recovered"] do
    if launch_fields_nil?(record), do: :quiescent, else: observed_stopped(record, opts)
  end

  def quiescence(_record, _opts), do: :owner_verification_required

  # The group observed empty and the root absent or reused. Both are always
  # observed: live work seen by either wins over a failure of the other.
  defp observed_stopped(record, opts) do
    probe = probe(opts)
    group = observe(:group, fn -> probe.group_members(record.process_group_id) end)
    root = observe(:identity, fn -> probe.start_identity(record.root_pid) end)

    cond do
      match?({:ok, [_ | _]}, group) or root == {:ok, {:ok, record.root_identity}} ->
        :not_quiescent

      match?({:error, _}, group) or match?({:error, _}, root) ->
        {:error, :probe_unavailable}

      true ->
        :quiescent
    end
  end

  ## Attestation (E4c-4)

  @doc """
  A fresh owner attestation for the recovery `handle`: `{:ok, attestation}`
  bound to the handle's record (`instance_id`, `invocation_id`), its ticket
  and the attested observation (`state`, `root_pid`, `process_group_id`),
  with a new `attestation_id` and `confirmed_at`. Only a `launch_pending`
  or `launched` record has anything to attest (`{:error,
  :invalid_transition}`). It is pure: the console appends its audit event
  first, then `write_attestation/4`.
  """
  def new_attestation(%{record: %{state: state} = record, ticket: ticket})
      when state in ["launch_pending", "launched"] do
    if Map.get(record, :unreadable) do
      {:error, :invalid_transition}
    else
      {:ok,
       %{
         schema: @attestation_schema,
         attestation_id: Ash.UUIDv7.generate(),
         instance_id: record.instance_id,
         invocation_id: record.invocation_id,
         ticket_id: ticket,
         observation: observation(record),
         confirmed_at: now()
       }}
    end
  end

  def new_attestation(_handle), do: {:error, :invalid_transition}

  @doc """
  Writes `attestation` (0600) as `attestation.json` in the handle's own
  ticket, never in the record: `{:ok, attestation}`; the same attestation
  again is a replay. `{:error, :attestation_mismatch}` when it does not
  bind this handle's record, ticket and observation; `:attestation_conflict`
  when another one is already written; `:recovery_changed`,
  `:launch_record_unsafe` or `:launch_record_write_failed`.
  """
  def write_attestation(root, handle, attestation, opts \\ []) do
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- own_ticket(root, handle.ticket, env),
         :ok <- bound(attestation, current, handle.ticket) do
      case stored_attestation(root, env) do
        {:ok, :none} -> create_attestation(root, attestation, env)
        {:ok, ^attestation} -> {:ok, attestation}
        {:ok, _other} -> {:error, :attestation_conflict}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  The attestation in the handle's own ticket: `{:ok, attestation}`, `{:ok,
  :none}`, or `{:error, :attestation_mismatch | :recovery_changed |
  :launch_record_unsafe}`.
  """
  def read_attestation(root, handle, opts \\ []) do
    with {:ok, env} <- env(opts),
         {:ok, current} <- read_safe(root, env),
         :ok <- own_ticket(root, handle.ticket, env),
         {:ok, stored} <- stored_attestation(root, env) do
      checked(stored, current, handle.ticket)
    end
  end

  defp checked(:none, _record, _ticket), do: {:ok, :none}

  defp checked(stored, record, ticket),
    do: with(:ok <- bound(stored, record, ticket), do: {:ok, stored})

  defp create_attestation(root, attestation, env) do
    case write_file(ticket_dir(root), "attestation.json", Jason.encode!(attestation), env) do
      :ok -> {:ok, attestation}
      _failed -> {:error, :launch_record_write_failed}
    end
  end

  defp stored_attestation(root, env) do
    path = attestation_path(root)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, :none}

      {:ok, _stat} ->
        with :ok <- private_file(path, env),
             {:ok, bytes} <- File.read(path) do
          parse_attestation(bytes)
        else
          {:error, :launch_record_unsafe} = unsafe -> unsafe
          _unreadable -> {:error, :attestation_mismatch}
        end

      {:error, _reason} ->
        {:error, :launch_record_unsafe}
    end
  end

  defp parse_attestation(bytes) do
    with {:ok, %{} = decoded} <- Jason.decode(bytes),
         true <- closed?(decoded, @attestation_keys),
         %{} = observed <- decoded["observation"],
         true <- closed?(observed, @observation_keys) do
      attestation = atomize(decoded, @attestation_keys)
      {:ok, %{attestation | observation: atomize(observed, @observation_keys)}}
    else
      _ -> {:error, :attestation_mismatch}
    end
  end

  defp closed?(decoded, keys),
    do: Enum.sort(Map.keys(decoded)) == Enum.sort(Enum.map(keys, &Atom.to_string/1))

  defp atomize(decoded, keys), do: Map.new(keys, &{&1, Map.fetch!(decoded, Atom.to_string(&1))})

  # The attestation binds this record (its claim, invocation and attested
  # observation) and this ticket, and is well formed.
  defp bound(attestation, record, ticket) do
    if is_map(attestation) and not Map.has_key?(record, :unreadable) and
         well_formed?(attestation) and binds?(attestation, record, ticket),
       do: :ok,
       else: {:error, :attestation_mismatch}
  end

  defp well_formed?(attestation) do
    Map.get(attestation, :schema) == @attestation_schema and
      uuid?(Map.get(attestation, :attestation_id)) and
      timestamp?(Map.get(attestation, :confirmed_at))
  end

  defp binds?(attestation, record, ticket) do
    uuid?(record.invocation_id) and
      Map.take(attestation, [:ticket_id, :instance_id, :invocation_id, :observation]) ==
        %{
          ticket_id: ticket,
          instance_id: record.instance_id,
          invocation_id: record.invocation_id,
          observation: observation(record)
        }
  end

  # What a recovery attests. A `recovered` record keeps the observation of
  # the state it was recovered from: no launch fields means `launch_pending`.
  defp observation(%{state: "recovered"} = record) do
    from = if launch_fields_nil?(record), do: "launch_pending", else: "launched"
    observation(%{record | state: from})
  end

  defp observation(record),
    do: %{
      state: record.state,
      root_pid: record.root_pid,
      process_group_id: record.process_group_id
    }

  ## Transitions

  # An unreadable record never advances: only recovery may act on it.
  defp transition(%{unreadable: true}, _state, _attrs), do: {:error, :invalid_transition}

  defp transition(%{state: from} = current, state, attrs) when is_atom(state) do
    from = String.to_existing_atom(from)

    with true <- state in Map.get(@next, from, []),
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

  # An abort keeps the invocation id (if any) and clears no history: a
  # record that can abort has no launch fields.
  defp fields(:aborted, attrs) when attrs == %{}, do: {:ok, %{}}

  defp fields(:recovered, %{attestation_id: id} = attrs) when map_size(attrs) == 1 do
    if is_nil(id) or uuid?(id), do: {:ok, %{attestation_id: id}}, else: :error
  end

  defp fields(_state, _attrs), do: :error

  defp final(%{state: state} = record) when state in @final do
    if Map.has_key?(record, :unreadable), do: {:error, :not_finished}, else: :ok
  end

  defp final(_record), do: {:error, :not_finished}

  ## Authority and evidence

  # Who may write a final state or release: `recovered` only under the
  # recovery handle that holds the ticket; `aborted` and a release either
  # under that handle or by the live owner with no ticket on disk. The
  # forward launch states stay the owner's own steps.
  defp authorized(root, current, step, opts, env) when step in [:aborted, :recovered, :release] do
    case Keyword.fetch(opts, :recovery) do
      {:ok, handle} -> handle_holds(root, current, handle, env)
      :error -> owner_holds(root, current, step, opts)
    end
  end

  defp authorized(_root, _current, _step, _opts, _env), do: :ok

  defp handle_holds(root, current, %{record: snapshot, ticket: ticket}, env) do
    with :ok <- own_ticket(root, ticket, env) do
      if same_claim?(snapshot, current), do: :ok, else: {:error, :record_changed}
    end
  end

  defp handle_holds(_root, _current, _handle, _env), do: {:error, :recovery_changed}

  defp same_claim?(snapshot, current) do
    not Map.has_key?(snapshot, :unreadable) and
      Map.take(snapshot, [:instance_id, :owner_pid, :owner_identity]) ==
        Map.take(current, [:instance_id, :owner_pid, :owner_identity])
  end

  defp owner_holds(root, current, step, opts) do
    cond do
      File.exists?(ticket_dir(root)) -> {:error, :recovery_in_progress}
      step == :recovered or current.state == "recovered" -> {:error, :recovery_required}
      true -> live_owner(current, opts)
    end
  end

  defp live_owner(current, opts) do
    case self_identity(probe(opts)) do
      {:ok, pid, identity} when pid == current.owner_pid and identity == current.owner_identity ->
        :ok

      {:ok, _pid, _identity} ->
        {:error, :not_owner}

      error ->
        error
    end
  end

  # The evidence a recovered finalization binds (E4c-2/E4c-4).
  defp evidence(root, %{state: "launch_pending"}, %{state: "recovered"} = next, opts, env) do
    case next.attestation_id do
      nil -> {:error, :owner_verification_required}
      _id -> attested(root, next, opts, env)
    end
  end

  defp evidence(root, %{state: "launched"}, %{state: "recovered"} = next, opts, env) do
    case next.attestation_id do
      nil -> quiescent(next, opts)
      _id -> with :ok <- attested(root, next, opts, env), do: no_live_work(next, opts)
    end
  end

  defp evidence(_root, _current, _next, _opts, _env), do: :ok

  # The handle's ticket holds the attestation whose id the record carries.
  defp attested(root, record, opts, env) do
    {:ok, handle} = Keyword.fetch(opts, :recovery)

    case stored_attestation(root, env) do
      {:ok, %{attestation_id: id} = stored} when id == record.attestation_id ->
        bound(stored, record, handle.ticket)

      {:ok, _none_or_other} ->
        {:error, :attestation_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp quiescent(record, opts) do
    case quiescence(record, opts) do
      :quiescent -> :ok
      :not_quiescent -> {:error, :not_quiescent}
      :owner_verification_required -> {:error, :owner_verification_required}
      {:error, _reason} = error -> error
    end
  end

  # An attestation covers an unavailable probe, never observed live work.
  defp no_live_work(record, opts) do
    case observed_stopped(record, opts) do
      :not_quiescent -> {:error, :not_quiescent}
      _quiescent_or_unavailable -> :ok
    end
  end

  # A final state is not itself quiescence: release re-checks the evidence
  # bound to it, and live work always wins.
  defp still_stopped(_root, %{state: "aborted"}, _opts, _env), do: :ok

  defp still_stopped(_root, %{state: "finished"} = record, opts, _env),
    do: quiescent(record, opts)

  defp still_stopped(_root, %{state: "recovered", attestation_id: nil} = record, opts, _env),
    do: quiescent(record, opts)

  defp still_stopped(root, %{state: "recovered"} = record, opts, env) do
    with :ok <- attested(root, record, opts, env) do
      if launch_fields_nil?(record), do: :ok, else: no_live_work(record, opts)
    end
  end

  # Whole-map equality, the unreadable fingerprint included.
  defp same(current, record, error), do: if(current == record, do: :ok, else: {:error, error})

  defp blank, do: Map.new(@keys, &{&1, nil}) |> Map.merge(%{schema: @schema, generation: 1})

  ## Recovery checks

  defp recoverable(:none, _opts), do: {:error, :no_launch}

  # Unbindable: a hard owner conflict that no typed answer unlocks.
  defp recoverable(%{unreadable: true}, _opts), do: {:error, :owner_unknown}

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
    Enum.reduce_while(["ticket", "attestation.json"], :ok, fn name, :ok ->
      case private_entry(Path.join(dir, name), env) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp private_entry(path, env) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> private_file(path, env)
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
      is_nil(record.owner_attested_at) and state_fields?(record)
  end

  # The nullable fields of every state (E4c bound 3): `attestation_id` is
  # set only by an owner-attested `recovered` finalization.
  defp state_fields?(%{state: "claimed"} = r),
    do: is_nil(r.invocation_id) and launch_fields_nil?(r) and is_nil(r.attestation_id)

  defp state_fields?(%{state: "launch_pending"} = r),
    do: uuid?(r.invocation_id) and launch_fields_nil?(r) and is_nil(r.attestation_id)

  defp state_fields?(%{state: state} = r) when state in ["launched", "finished"],
    do: uuid?(r.invocation_id) and launch_fields?(r) and is_nil(r.attestation_id)

  defp state_fields?(%{state: "aborted"} = r),
    do:
      (is_nil(r.invocation_id) or uuid?(r.invocation_id)) and launch_fields_nil?(r) and
        is_nil(r.attestation_id)

  defp state_fields?(%{state: "recovered"} = r) do
    uuid?(r.invocation_id) and
      ((launch_fields_nil?(r) and uuid?(r.attestation_id)) or
         (launch_fields?(r) and (is_nil(r.attestation_id) or uuid?(r.attestation_id))))
  end

  defp state_fields?(_record), do: false

  defp launch_fields?(r),
    do: pos_int?(r.root_pid) and text?(r.root_identity) and pos_int?(r.process_group_id)

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

  # The lock holds the record, plus the recovery's own ticket directory
  # (its ticket and any attestation) only under a handle; anything else is
  # refused before any removal.
  defp release_entries(root, opts) do
    if Keyword.has_key?(opts, :recovery) do
      with :ok <- only(lock(root), ["record.json", "recover"], nil) do
        recovery_entries(ticket_dir(root))
      end
    else
      only(lock(root), ["record.json"], "recover")
    end
  end

  defp recovery_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        if "ticket" in entries and entries -- ["ticket", "attestation.json"] == [],
          do: :ok,
          else: {:error, :launch_record_unsafe}

      {:error, _reason} ->
        {:error, :launch_record_unsafe}
    end
  end

  # The record goes first, so any partial release leaves an unreadable
  # remnant (a hard owner conflict that never resumes). A failure before
  # anything is removed leaves the record whole and replayable.
  defp remove_all(root, env) do
    dir = ticket_dir(root)

    later =
      [Path.join(dir, "attestation.json"), Path.join(dir, "ticket"), dir]
      |> Enum.filter(&match?({:ok, _}, File.lstat(&1)))
      |> Kernel.++([lock(root)])

    case env.remove.(record_path(root)) do
      :ok ->
        if Enum.all?(later, &(env.remove.(&1) == :ok)),
          do: :ok,
          else: {:error, :calibration_owner_conflict}

      _failed ->
        {:error, :launch_record_write_failed}
    end
  end

  ## Private, owner-local paths

  # The expected owner and the final rename. Only test-seam builds honour
  # the `owner_uid:` and `replace:` options.
  defp env(opts) do
    with {:ok, uid} <- expected_uid(opts) do
      {:ok, %{uid: uid, replace: replace(opts), remove: remove(opts)}}
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
    defp remove(opts), do: Keyword.get(opts, :remove, &remove_path/1)
  else
    defp expected_uid(_opts), do: own_uid()
    defp replace(_opts), do: &File.rename/2
    defp remove(_opts), do: &remove_path/1
  end

  defp remove_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> File.rmdir(path)
      {:ok, _stat} -> File.rm(path)
      {:error, _reason} = error -> error
    end
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
  defp attestation_path(root), do: Path.join(ticket_dir(root), "attestation.json")

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
