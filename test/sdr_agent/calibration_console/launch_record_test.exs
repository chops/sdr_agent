defmodule SdrAgent.CalibrationConsole.LaunchRecordTest do
  @moduledoc """
  R0-07 slice E, row R11-1 (harness round 13, entity PASS at 094caa86):
  the console's durable single-flight launch record and its recovery.

  `run.lock` (created by `mkdir`, mode 0700) holds `record.json` (0600,
  rewritten only by atomic replace): console instance id, owner OS pid and
  its start identity, invocation id, launch generation 1, and a state
  `claimed` → `launch_pending` → `launched` (with the CLI root pid, its
  start identity and its session id) → `finished`.

  Only recovery may take over a stale lock, and only when the recorded
  owner is provably gone (pid absent, or alive with another start
  identity); it claims `run.lock/recover` atomically, so a second recoverer
  fails, and re-reads the record. A missing, partial or malformed record is
  never "no launch": it reads as `launch_pending`. Quiescence of a
  `launched` record needs no process in its session and the root absent or
  reused; a `launch_pending` one needs the owner's typed attestation. Root
  death alone is never quiescence.

  OS process facts come from an injected probe (`FakeProbe`), so nothing is
  launched here.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.CalibrationConsole.LaunchRecord

  defmodule FakeProbe do
    @moduledoc false
    # OS facts for the tests: start identities by pid, session members by
    # session id, and this process's own pid. A value `{:error, reason}` is
    # returned as an observation failure; `:raise` makes the lookup raise.
    use Agent

    def start_link(_),
      do:
        Agent.start_link(
          fn -> %{identities: %{4242 => "Mon 10:00 owner"}, groups: %{}, self: 4242} end,
          name: __MODULE__
        )

    def put(fun), do: Agent.update(__MODULE__, fun)

    def self_pid, do: __MODULE__ |> Agent.get(& &1.self) |> result(&{:ok, &1})

    def start_identity(pid) do
      case Agent.get(__MODULE__, &Map.fetch(&1.identities, pid)) do
        :error -> :absent
        {:ok, value} -> result(value, &{:ok, &1})
      end
    end

    def group_members(process_group_id),
      do: __MODULE__ |> Agent.get(&Map.get(&1.groups, process_group_id, [])) |> result(&{:ok, &1})

    # `{:raw, reply}` returns `reply` itself (malformed answers).
    defp result({:raw, reply}, _ok), do: reply
    defp result(:raise, _ok), do: raise("synthetic probe failure")
    defp result({:error, _reason} = error, _ok), do: error
    defp result(value, ok), do: ok.(value)
  end

  setup %{tmp_dir: tmp} do
    start_supervised!(FakeProbe)
    File.chmod!(tmp, 0o700)

    # After the fixtures: a missing module fails as an assertion.
    assert Code.ensure_loaded?(LaunchRecord),
           "SdrAgent.CalibrationConsole.LaunchRecord is not defined"

    %{root: tmp, opts: [probe: FakeProbe]}
  end

  describe "claim and advance" do
    test "claim creates the 0700 lock and a 0600 claimed record of this owner", ctx do
      assert {:ok, record} = LaunchRecord.claim(ctx.root, ctx.opts)
      lock = Path.join(ctx.root, "run.lock")

      assert mode(lock) == 0o700
      assert mode(Path.join(lock, "record.json")) == 0o600

      assert %{state: "claimed", generation: 1, owner_pid: 4242} = record
      assert record.owner_identity == "Mon 10:00 owner"
      assert is_binary(record.instance_id)
      assert {:ok, ^record} = LaunchRecord.read(ctx.root)
    end

    test "a second claim is refused while the lock exists", ctx do
      {:ok, _} = LaunchRecord.claim(ctx.root, ctx.opts)
      assert {:error, :calibration_in_progress} = LaunchRecord.claim(ctx.root, ctx.opts)
    end

    test "the states advance in order only, by atomic replace", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      invocation_id = Ash.UUIDv7.generate()

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, claimed, :launched, launched_attrs())

      assert {:ok, pending} =
               LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
                 invocation_id: invocation_id
               })

      assert {pending.state, pending.invocation_id} == {"launch_pending", invocation_id}

      assert {:ok, launched} =
               LaunchRecord.advance(ctx.root, pending, :launched, launched_attrs())

      assert {launched.root_pid, launched.process_group_id} == {9001, 9001}
      assert finished = finished!(ctx.root, launched)
      assert finished.state == "finished"

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, finished, :launch_pending, %{
                 invocation_id: invocation_id
               })

      assert Path.wildcard(Path.join([ctx.root, "run.lock", ".*"])) |> Enum.reject(&dot?/1) ==
               []
    end

    test "a stale record copy cannot advance", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      {:ok, _pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
                 invocation_id: Ash.UUIDv7.generate()
               })
    end

    test "the record holds metadata only", ctx do
      {:ok, _} = LaunchRecord.claim(ctx.root, ctx.opts)
      decoded = ctx.root |> Path.join("run.lock/record.json") |> File.read!() |> Jason.decode!()

      assert Enum.sort(Map.keys(decoded)) ==
               Enum.sort(~w(schema instance_id owner_pid owner_identity generation state
                            invocation_id root_pid root_identity process_group_id owner_attested_at
                            attestation_id))
    end

    test "release after finished removes the lock; before finished it is refused", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      assert {:error, :not_finished} = LaunchRecord.release(ctx.root, claimed, ctx.opts)

      {:ok, pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      launched = launched!(ctx.root, pending)
      finished = finished!(ctx.root, launched)
      assert :ok = LaunchRecord.release(ctx.root, finished, ctx.opts)
      refute File.exists?(Path.join(ctx.root, "run.lock"))
      assert {:ok, :none} = LaunchRecord.read(ctx.root)
    end
  end

  describe "an unreadable record is launch_pending" do
    test "a lock with no record (crash before the record)", ctx do
      File.mkdir!(Path.join(ctx.root, "run.lock"))
      File.chmod!(Path.join(ctx.root, "run.lock"), 0o700)
      assert {:ok, %{state: "launch_pending", unreadable: true}} = LaunchRecord.read(ctx.root)
    end

    test "a schema-1 record (session_id) is never reinterpreted", ctx do
      lock = Path.join(ctx.root, "run.lock")
      File.mkdir!(lock)
      File.chmod!(lock, 0o700)

      v1 = %{
        "schema" => "r0-calibration-launch-record/1",
        "instance_id" => Ash.UUIDv7.generate(),
        "owner_pid" => 4242,
        "owner_identity" => "Mon 10:00 owner",
        "generation" => 1,
        "state" => "launched",
        "invocation_id" => Ash.UUIDv7.generate(),
        "root_pid" => 9001,
        "root_identity" => "Mon 10:01 cli",
        "session_id" => 9001,
        "owner_attested_at" => nil
      }

      write_private!(Path.join(lock, "record.json"), Jason.encode!(v1))

      assert {:ok, %{state: "launch_pending", unreadable: true} = read} =
               LaunchRecord.read(ctx.root)

      assert :owner_verification_required = LaunchRecord.quiescence(read, ctx.opts)
    end

    test "a partial, malformed or wrongly shaped record", ctx do
      lock = Path.join(ctx.root, "run.lock")
      File.mkdir!(lock)
      File.chmod!(lock, 0o700)

      shaped = fn change ->
        %{
          "schema" => "r0-calibration-launch-record/3",
          "instance_id" => Ash.UUIDv7.generate(),
          "owner_pid" => 4242,
          "owner_identity" => "Mon 10:00 owner",
          "generation" => 1,
          "state" => "claimed",
          "invocation_id" => nil,
          "root_pid" => nil,
          "root_identity" => nil,
          "process_group_id" => nil,
          "owner_attested_at" => nil,
          "attestation_id" => nil
        }
        |> Map.merge(change)
        |> Jason.encode!()
      end

      # Positive control: the well-formed schema-3 base reads as a record,
      # so every case below fails for its own change.
      write_private!(Path.join(lock, "record.json"), shaped.(%{}))
      assert {:ok, %{state: "claimed"} = base} = LaunchRecord.read(ctx.root)
      refute Map.has_key?(base, :unreadable)

      for bytes <- [
            ~s({"state":"cla),
            ~s({"state":"claimed"}),
            "null",
            "not json",
            shaped.(%{"schema" => "r0-calibration-launch-record/2"}),
            shaped.(%{"schema" => "r0-calibration-launch-record/4"}),
            # Schema-3 nullable fields, pinned per state (E4c bound 3).
            shaped.(%{"attestation_id" => Ash.UUIDv7.generate()}),
            shaped.(%{"state" => "aborted", "root_pid" => 9001}),
            shaped.(%{
              "state" => "aborted",
              "invocation_id" => Ash.UUIDv7.generate(),
              "attestation_id" => Ash.UUIDv7.generate()
            }),
            shaped.(%{"state" => "recovered", "invocation_id" => Ash.UUIDv7.generate()}),
            shaped.(%{"state" => "recovered", "attestation_id" => Ash.UUIDv7.generate()}),
            shaped.(%{
              "state" => "launched",
              "invocation_id" => Ash.UUIDv7.generate(),
              "root_pid" => 9001,
              "root_identity" => "Mon 10:01 cli",
              "process_group_id" => 9001,
              "attestation_id" => Ash.UUIDv7.generate()
            }),
            shaped.(%{"state" => "released"}),
            shaped.(%{"owner_pid" => "4242"}),
            shaped.(%{"owner_identity" => 7}),
            shaped.(%{"generation" => 2}),
            shaped.(%{"instance_id" => "not-a-uuid"}),
            shaped.(%{"state" => "finished", "invocation_id" => nil}),
            shaped.(%{"extra" => "field"})
          ] do
        write_private!(Path.join(lock, "record.json"), bytes)

        assert {:ok, %{state: "launch_pending", unreadable: true} = read} =
                 LaunchRecord.read(ctx.root),
               bytes

        assert :owner_verification_required = LaunchRecord.quiescence(read, ctx.opts)
      end
    end
  end

  describe "recovery" do
    setup ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      {:ok, pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      %{pending: pending}
    end

    test "a live owner is never taken over", ctx do
      assert {:error, :owner_alive} = LaunchRecord.recover(ctx.root, ctx.opts)
      refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
    end

    test "an absent owner, or a reused pid, may be recovered", ctx do
      FakeProbe.put(&put_in(&1.identities[4242], "Tue 11:00 someone else"))
      assert {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert recovery.record.instance_id == ctx.pending.instance_id
      assert :ok = LaunchRecord.end_recovery(ctx.root, recovery)

      FakeProbe.put(&%{&1 | identities: %{}})
      assert {:ok, _recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
    end

    test "two simultaneous recoverers: exactly one wins", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> LaunchRecord.recover(ctx.root, ctx.opts) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      # Exactly one claim; every contender is refused. One that meets the
      # winner's directory before it is made 0700 sees it unsafe (the
      # reviewed fail-closed visibility qualification, Codex 9badd2cf).
      assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))

      refusals = Enum.reject(results, &match?({:ok, _}, &1))
      assert length(refusals) == 3

      assert Enum.all?(
               refusals,
               &(&1 in [{:error, :recovery_in_progress}, {:error, :launch_record_unsafe}])
             ),
             inspect(refusals)
    end

    test "a record replaced on disk under the recoverer is refused and kept", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert :ok = LaunchRecord.verify_recovery(ctx.root, recovery)

      record_path = Path.join(ctx.root, "run.lock/record.json")

      for change <- [
            %{"instance_id" => Ash.UUIDv7.generate()},
            %{"owner_identity" => "another start"},
            %{"owner_pid" => 4343},
            %{"generation" => 2}
          ] do
        replacement = record_path |> File.read!() |> Jason.decode!() |> Map.merge(change)
        write_private!(record_path, Jason.encode!(replacement))

        assert {:error, :record_changed} = LaunchRecord.verify_recovery(ctx.root, recovery),
               inspect(change)

        assert Jason.decode!(File.read!(record_path)) == replacement
        assert File.dir?(Path.join(ctx.root, "run.lock/recover"))
        write_private!(record_path, Jason.encode!(snapshot(ctx.pending)))
      end
    end

    test "a stale end_recovery never removes a successor's ticket", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, first} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert :ok = LaunchRecord.end_recovery(ctx.root, first)
      {:ok, second} = LaunchRecord.recover(ctx.root, ctx.opts)

      assert {:error, :recovery_changed} = LaunchRecord.end_recovery(ctx.root, first)
      assert File.dir?(Path.join(ctx.root, "run.lock/recover"))
      assert :ok = LaunchRecord.end_recovery(ctx.root, second)
    end

    test "a crashed recoverer's ticket is not silently taken over", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, _abandoned} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert {:error, :recovery_in_progress} = LaunchRecord.recover(ctx.root, ctx.opts)
    end
  end

  describe "recovery of an unreadable record" do
    test "is refused: the owner cannot be known", ctx do
      File.mkdir!(Path.join(ctx.root, "run.lock"))
      File.chmod!(Path.join(ctx.root, "run.lock"), 0o700)
      FakeProbe.put(&%{&1 | identities: %{}})

      assert {:error, :owner_unknown} = LaunchRecord.recover(ctx.root, ctx.opts)
      refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
    end

    # Superseded by E4c round 4 (Codex 01a13526): an unreadable record is a
    # hard owner conflict; no typed attestation unlocks its recovery.
    test "is refused even with a typed attestation", ctx do
      File.mkdir!(Path.join(ctx.root, "run.lock"))
      File.chmod!(Path.join(ctx.root, "run.lock"), 0o700)

      for typed <- ["yes", "STOPPED"] do
        assert {:error, :owner_unknown} =
                 LaunchRecord.recover(ctx.root, ctx.opts ++ [owner_verified_stopped: typed])
      end

      refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
    end
  end

  describe "an observation failure is never absence" do
    test "claim without a reliable own pid or start identity creates nothing", ctx do
      for self <- [{:error, :unavailable}, :raise] do
        FakeProbe.put(&%{&1 | self: self})
        assert {:error, :probe_unavailable} = LaunchRecord.claim(ctx.root, ctx.opts)
        refute File.exists?(Path.join(ctx.root, "run.lock"))
      end

      FakeProbe.put(&%{&1 | self: 4242, identities: %{4242 => {:error, :unavailable}}})
      assert {:error, :probe_unavailable} = LaunchRecord.claim(ctx.root, ctx.opts)
      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end

    test "an unreadable owner identity cannot authorize recovery", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      {:ok, _pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      for failure <- [{:error, :unavailable}, :raise] do
        FakeProbe.put(&put_in(&1.identities[4242], failure))
        assert {:error, :probe_unavailable} = LaunchRecord.recover(ctx.root, ctx.opts)
        refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
      end
    end

    test "a failed root or session lookup never establishes quiescence", ctx do
      for {key, failure} <- [
            {:identities, {:error, :unavailable}},
            {:identities, :raise},
            {:groups, {:error, :unavailable}},
            {:groups, :raise}
          ] do
        FakeProbe.put(&put_in(&1, [key, 9001], failure))

        assert {:error, :probe_unavailable} =
                 LaunchRecord.quiescence(launched_record(), ctx.opts),
               inspect({key, failure})

        FakeProbe.put(&%{&1 | identities: %{4242 => "Mon 10:00 owner"}, groups: %{}})
      end
    end
  end

  describe "private paths" do
    test "a symlinked root or ancestor is unsafe", ctx do
      alias_root = ctx.root <> "-alias"
      File.rm(alias_root)
      on_exit(fn -> File.rm(alias_root) end)
      File.ln_s!(ctx.root, alias_root)

      assert {:error, :launch_record_unsafe} = LaunchRecord.claim(alias_root, ctx.opts)
      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end

    test "a symlinked lock, record or recovery ticket is unsafe", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      lock = Path.join(ctx.root, "run.lock")
      record = Path.join(lock, "record.json")

      # record.json as a symlink to a valid copy
      copy = Path.join(ctx.root, "copy.json")
      File.cp!(record, copy)
      File.rm!(record)
      File.ln_s!(copy, record)
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root)
      assert {:error, :launch_record_unsafe} = LaunchRecord.release(ctx.root, claimed, ctx.opts)
      assert File.exists?(copy)

      # run.lock as a symlink to a private directory
      File.rm!(record)
      File.cp!(copy, record)
      moved = Path.join(ctx.root, "moved.lock")
      File.rename!(lock, moved)
      File.ln_s!(moved, lock)
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root)
      assert {:error, :launch_record_unsafe} = LaunchRecord.claim(ctx.root, ctx.opts)
      File.rm!(lock)
      File.rename!(moved, lock)

      # the recovery ticket as a symlink
      FakeProbe.put(&%{&1 | identities: %{}})
      target = Path.join(ctx.root, "elsewhere")
      File.mkdir!(target)
      File.ln_s!(target, Path.join(lock, "recover"))
      assert {:error, :launch_record_unsafe} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert File.dir?(target)
    end

    test "wrong modes are unsafe", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      lock = Path.join(ctx.root, "run.lock")
      record = Path.join(lock, "record.json")

      File.chmod!(record, 0o644)
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root)
      File.chmod!(record, 0o600)

      File.chmod!(lock, 0o755)

      assert {:error, :launch_record_unsafe} =
               LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
                 invocation_id: Ash.UUIDv7.generate()
               })

      File.chmod!(lock, 0o700)

      File.chmod!(ctx.root, 0o755)
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root)
      File.chmod!(ctx.root, 0o700)
    end

    test "a non-0700 lock is unsafe before any write", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      lock = Path.join(ctx.root, "run.lock")
      before = File.read!(Path.join(lock, "record.json"))
      File.chmod!(lock, 0o500)

      try do
        assert {:error, :launch_record_unsafe} =
                 LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
                   invocation_id: Ash.UUIDv7.generate()
                 })
      after
        File.chmod!(lock, 0o700)
      end

      assert File.read!(Path.join(lock, "record.json")) == before
    end

    # The test-only `:replace` seam fails the atomic replace itself, after
    # every private-path check has passed.
    test "a record replace failure is typed and leaves the lock and record", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      lock = Path.join(ctx.root, "run.lock")
      before = File.read!(Path.join(lock, "record.json"))
      failing = ctx.opts ++ [replace: fn _temp, _final -> {:error, :eio} end]

      assert {:error, :launch_record_write_failed} =
               LaunchRecord.advance(
                 ctx.root,
                 claimed,
                 :launch_pending,
                 %{invocation_id: Ash.UUIDv7.generate()},
                 failing
               )

      assert File.read!(Path.join(lock, "record.json")) == before
      assert Path.wildcard(Path.join(lock, ".*")) |> Enum.reject(&dot?/1) == []
      assert {:ok, %{state: "claimed"}} = LaunchRecord.read(ctx.root)
    end

    test "a stale finished record never releases a successor's lock", ctx do
      finished = finished_record!(ctx)
      assert :ok = LaunchRecord.release(ctx.root, finished, ctx.opts)
      {:ok, _successor} = LaunchRecord.claim(ctx.root, ctx.opts)

      assert {:error, :record_changed} = LaunchRecord.release(ctx.root, finished, ctx.opts)
      assert File.exists?(Path.join(ctx.root, "run.lock/record.json"))
    end
  end

  describe "quiescence" do
    test "a launch_pending (or unreadable) record needs the owner's attestation", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      {:ok, pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      assert :owner_verification_required = LaunchRecord.quiescence(pending, ctx.opts)

      assert :owner_verification_required =
               LaunchRecord.quiescence(%{state: "launch_pending", unreadable: true}, ctx.opts)

      # The record-level attestation is superseded by the ticket's
      # attestation artifact (E4c-4, launch_record_v3_test.exs).
    end

    test "launched: a dead root with a live process in its session is not quiescent", ctx do
      record = %{launched_record() | state: "launched"}
      FakeProbe.put(&put_in(&1.groups[9001], [9002]))
      assert :not_quiescent = LaunchRecord.quiescence(record, ctx.opts)
    end

    test "launched: an empty session and an absent or reused root is quiescent", ctx do
      record = launched_record()
      assert :quiescent = LaunchRecord.quiescence(record, ctx.opts)

      FakeProbe.put(&put_in(&1.identities[9001], "a later process"))
      assert :quiescent = LaunchRecord.quiescence(record, ctx.opts)
    end

    test "launched: the same root still alive is not quiescent", ctx do
      FakeProbe.put(&put_in(&1.identities[9001], "Mon 10:01 cli"))
      assert :not_quiescent = LaunchRecord.quiescence(launched_record(), ctx.opts)
    end

    test "claimed and finished records have nothing outstanding", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      assert :quiescent = LaunchRecord.quiescence(claimed, ctx.opts)
      assert {:ok, ^claimed} = LaunchRecord.read(ctx.root)

      {:ok, pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      launched = launched!(ctx.root, pending)
      finished = finished!(ctx.root, launched)
      assert :quiescent = LaunchRecord.quiescence(finished, ctx.opts)
    end
  end

  describe "code review (Codex, 42c6ebc)" do
    setup ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      {:ok, pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      %{pending: pending}
    end

    test "an empty partial ticket is never replaced", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      partial = Path.join(ctx.root, "run.lock/recover")
      parent = self()

      # Codex's interleaving (9badd2cf): an empty private partial ticket is
      # already at `recover` when the claim is made. The claim is the
      # exclusive mkdir itself, so no precheck can be raced, and no file
      # write of this recoverer may run (the callback reports one).
      replace = fn temp, final ->
        send(parent, {:partial_inode, :file_write_ran})
        File.rename(temp, final)
      end

      File.mkdir!(partial)
      File.chmod!(partial, 0o700)
      inode = File.stat!(partial).inode

      assert {:error, :recovery_in_progress} =
               LaunchRecord.recover(ctx.root, ctx.opts ++ [replace: replace])

      refute_received {:partial_inode, _}
      assert File.stat!(partial).inode == inode
      refute File.exists?(Path.join(partial, "ticket"))
      assert {:error, :recovery_in_progress} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert File.dir?(partial)
    end

    test "a raising write is a typed failure, never a crash", ctx do
      raising = ctx.opts ++ [replace: fn _temp, _final -> raise "synthetic" end]
      before = File.read!(Path.join(ctx.root, "run.lock/record.json"))

      assert {:error, :launch_record_write_failed} =
               LaunchRecord.advance(ctx.root, ctx.pending, :launched, launched_attrs(), raising)

      assert File.read!(Path.join(ctx.root, "run.lock/record.json")) == before
      assert Path.wildcard(Path.join(ctx.root, "run.lock/.*")) |> Enum.reject(&dot?/1) == []
    end

    test "a malformed root or session answer never establishes quiescence", ctx do
      launched = launched!(ctx.root, ctx.pending)

      for {key, reply} <- [
            identities: {:raw, nil},
            identities: {:raw, {:ok, ""}},
            identities: {:raw, {:ok, 7}},
            identities: {:raw, :reused},
            identities: {:raw, {:absent}},
            groups: {:raw, nil},
            groups: {:raw, {:ok, nil}},
            groups: {:raw, {:ok, [9002, "x"]}},
            groups: {:raw, {:ok, [0]}},
            groups: {:raw, []}
          ] do
        FakeProbe.put(&put_in(&1, [key, 9001], reply))

        assert {:error, :probe_unavailable} = LaunchRecord.quiescence(launched, ctx.opts),
               inspect({key, reply})

        FakeProbe.put(&%{&1 | identities: %{4242 => "Mon 10:00 owner"}, groups: %{}})
      end
    end

    test "a malformed owner answer never authorizes recovery", ctx do
      for reply <- [nil, {:ok, ""}, {:ok, 7}, :gone, {:ok, "x", "y"}] do
        FakeProbe.put(&put_in(&1.identities[4242], {:raw, reply}))

        assert {:error, :probe_unavailable} = LaunchRecord.recover(ctx.root, ctx.opts),
               inspect(reply)

        refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
      end
    end

    test "a malformed own pid never claims", ctx do
      other = Path.join(ctx.root, "other")
      File.mkdir!(other)
      File.chmod!(other, 0o700)

      for reply <- [nil, {:ok, 0}, {:ok, "4242"}, 4242] do
        FakeProbe.put(&%{&1 | self: {:raw, reply}})
        assert {:error, :probe_unavailable} = LaunchRecord.claim(other, ctx.opts), inspect(reply)
        refute File.exists?(Path.join(other, "run.lock"))
      end
    end

    test "a stale recovery handle cannot verify after its ticket was replaced", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, first} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert :ok = LaunchRecord.end_recovery(ctx.root, first)
      {:ok, second} = LaunchRecord.recover(ctx.root, ctx.opts)

      assert first.ticket != second.ticket
      assert {:error, :recovery_changed} = LaunchRecord.verify_recovery(ctx.root, first)
      assert :ok = LaunchRecord.verify_recovery(ctx.root, second)
    end

    test "a release refused by an active recovery or a stray entry keeps the record", ctx do
      launched = launched!(ctx.root, ctx.pending)
      finished = finished!(ctx.root, launched)
      path = Path.join(ctx.root, "run.lock/record.json")
      bytes = File.read!(path)

      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert {:error, :recovery_in_progress} = LaunchRecord.release(ctx.root, finished, ctx.opts)
      assert File.read(path) == {:ok, bytes}
      :ok = LaunchRecord.end_recovery(ctx.root, recovery)
      # The owner's own release (schema 3: without a handle, owner only).
      FakeProbe.put(&put_in(&1.identities[4242], "Mon 10:00 owner"))

      stray = Path.join(ctx.root, "run.lock/stray")
      write_private!(stray, "x")
      assert {:error, :launch_record_unsafe} = LaunchRecord.release(ctx.root, finished, ctx.opts)
      assert File.read(path) == {:ok, bytes}
      File.rm!(stray)

      assert :ok = LaunchRecord.release(ctx.root, finished, ctx.opts)
    end

    test "a failed ticket removal is a typed failure and the ticket stays", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      dir = Path.join(ctx.root, "run.lock/recover")
      write_private!(Path.join(dir, "obstruction"), "x")

      assert {:error, :launch_record_write_failed} = LaunchRecord.end_recovery(ctx.root, recovery)
      assert File.dir?(dir)
    end

    test "recovery artifacts are private on every operation", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, _recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      dir = Path.join(ctx.root, "run.lock/recover")
      ticket = Path.join(dir, "ticket")

      File.chmod!(ticket, 0o644)
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root)
      assert {:error, :launch_record_unsafe} = LaunchRecord.recover(ctx.root, ctx.opts)
      File.chmod!(ticket, 0o600)

      File.chmod!(dir, 0o755)
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root)
      assert {:error, :launch_record_unsafe} = LaunchRecord.recover(ctx.root, ctx.opts)
      File.chmod!(dir, 0o700)

      # A partial ticket (directory without its id) stays blocked.
      File.rm!(ticket)
      assert {:ok, %{state: "launch_pending"}} = LaunchRecord.read(ctx.root)
      assert {:error, :recovery_in_progress} = LaunchRecord.recover(ctx.root, ctx.opts)
    end

    test "artifacts owned by another user are unsafe", ctx do
      foreign = ctx.opts ++ [owner_uid: 999_999]
      assert {:error, :launch_record_unsafe} = LaunchRecord.read(ctx.root, foreign)

      assert {:error, :launch_record_unsafe} =
               LaunchRecord.advance(
                 ctx.root,
                 ctx.pending,
                 :launched,
                 launched_attrs(),
                 foreign
               )

      assert {:error, :launch_record_unsafe} = LaunchRecord.recover(ctx.root, foreign)
      other = Path.join(ctx.root, "other")
      File.mkdir!(other)
      File.chmod!(other, 0o700)
      assert {:error, :launch_record_unsafe} = LaunchRecord.claim(other, foreign)
      refute File.exists?(Path.join(other, "run.lock"))
    end

    test "an attestation that is not a canonical timestamp is unreadable", ctx do
      path = Path.join(ctx.root, "run.lock/record.json")

      for bad <- ["raw-text", "2026-10-13T06:00:00Z", "2026-10-13"] do
        tampered = path |> File.read!() |> Jason.decode!() |> Map.put("owner_attested_at", bad)
        write_private!(path, Jason.encode!(tampered))
        assert {:ok, %{unreadable: true}} = LaunchRecord.read(ctx.root), bad
      end
    end

    # Superseded by E4c round 4: an unreadable record, whatever its bytes,
    # is never recovered, so it cannot change under a recoverer.
    test "an unreadable record is never recovered, whatever its bytes", ctx do
      path = Path.join(ctx.root, "run.lock/record.json")

      for bytes <- ["corrupt one", "corrupt two"] do
        write_private!(path, bytes)

        assert {:error, :owner_unknown} =
                 LaunchRecord.recover(ctx.root, ctx.opts ++ [owner_verified_stopped: "STOPPED"])
      end

      File.rm!(path)
      assert {:error, :owner_unknown} = LaunchRecord.recover(ctx.root, ctx.opts)
      refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
    end
  end

  # Fixture steps that need the schema-2 transitions, checked by assertion
  # so a missing implementation never crashes a test.
  defp launched!(root, pending) do
    result = LaunchRecord.advance(root, pending, :launched, launched_attrs())

    assert match?({:ok, _}, result),
           "advancing to launched with process_group_id (schema 2) is not implemented: " <>
             inspect(result)

    {:ok, launched} = result
    launched
  end

  defp finished!(root, launched) do
    result = LaunchRecord.advance(root, launched, :finished, %{})

    assert match?({:ok, _}, result),
           "advancing a schema-2 launched record to finished is not implemented: " <>
             inspect(result)

    {:ok, finished} = result
    finished
  end

  defp write_private!(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
  end

  defp snapshot(record) do
    record
    |> Map.take(
      ~w(schema instance_id owner_pid owner_identity generation state invocation_id root_pid
         root_identity process_group_id owner_attested_at attestation_id)a
    )
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp finished_record!(ctx) do
    {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

    {:ok, pending} =
      LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
        invocation_id: Ash.UUIDv7.generate()
      })

    launched = launched!(ctx.root, pending)
    finished = finished!(ctx.root, launched)
    finished
  end

  defp launched_attrs,
    do: %{root_pid: 9001, root_identity: "Mon 10:01 cli", process_group_id: 9001}

  defp launched_record do
    %{
      state: "launched",
      root_pid: 9001,
      root_identity: "Mon 10:01 cli",
      process_group_id: 9001,
      owner_attested_at: nil
    }
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    Bitwise.band(mode, 0o777)
  end

  defp dot?(path), do: Path.basename(path) in [".", ".."]
end
