defmodule SdrAgent.CalibrationConsole.LaunchRecordV3Test do
  @moduledoc """
  R0-07 slice E4c, sub-slice a (packet 8.12 E4c-2/E4c-4, entity PASS at
  25c1b18, Codex 01a13526): the launch record's schema 3.

    * Final states `aborted` (from `claimed` or `launch_pending`, launch
      fields null) and `recovered` (only under a verified recovery
      handle), with the nullable fields of every state pinned.
    * `attestation_id`, set only by an owner-attested `recovered`
      finalization bound to the handle's ticket through `attestation.json`
      (0600, in the ticket). Observed-quiescence recovery leaves it null.
    * Release of `aborted`, `finished` or `recovered` only, re-checking the
      evidence bound to the state; by the live owner without a ticket, or by
      the recovery handle that holds the ticket. Live work always wins.
    * Removal order makes every partial release an unreadable remnant: a
      hard owner conflict that never resumes.
    * Unreadable records are a hard owner conflict (no typed bypass);
      `attest_stopped` and `owner_attested_at` are gone.

  OS facts come from `V3Probe`; nothing is launched.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.CalibrationConsole.LaunchRecord

  defmodule V3Probe do
    @moduledoc false
    # Start identities by pid, group members by group id, and this
    # process's own pid. `{:error, _}` values are observation failures.
    use Agent

    def start_link(_),
      do:
        Agent.start_link(
          fn -> %{identities: %{4242 => "Mon 10:00 owner"}, groups: %{}, self: 4242} end,
          name: __MODULE__
        )

    def put(fun), do: Agent.update(__MODULE__, fun)
    def self_pid, do: {:ok, Agent.get(__MODULE__, & &1.self)}

    def start_identity(pid) do
      case Agent.get(__MODULE__, &Map.fetch(&1.identities, pid)) do
        :error -> :absent
        {:ok, {:error, _} = error} -> error
        {:ok, value} -> {:ok, value}
      end
    end

    def group_members(group) do
      case Agent.get(__MODULE__, &Map.get(&1.groups, group, [])) do
        {:error, _} = error -> error
        pids -> {:ok, pids}
      end
    end
  end

  @keys ~w(schema instance_id owner_pid owner_identity generation state invocation_id root_pid
           root_identity process_group_id owner_attested_at attestation_id)

  setup %{tmp_dir: tmp} do
    start_supervised!(V3Probe)
    File.chmod!(tmp, 0o700)

    # After the fixtures: a missing module fails as an assertion.
    assert Code.ensure_loaded?(LaunchRecord),
           "SdrAgent.CalibrationConsole.LaunchRecord is not defined"

    %{root: tmp, opts: [probe: V3Probe]}
  end

  describe "schema 3" do
    test "records are schema 3 with attestation_id, and owner_attested_at stays null", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      decoded = disk(ctx.root)

      assert decoded["schema"] == "r0-calibration-launch-record/3"
      assert Enum.sort(Map.keys(decoded)) == Enum.sort(@keys)
      assert {decoded["owner_attested_at"], decoded["attestation_id"]} == {nil, nil}
      assert Map.get(claimed, :attestation_id, :missing) == nil
    end

    test "a schema-2 record is never reinterpreted", ctx do
      {:ok, _claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      schema2 =
        ctx.root
        |> disk()
        |> Map.delete("attestation_id")
        |> Map.put("schema", "r0-calibration-launch-record/2")

      write_private!(record_path(ctx.root), Jason.encode!(schema2))
      assert {:ok, %{unreadable: true}} = LaunchRecord.read(ctx.root)
    end

    test "a set owner_attested_at is unreadable, even a canonical timestamp", ctx do
      {:ok, _claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      tampered = ctx.root |> disk() |> Map.put("owner_attested_at", now())
      write_private!(record_path(ctx.root), Jason.encode!(tampered))
      assert {:ok, %{unreadable: true}} = LaunchRecord.read(ctx.root)
    end

    test "the record-level attestation is removed" do
      refute function_exported?(LaunchRecord, :attest_stopped, 3)
      refute function_exported?(LaunchRecord, :attest_stopped, 4)
    end

    test "a launch_pending record always needs the owner, never a record field", ctx do
      pending = pending!(ctx)
      assert :owner_verification_required = LaunchRecord.quiescence(pending, ctx.opts)
    end
  end

  describe "abort" do
    test "claimed → aborted by its live owner: launch fields and invocation null", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      result = LaunchRecord.advance(ctx.root, claimed, :aborted, %{}, ctx.opts)
      assert match?({:ok, %{state: "aborted"}}, result), inspect(result)

      assert nulls(disk(ctx.root)) ==
               ~w(attestation_id invocation_id owner_attested_at process_group_id root_identity
                  root_pid)
    end

    test "launch_pending → aborted keeps the invocation id, launch fields null", ctx do
      pending = pending!(ctx)
      result = LaunchRecord.advance(ctx.root, pending, :aborted, %{}, ctx.opts)
      assert match?({:ok, %{state: "aborted"}}, result), inspect(result)
      assert disk(ctx.root)["invocation_id"] == pending.invocation_id

      assert nulls(disk(ctx.root)) ==
               ~w(attestation_id owner_attested_at process_group_id root_identity root_pid)
    end

    test "a launched or finished record never aborts", ctx do
      launched = launched!(ctx, pending!(ctx))

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, launched, :aborted, %{}, ctx.opts)

      finished = finished!(ctx, launched)

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, finished, :aborted, %{}, ctx.opts)
    end

    test "abort by a process that is not the owner needs the recovery handle", ctx do
      pending = pending!(ctx)
      V3Probe.put(&%{&1 | self: 5151, identities: %{5151 => "Tue 09:00 other"}})

      assert {:error, :not_owner} =
               LaunchRecord.advance(ctx.root, pending, :aborted, %{}, ctx.opts)

      assert disk(ctx.root)["state"] == "launch_pending"

      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)

      result =
        LaunchRecord.advance(ctx.root, pending, :aborted, %{}, ctx.opts ++ [recovery: recovery])

      assert match?({:ok, %{state: "aborted"}}, result), inspect(result)
    end

    test "an abort attribute is refused (attestation_id only by attested recovery)", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(
                 ctx.root,
                 claimed,
                 :aborted,
                 %{attestation_id: Ash.UUIDv7.generate()},
                 ctx.opts
               )
    end
  end

  describe "attestation artifact (E4c-4)" do
    setup ctx do
      pending = pending!(ctx)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)

      assert function_exported?(LaunchRecord, :new_attestation, 1),
             "LaunchRecord.new_attestation/1 is not defined"

      assert function_exported?(LaunchRecord, :write_attestation, 4),
             "LaunchRecord.write_attestation/4 is not defined"

      assert function_exported?(LaunchRecord, :read_attestation, 3),
             "LaunchRecord.read_attestation/3 is not defined"

      %{pending: pending, recovery: recovery}
    end

    test "is built from the handle: a fresh id bound to record, ticket and observation", ctx do
      {:ok, attestation} = LaunchRecord.new_attestation(ctx.recovery)

      assert attestation.schema == "r0-calibration-attestation/1"
      assert attestation.attestation_id =~ ~r/\A[0-9a-f-]{36}\z/
      assert attestation.instance_id == ctx.pending.instance_id
      assert attestation.invocation_id == ctx.pending.invocation_id
      assert attestation.ticket_id == ctx.recovery.ticket

      assert attestation.observation == %{
               state: "launch_pending",
               root_pid: nil,
               process_group_id: nil
             }

      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(attestation.confirmed_at)
      {:ok, again} = LaunchRecord.new_attestation(ctx.recovery)
      assert again.attestation_id != attestation.attestation_id
    end

    test "is written 0600 in the ticket, never in the record, and replays idempotently", ctx do
      {:ok, attestation} = LaunchRecord.new_attestation(ctx.recovery)
      before = File.read!(record_path(ctx.root))

      assert {:ok, ^attestation} =
               LaunchRecord.write_attestation(ctx.root, ctx.recovery, attestation, ctx.opts)

      path = Path.join(ctx.root, "run.lock/recover/attestation.json")
      assert mode(path) == 0o600
      assert File.read!(record_path(ctx.root)) == before

      assert {:ok, ^attestation} =
               LaunchRecord.write_attestation(ctx.root, ctx.recovery, attestation, ctx.opts)

      assert {:ok, ^attestation} = LaunchRecord.read_attestation(ctx.root, ctx.recovery, ctx.opts)
    end

    test "a different attestation under the same ticket is a conflict", ctx do
      {:ok, first} = LaunchRecord.new_attestation(ctx.recovery)
      {:ok, _} = LaunchRecord.write_attestation(ctx.root, ctx.recovery, first, ctx.opts)
      {:ok, second} = LaunchRecord.new_attestation(ctx.recovery)

      assert {:error, :attestation_conflict} =
               LaunchRecord.write_attestation(ctx.root, ctx.recovery, second, ctx.opts)

      assert {:ok, ^first} = LaunchRecord.read_attestation(ctx.root, ctx.recovery, ctx.opts)
    end

    test "an attestation that does not bind this handle is refused", ctx do
      {:ok, attestation} = LaunchRecord.new_attestation(ctx.recovery)

      for wrong <- [
            %{attestation | ticket_id: Ash.UUIDv7.generate()},
            %{attestation | instance_id: Ash.UUIDv7.generate()},
            %{attestation | invocation_id: Ash.UUIDv7.generate()},
            %{attestation | observation: %{attestation.observation | state: "launched"}}
          ] do
        assert {:error, :attestation_mismatch} =
                 LaunchRecord.write_attestation(ctx.root, ctx.recovery, wrong, ctx.opts)
      end

      refute File.exists?(Path.join(ctx.root, "run.lock/recover/attestation.json"))
    end

    test "a missing attestation reads as none; a tampered one is unsafe or mismatched", ctx do
      assert {:ok, :none} = LaunchRecord.read_attestation(ctx.root, ctx.recovery, ctx.opts)
      {:ok, attestation} = LaunchRecord.new_attestation(ctx.recovery)
      {:ok, _} = LaunchRecord.write_attestation(ctx.root, ctx.recovery, attestation, ctx.opts)
      path = Path.join(ctx.root, "run.lock/recover/attestation.json")

      File.chmod!(path, 0o644)

      assert {:error, :launch_record_unsafe} =
               LaunchRecord.read_attestation(ctx.root, ctx.recovery, ctx.opts)

      File.chmod!(path, 0o600)

      tampered = path |> File.read!() |> Jason.decode!() |> Map.put("ticket_id", "x")
      write_private!(path, Jason.encode!(tampered))

      assert {:error, :attestation_mismatch} =
               LaunchRecord.read_attestation(ctx.root, ctx.recovery, ctx.opts)
    end

    test "a claimed record (no invocation) has nothing to attest", ctx do
      :ok = LaunchRecord.end_recovery(ctx.root, ctx.recovery)
      File.rm_rf!(Path.join(ctx.root, "run.lock"))
      V3Probe.put(&%{&1 | self: 4242, identities: %{4242 => "Mon 10:00 owner"}})
      {:ok, _claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert {:error, :invalid_transition} = LaunchRecord.new_attestation(recovery)
    end
  end

  describe "recovered" do
    test "needs the recovery handle", ctx do
      pending = pending!(ctx)

      assert {:error, :recovery_required} =
               LaunchRecord.advance(
                 ctx.root,
                 pending,
                 :recovered,
                 %{attestation_id: Ash.UUIDv7.generate()},
                 ctx.opts
               )
    end

    test "launch_pending → recovered only with its written, bound attestation", ctx do
      pending = pending!(ctx)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      handle = ctx.opts ++ [recovery: recovery]

      assert {:error, :owner_verification_required} =
               LaunchRecord.advance(ctx.root, pending, :recovered, %{attestation_id: nil}, handle)

      assert {:error, :attestation_mismatch} =
               LaunchRecord.advance(
                 ctx.root,
                 pending,
                 :recovered,
                 %{attestation_id: Ash.UUIDv7.generate()},
                 handle
               )

      {:ok, attestation} = new_written_attestation!(ctx, recovery)

      result =
        LaunchRecord.advance(
          ctx.root,
          pending,
          :recovered,
          %{attestation_id: attestation.attestation_id},
          handle
        )

      assert match?({:ok, %{state: "recovered"}}, result), inspect(result)
      decoded = disk(ctx.root)
      assert decoded["attestation_id"] == attestation.attestation_id
      assert decoded["invocation_id"] == pending.invocation_id

      assert nulls(decoded) ==
               ~w(owner_attested_at process_group_id root_identity root_pid)
    end

    test "the attestation authorizes exactly its own transition", ctx do
      pending = pending!(ctx)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      handle = ctx.opts ++ [recovery: recovery]
      {:ok, attestation} = new_written_attestation!(ctx, recovery)
      attrs = %{attestation_id: attestation.attestation_id}

      {:ok, recovered} = LaunchRecord.advance(ctx.root, pending, :recovered, attrs, handle)

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, recovered, :recovered, attrs, handle)

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(ctx.root, recovered, :aborted, %{}, handle)
    end

    test "launched → recovered by observed quiescence leaves attestation_id null", ctx do
      launched = launched!(ctx, pending!(ctx))
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      handle = ctx.opts ++ [recovery: recovery]

      V3Probe.put(&put_in(&1.groups[9001], [9002]))

      assert {:error, :not_quiescent} =
               LaunchRecord.advance(
                 ctx.root,
                 launched,
                 :recovered,
                 %{attestation_id: nil},
                 handle
               )

      V3Probe.put(&put_in(&1.groups[9001], {:error, :ps_failed}))

      assert {:error, :probe_unavailable} =
               LaunchRecord.advance(
                 ctx.root,
                 launched,
                 :recovered,
                 %{attestation_id: nil},
                 handle
               )

      V3Probe.put(&put_in(&1.groups[9001], []))

      result =
        LaunchRecord.advance(ctx.root, launched, :recovered, %{attestation_id: nil}, handle)

      assert match?({:ok, %{state: "recovered"}}, result), inspect(result)
      decoded = disk(ctx.root)
      assert {decoded["root_pid"], decoded["process_group_id"]} == {9001, 9001}
      assert nulls(decoded) == ~w(attestation_id owner_attested_at)
    end

    test "launched → recovered by attestation: observed live work still wins", ctx do
      launched = launched!(ctx, pending!(ctx))
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      handle = ctx.opts ++ [recovery: recovery]
      {:ok, attestation} = new_written_attestation!(ctx, recovery)
      attrs = %{attestation_id: attestation.attestation_id}

      assert attestation.observation == %{
               state: "launched",
               root_pid: 9001,
               process_group_id: 9001
             }

      V3Probe.put(&put_in(&1.groups[9001], [9002]))

      assert {:error, :not_quiescent} =
               LaunchRecord.advance(ctx.root, launched, :recovered, attrs, handle)

      # An unavailable probe is what the attestation covers.
      V3Probe.put(&put_in(&1.groups[9001], {:error, :ps_failed}))
      result = LaunchRecord.advance(ctx.root, launched, :recovered, attrs, handle)
      assert match?({:ok, %{state: "recovered"}}, result), inspect(result)
      assert disk(ctx.root)["attestation_id"] == attestation.attestation_id
    end

    test "claimed, finished and aborted records never become recovered", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)

      assert {:error, :invalid_transition} =
               LaunchRecord.advance(
                 ctx.root,
                 claimed,
                 :recovered,
                 %{attestation_id: nil},
                 ctx.opts ++ [recovery: recovery]
               )
    end
  end

  describe "release" do
    test "only aborted, finished and recovered records release", ctx do
      {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)
      assert {:error, :not_finished} = LaunchRecord.release(ctx.root, claimed, ctx.opts)
      {:ok, aborted} = abort!(ctx, claimed)
      assert :ok = LaunchRecord.release(ctx.root, aborted, ctx.opts)
      assert {:ok, :none} = LaunchRecord.read(ctx.root)
    end

    test "a finished release re-checks quiescence: live work refuses", ctx do
      finished = finished!(ctx, launched!(ctx, pending!(ctx)))

      V3Probe.put(&put_in(&1.groups[9001], [9002]))
      assert {:error, :not_quiescent} = LaunchRecord.release(ctx.root, finished, ctx.opts)
      assert disk(ctx.root)["state"] == "finished"

      V3Probe.put(&put_in(&1.groups[9001], {:error, :ps_failed}))
      assert {:error, :probe_unavailable} = LaunchRecord.release(ctx.root, finished, ctx.opts)

      V3Probe.put(&put_in(&1.groups[9001], []))
      assert :ok = LaunchRecord.release(ctx.root, finished, ctx.opts)
    end

    test "release without a handle is the live owner's only", ctx do
      {:ok, aborted} = abort!(ctx, pending!(ctx))
      V3Probe.put(&%{&1 | self: 5151, identities: %{5151 => "Tue 09:00 other"}})
      assert {:error, :not_owner} = LaunchRecord.release(ctx.root, aborted, ctx.opts)
      assert disk(ctx.root)["state"] == "aborted"
    end

    test "a crash after aborted or finished: a later process releases through recovery",
         ctx do
      {:ok, aborted} = abort!(ctx, pending!(ctx))
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)

      assert :ok =
               LaunchRecord.release(ctx.root, aborted, ctx.opts ++ [recovery: recovery])

      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end

    test "an abandoned ticket on an aborted or finished record is a hard conflict", ctx do
      {:ok, aborted} = abort!(ctx, pending!(ctx))
      owner_gone()
      {:ok, _abandoned} = LaunchRecord.recover(ctx.root, ctx.opts)

      # A later process: the ticket is never adopted or erased.
      assert {:error, :recovery_in_progress} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert {:error, :recovery_in_progress} = LaunchRecord.release(ctx.root, aborted, ctx.opts)
      assert File.exists?(Path.join(ctx.root, "run.lock/recover/ticket"))
      assert disk(ctx.root)["state"] == "aborted"
    end

    test "a recovered record releases only by its own live handle, re-checking", ctx do
      pending = pending!(ctx)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      handle = ctx.opts ++ [recovery: recovery]
      {:ok, attestation} = new_written_attestation!(ctx, recovery)

      {:ok, recovered} =
        LaunchRecord.advance(
          ctx.root,
          pending,
          :recovered,
          %{attestation_id: attestation.attestation_id},
          handle
        )

      assert {:error, :recovery_in_progress} =
               LaunchRecord.release(ctx.root, recovered, ctx.opts)

      # The handle's attestation must still be the record's.
      path = Path.join(ctx.root, "run.lock/recover/attestation.json")
      bytes = File.read!(path)
      other = bytes |> Jason.decode!() |> Map.put("attestation_id", Ash.UUIDv7.generate())
      write_private!(path, Jason.encode!(other))
      assert {:error, :attestation_mismatch} = LaunchRecord.release(ctx.root, recovered, handle)
      write_private!(path, bytes)

      assert :ok = LaunchRecord.release(ctx.root, recovered, handle)
      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end

    test "a recovered record whose handle died is a hard conflict", ctx do
      pending = pending!(ctx)
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      {:ok, attestation} = new_written_attestation!(ctx, recovery)

      {:ok, _recovered} =
        LaunchRecord.advance(
          ctx.root,
          pending,
          :recovered,
          %{attestation_id: attestation.attestation_id},
          ctx.opts ++ [recovery: recovery]
        )

      # The recovering process is gone: its handle cannot be rebuilt.
      assert {:error, :recovery_in_progress} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert disk(ctx.root)["state"] == "recovered"
    end

    test "a stale handle (ticket replaced) never releases", ctx do
      {:ok, aborted} = abort!(ctx, pending!(ctx))
      owner_gone()
      {:ok, recovery} = LaunchRecord.recover(ctx.root, ctx.opts)
      write_private!(Path.join(ctx.root, "run.lock/recover/ticket"), Ash.UUIDv7.generate())

      assert {:error, :recovery_changed} =
               LaunchRecord.release(ctx.root, aborted, ctx.opts ++ [recovery: recovery])

      assert disk(ctx.root)["state"] == "aborted"
    end

    test "a partial removal is a hard owner conflict and never resumes", ctx do
      {:ok, aborted} = abort!(ctx, pending!(ctx))
      lock = Path.join(ctx.root, "run.lock")

      # The record goes first; the lock removal then fails.
      remove = fn path ->
        if path == lock, do: {:error, :eacces}, else: remove_path(path)
      end

      assert {:error, :calibration_owner_conflict} =
               LaunchRecord.release(ctx.root, aborted, ctx.opts ++ [remove: remove])

      assert File.dir?(lock)
      assert {:ok, %{unreadable: true}} = LaunchRecord.read(ctx.root)
      owner_gone()
      assert {:error, :owner_unknown} = LaunchRecord.recover(ctx.root, ctx.opts)
      assert {:error, :calibration_in_progress} = LaunchRecord.claim(ctx.root, ctx.opts)
    end

    test "a failed first removal leaves the record whole and replayable", ctx do
      {:ok, aborted} = abort!(ctx, pending!(ctx))
      remove = fn _path -> {:error, :eacces} end

      assert {:error, :launch_record_write_failed} =
               LaunchRecord.release(ctx.root, aborted, ctx.opts ++ [remove: remove])

      assert disk(ctx.root)["state"] == "aborted"
      assert :ok = LaunchRecord.release(ctx.root, aborted, ctx.opts)
    end
  end

  describe "unreadable records are a hard owner conflict (round 4)" do
    test "STOPPED never unlocks the recovery of an unreadable record", ctx do
      File.mkdir!(Path.join(ctx.root, "run.lock"))
      File.chmod!(Path.join(ctx.root, "run.lock"), 0o700)
      owner_gone()

      assert {:error, :owner_unknown} =
               LaunchRecord.recover(ctx.root, ctx.opts ++ [owner_verified_stopped: "STOPPED"])

      refute File.exists?(Path.join(ctx.root, "run.lock/recover"))
      assert {:error, :calibration_in_progress} = LaunchRecord.claim(ctx.root, ctx.opts)
    end
  end

  ## Fixtures

  defp pending!(ctx) do
    {:ok, claimed} = LaunchRecord.claim(ctx.root, ctx.opts)

    {:ok, pending} =
      LaunchRecord.advance(ctx.root, claimed, :launch_pending, %{
        invocation_id: Ash.UUIDv7.generate()
      })

    pending
  end

  defp launched!(ctx, pending) do
    {:ok, launched} =
      LaunchRecord.advance(ctx.root, pending, :launched, %{
        root_pid: 9001,
        root_identity: "Mon 10:01 cli",
        process_group_id: 9001
      })

    launched
  end

  defp finished!(ctx, launched) do
    {:ok, finished} = LaunchRecord.advance(ctx.root, launched, :finished, %{})
    finished
  end

  defp abort!(ctx, record) do
    result = LaunchRecord.advance(ctx.root, record, :aborted, %{}, ctx.opts)
    assert match?({:ok, %{state: "aborted"}}, result), "abort: " <> inspect(result)
    result
  end

  defp new_written_attestation!(ctx, recovery) do
    assert function_exported?(LaunchRecord, :new_attestation, 1),
           "LaunchRecord.new_attestation/1 is not defined"

    assert function_exported?(LaunchRecord, :write_attestation, 4),
           "LaunchRecord.write_attestation/4 is not defined"

    {:ok, attestation} = LaunchRecord.new_attestation(recovery)

    {:ok, ^attestation} =
      LaunchRecord.write_attestation(ctx.root, recovery, attestation, ctx.opts)

    {:ok, attestation}
  end

  # The recorded owner (4242) is gone and this process is a later one.
  defp owner_gone,
    do: V3Probe.put(&%{&1 | self: 5151, identities: %{5151 => "Tue 09:00 recoverer"}})

  defp remove_path(path) do
    if File.dir?(path), do: File.rmdir(path), else: File.rm(path)
  end

  defp disk(root), do: root |> record_path() |> File.read!() |> Jason.decode!()
  defp record_path(root), do: Path.join(root, "run.lock/record.json")

  defp nulls(decoded),
    do:
      decoded |> Enum.filter(fn {_k, v} -> is_nil(v) end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  defp write_private!(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    Bitwise.band(mode, 0o777)
  end
end
