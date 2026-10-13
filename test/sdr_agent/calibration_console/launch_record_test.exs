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
    # session id, and this process's own pid and identity.
    use Agent

    def start_link(_),
      do:
        Agent.start_link(
          fn -> %{identities: %{4242 => "Mon 10:00 owner"}, sessions: %{}, self: 4242} end,
          name: __MODULE__
        )

    def put(fun), do: Agent.update(__MODULE__, fun)

    def self_pid, do: Agent.get(__MODULE__, & &1.self)

    def start_identity(pid) do
      case Agent.get(__MODULE__, &Map.get(&1.identities, pid)) do
        nil -> :absent
        identity -> {:ok, identity}
      end
    end

    def session_members(session_id),
      do: Agent.get(__MODULE__, &Map.get(&1.sessions, session_id, []))
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

      assert {launched.root_pid, launched.session_id} == {9001, 9001}
      assert {:ok, finished} = LaunchRecord.advance(ctx.root, launched, :finished, %{})
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
                            invocation_id root_pid root_identity session_id owner_attested_at))
    end

    test "release after finished removes the lock; before finished it is refused", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      assert {:error, :not_finished} = LaunchRecord.release(ctx.root, claimed)

      {:ok, pending} =
        LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
          invocation_id: Ash.UUIDv7.generate()
        })

      {:ok, launched} = LaunchRecord.advance(ctx.root, pending, :launched, launched_attrs())
      {:ok, finished} = LaunchRecord.advance(ctx.root, launched, :finished, %{})
      assert :ok = LaunchRecord.release(ctx.root, finished)
      refute File.exists?(Path.join(ctx.root, "run.lock"))
      assert {:ok, :none} = LaunchRecord.read(ctx.root)
    end
  end

  describe "an unreadable record is launch_pending" do
    test "a lock with no record (crash before the record)", ctx do
      File.mkdir!(Path.join(ctx.root, "run.lock"))
      assert {:ok, %{state: "launch_pending", unreadable: true}} = LaunchRecord.read(ctx.root)
    end

    test "a partial or malformed record", ctx do
      lock = Path.join(ctx.root, "run.lock")
      File.mkdir!(lock)

      for bytes <- [~s({"state":"cla), ~s({"state":"claimed"}), "null", "not json"] do
        File.write!(Path.join(lock, "record.json"), bytes)
        assert {:ok, %{state: "launch_pending", unreadable: true}} = LaunchRecord.read(ctx.root)
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

      assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :recovery_in_progress})) == 3
    end

    test "a record that changed under the recoverer is refused", ctx do
      FakeProbe.put(&%{&1 | identities: %{}})
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)

      replaced = %{ctx.pending | instance_id: Ash.UUIDv7.generate()}

      assert {:error, :record_changed} =
               LaunchRecord.verify_recovery(ctx.root, recovery, replaced)
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

      assert {:error, :confirmation_mismatch} =
               LaunchRecord.attest_stopped(ctx.root, pending, "yes")

      assert {:ok, attested} = LaunchRecord.attest_stopped(ctx.root, pending, "STOPPED")
      assert is_binary(attested.owner_attested_at)
      assert :quiescent = LaunchRecord.quiescence(attested, ctx.opts)
    end

    test "launched: a dead root with a live process in its session is not quiescent", ctx do
      record = %{launched_record() | state: "launched"}
      FakeProbe.put(&put_in(&1.sessions[9001], [9002]))
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
      assert :quiescent =
               LaunchRecord.quiescence(%{launched_record() | state: "claimed"}, ctx.opts)

      assert :quiescent =
               LaunchRecord.quiescence(%{launched_record() | state: "finished"}, ctx.opts)
    end
  end

  defp launched_attrs, do: %{root_pid: 9001, root_identity: "Mon 10:01 cli", session_id: 9001}

  defp launched_record do
    %{
      state: "launched",
      root_pid: 9001,
      root_identity: "Mon 10:01 cli",
      session_id: 9001,
      owner_attested_at: nil
    }
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    Bitwise.band(mode, 0o777)
  end

  defp dot?(path), do: Path.basename(path) in [".", ".."]
end
