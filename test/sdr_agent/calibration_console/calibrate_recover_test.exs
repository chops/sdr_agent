defmodule SdrAgent.CalibrationConsole.CalibrateRecoverTest do
  @moduledoc """
  R0-07 slice E, sub-slice d3d: `calibrate-recover` (packet 8.14.5, 8.14.7
  and 8.14.11; contract/entity PASS at 5153ad3, pinned at 052ff49).

  Every record state is real: either left by `Calibrate.run/2` under a
  stale-owner probe (a fake owner pid that is alive while the command runs
  and gone afterwards), or built through `LaunchRecord`'s own transitions
  with a real calibration reservation. Recovery itself runs as another
  process would: the recorded owner reads as absent.

  Not hermetically testable, and covered by review of the code only: a
  failed bare-ticket end (`end_recovery/3` removes with `File.rm`, not the
  `remove:` seam), and the task's start order.
  """
  use SdrAgent.AuditCase, async: false

  defmodule RecoverProbe do
    @moduledoc """
    The real ProcessProbe for every process but the fake owner 4242, whose
    start identity reads as alive or gone; and a group answer set per test
    (`:real`, `{:plus, pid}` a phantom member, `:error` a failed read).
    Each group read is reported to `watch`, when set, for ordering tests.
    """
    use Agent

    alias SdrAgent.CalibrationConsole.ProcessProbe

    @owner 4242
    @identity "Mon 10:00 owner"

    def start_link(_),
      do: Agent.start_link(fn -> %{owner: :alive, group: :real, watch: nil} end, name: __MODULE__)

    def owner_gone, do: Agent.update(__MODULE__, &%{&1 | owner: :gone})
    def group(mode), do: Agent.update(__MODULE__, &%{&1 | group: mode})
    def watch(pid), do: Agent.update(__MODULE__, &%{&1 | watch: pid})

    def self_pid, do: {:ok, @owner}

    def start_identity(@owner) do
      case Agent.get(__MODULE__, & &1.owner) do
        :alive -> {:ok, @identity}
        :gone -> :absent
      end
    end

    def start_identity(pid), do: ProcessProbe.start_identity(pid)

    def group_members(pgid) do
      %{group: mode, watch: watch} = Agent.get(__MODULE__, & &1)
      if watch, do: send(watch, {:probe_group, pgid})

      case mode do
        :real ->
          ProcessProbe.group_members(pgid)

        :error ->
          {:error, :ps_failed}

        {:plus, extra} ->
          with {:ok, members} <- ProcessProbe.group_members(pgid), do: {:ok, members ++ [extra]}
      end
    end
  end

  defmodule LaunchProbe do
    @moduledoc "The d3a receipt probe: real, unverified, or real then a phantom group."
    use Agent

    alias SdrAgent.CalibrationConsole.ProcessProbe

    def start_link(_), do: Agent.start_link(fn -> :real end, name: __MODULE__)
    def put(mode), do: Agent.update(__MODULE__, fn _ -> mode end)

    def start_identity(pid) do
      case Agent.get(__MODULE__, & &1) do
        :identity_absent ->
          :absent

        :then_phantom ->
          RecoverProbe.group({:plus, 999_999})
          ProcessProbe.start_identity(pid)

        :real ->
          ProcessProbe.start_identity(pid)
      end
    end

    def group_members(pgid), do: ProcessProbe.group_members(pgid)
  end

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.CalibrationConsole.Authority
  alias SdrAgent.CalibrationConsole.Calibrate
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.LaunchRecord
  alias SdrAgent.CalibrationConsole.ProcessProbe
  alias SdrAgent.CalibrationConsole.Prompt
  alias SdrAgent.Clock
  alias SdrAgent.Test.PinnedCLI

  @moduletag :tmp_dir
  @profile :claude_cli_opus
  @v3 "claude-message-json/3+prompt-builder/1"
  @now ~U[2026-10-15 12:00:00.000000Z]

  setup %{tmp_dir: tmp} do
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    start_supervised!(RecoverProbe)
    start_supervised!(LaunchProbe)
    start_supervised!(Authority)
    %{root: store} = AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    grant = g_r0!(tenant)

    previous = Application.get_env(:sdr_agent, :calibration_launch_probe)
    Application.put_env(:sdr_agent, :calibration_launch_probe, LaunchProbe)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, :calibration_launch_probe, previous),
        else: Application.delete_env(:sdr_agent, :calibration_launch_probe)
    end)

    pins = Path.join(tmp, "pins")
    bin = Path.join([pins, String.duplicate("a", 32) <> "-app-claude-cli-2.1.294", "bin"])
    File.mkdir_p!(bin)
    executable = Path.join(bin, "claude-code")
    File.write!(executable, "#!/bin/sh\nexit 1\n")
    File.chmod!(executable, 0o555)
    PinnedCLI.inject_identity!(executable, store: pins)

    ctx = %{
      tenant: tenant,
      grant: grant,
      store: store,
      executable: executable,
      ran: Path.join(tmp, "ran"),
      root: private_dir!(tmp, "calibration"),
      tmp: tmp
    }

    ctx
    |> Map.put(:evidence, private_dir!(ctx.root, "evidence"))
    |> then(&Map.put(&1, :cli, shell_cli!(&1)))
  end

  ## Wiring and inputs

  describe "wiring and inputs" do
    test "recover_command/1 and recover_opts/1 are exact" do
      recover_defined!()
      id = Ash.UUIDv7.generate()

      assert Calibrate.recover_command([id]) == {:recover, id, Calibrate.recover_opts(false)}

      assert Calibrate.recover_command([id, "--owner-verified-stopped"]) ==
               {:recover, id, Calibrate.recover_opts(true)}

      assert Calibrate.recover_command(["--release-aborted"]) ==
               {:recover, nil, Calibrate.recover_opts(false)}

      for argv <- [
            [],
            ["not-a-uuid"],
            [id, "--yes"],
            [id, "--owner-verified-stopped", "x"],
            ["--release-aborted", id]
          ],
          do: assert(Calibrate.recover_command(argv) == {:error, :usage}, inspect(argv))

      opts = Calibrate.recover_opts(true)
      calibration = Path.join(System.user_home!(), ".local/state/sdr-agent/calibration")

      assert Keyword.keys(opts) |> Enum.sort() ==
               Enum.sort([:tenant, :root, :evidence_dir, :confirm, :probe, :record, :stopped])

      assert {opts[:tenant], opts[:root], opts[:evidence_dir], opts[:probe], opts[:record],
              opts[:stopped]} ==
               {:console, calibration, Path.join(calibration, "evidence"), ProcessProbe, [], true}

      assert is_function(opts[:confirm], 1)
      assert Calibrate.recover_opts(false)[:stopped] == false
    end

    test "a malformed id or option is refused before any read; no ticket", ctx do
      product!(ctx, :pending_sent)
      recover_defined!()

      for {id, change} <- [
            {"not-a-uuid", []},
            {42, []},
            {Ash.UUIDv7.generate(), [stopped: "yes"]},
            {Ash.UUIDv7.generate(), [extra: 1]},
            {Ash.UUIDv7.generate(), [hook: :x]},
            {Ash.UUIDv7.generate(), [root: Path.join([ctx.root, "..", "calibration"])]}
          ] do
        assert {:stop, :calibration_options_invalid, summary} = recover(ctx, id, change)
        assert {summary.record, summary.ticket} == {:none, :none}, inspect({id, change})
        refute ticket?(ctx)
      end

      assert {:stop, :calibration_options_invalid, _} =
               Calibrate.recover(Ash.UUIDv7.generate(), Keyword.delete(base_opts(ctx), :stopped))
    end
  end

  ## The lock

  describe "the lock" do
    test "a live owner is never taken over", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent, owner: :alive)
      recover_defined!()

      assert {:stop, :owner_alive, summary} = recover(ctx, id)
      assert summary.ticket == :none
      refute ticket?(ctx)
    end

    test "an existing (abandoned) ticket is never adopted: recovery in progress", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)
      {:ok, _abandoned} = LaunchRecord.recover(ctx.root, probe: RecoverProbe)
      before = tree(ctx)
      recover_defined!()

      assert {:stop, :recovery_in_progress, %{ticket: :none}} = recover(ctx, id)
      assert tree(ctx) == before
    end

    test "an unreadable record is an owner conflict", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)
      File.write!(record_path(ctx), "not json")
      recover_defined!()

      assert {:stop, :owner_unknown, %{ticket: :none}} = recover(ctx, id)
      assert File.read!(record_path(ctx)) == "not json"
    end
  end

  ## The target

  describe "the target" do
    test "a zero-target claimed record is a hard owner conflict: kept, never released", ctx do
      product!(ctx, :claimed_zero)
      recover_defined!()

      assert {:stop, :calibration_owner_conflict, summary} = recover(ctx, Ash.UUIDv7.generate())
      assert {summary.record, summary.ticket} == {{:kept, "claimed"}, :ended}
      assert record_state(ctx) == "claimed"
      refute ticket?(ctx)
    end

    test "an id other than the claim's one target is ambiguous; the ticket is ended", ctx do
      product!(ctx, :pending_sent)
      recover_defined!()

      assert {:stop, :calibration_target_ambiguous, summary} =
               recover(ctx, Ash.UUIDv7.generate(), stopped: true)

      assert {summary.record, summary.ticket} == {{:kept, "launch_pending"}, :ended}
    end

    test "a target that is no longer a proof run's is invalid, before any effect", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)

      tamper!("UPDATE agent_runs SET usage_origin = 'assignment' WHERE id = $1", [
        Ecto.UUID.dump!(invocation!(id).agent_run_id)
      ])

      recover_defined!()

      assert {:stop, :calibration_target_invalid, summary} = recover(ctx, id, stopped: true)
      assert summary.ticket == :ended
      assert attested_events(ctx) == []
    end
  end

  ## The unlaunched path

  describe "the unlaunched path" do
    test "a claimed record with a reserved call: unlaunched, evidence, latch, aborted, released",
         ctx do
      %{invocation_id: id} = product!(ctx, :claimed_reserved)
      recover_defined!()

      assert {:ok, summary} = recover(ctx, id)

      assert {summary.record, summary.ticket, summary.outcome} ==
               {:released, :released, "launch_failed"}

      assert {invocation!(id).status, invocation!(id).sent_at} == {:failed, nil}
      assert_latched(ctx, id, summary)
      refute File.exists?(lock(ctx))
    end

    test "a declined RECOVER is a pre-effect stop: ticket ended, record kept", ctx do
      %{invocation_id: id} = product!(ctx, :claimed_reserved)
      recover_defined!()

      assert {:stop, :calibration_not_confirmed, summary} =
               recover(ctx, id, answers: %{recover: "no"})

      assert {summary.record, summary.ticket} == {{:kept, "claimed"}, :ended}
      assert invocation!(id).status == :reserved
      refute_received {:confirm, :stopped, _prompt}
    end
  end

  ## The attested path

  describe "the attested path" do
    test "sent history without --owner-verified-stopped needs the owner; pre-effect", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)
      recover_defined!()

      assert {:stop, :owner_verification_required, summary} = recover(ctx, id)
      assert {summary.record, summary.ticket} == {{:kept, "launch_pending"}, :ended}
      refute_received {:confirm, :stopped, _prompt}
    end

    test "launch_pending + STOPPED: attested, fresh observation without CLI init, latched, recovered",
         ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)
      recover_defined!()

      assert {:ok, summary} = recover(ctx, id, stopped: true)
      assert {summary.record, summary.ticket} == {:released, :released}
      assert [_attested] = attested_events(ctx)

      document = assert_latched(ctx, id, summary)
      # The owner's STOPPED is not the CLI's init attestation.
      assert {document["attested_cli_version"], document["attested_model_id"]} == {nil, nil}
      assert document["outcome"] == "init_drift"
    end

    test "a mistyped STOPPED is a pre-effect stop: no attestation", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)
      recover_defined!()

      assert {:stop, :calibration_not_confirmed, summary} =
               recover(ctx, id, stopped: true, answers: %{stopped: "STOPPED"})

      assert {summary.record, summary.ticket} == {{:kept, "launch_pending"}, :ended}
      assert attested_events(ctx) == []
    end

    test "live work refuses before any STOPPED prompt, event or write", ctx do
      %{invocation_id: id} = product!(ctx, :launched_live)
      recover_defined!()

      assert {:stop, :calibration_not_quiescent, summary} = recover(ctx, id, stopped: true)
      assert {summary.record, summary.ticket} == {{:kept, "launched"}, :ended}
      assert_received {:confirm, :recover, _prompt}
      refute_received {:confirm, :stopped, _prompt}
      assert attested_events(ctx) == []
      assert releases(id) == []
    end

    test "a probe error is never absence: refused before STOPPED", ctx do
      %{invocation_id: id} = product!(ctx, :launched_live)
      RecoverProbe.group(:error)
      recover_defined!()

      assert {:stop, :probe_unavailable, %{ticket: :ended}} = recover(ctx, id, stopped: true)
      refute_received {:confirm, :stopped, _prompt}
      assert attested_events(ctx) == []
    end

    test "launched and stopped: the group is observed before the STOPPED prompt; recovered",
         ctx do
      %{invocation_id: id} = product!(ctx, :launched_live)
      RecoverProbe.group(:real)
      RecoverProbe.watch(self())
      recover_defined!()

      assert {:ok, %{record: :released}} = recover(ctx, id, stopped: true)
      assert [first_group | _] = ordered(:probe_group)
      assert first_group < position({:confirm, :stopped})
      assert [_attested] = attested_events(ctx)
    end

    test "a launched record whose call was never sent is inconsistent: kept", ctx do
      %{invocation_id: id} = craft!(ctx, :launched_never_sent)
      recover_defined!()

      assert {:stop, :calibration_record_inconsistent, summary} = recover(ctx, id, stopped: true)
      assert summary.record == {:kept, "launched"}
      assert attested_events(ctx) == []
    end

    test "a claimed record with sent history is inconsistent: kept", ctx do
      %{invocation_id: id} = product!(ctx, :claimed_sent)
      recover_defined!()

      assert {:stop, :calibration_record_inconsistent, summary} = recover(ctx, id, stopped: true)
      assert summary.record == {:kept, "claimed"}
    end
  end

  ## Final replay

  describe "final replay" do
    test "finished with a sent, latched target and its file: released", ctx do
      %{invocation_id: id} = product!(ctx, :finished_kept)
      recover_defined!()

      assert {:ok, %{record: :released, ticket: :released}} = recover(ctx, id)
      refute File.exists?(lock(ctx))
    end

    test "finished with a changed or missing latched file is a conflict, kept", ctx do
      %{invocation_id: id} = product!(ctx, :finished_kept)
      [file] = File.ls!(ctx.evidence)
      path = Path.join(ctx.evidence, file)
      File.chmod!(path, 0o600)
      File.write!(path, File.read!(path) <> " ")
      recover_defined!()

      assert {:stop, :calibration_evidence_conflict, %{record: {:kept, "finished"}}} =
               recover(ctx, id)

      File.rm!(path)

      assert {:stop, :calibration_evidence_conflict, %{record: {:kept, "finished"}}} =
               recover(ctx, id)
    end

    test "aborted with a failed, never-sent, latched target: released", ctx do
      %{invocation_id: id} = product!(ctx, :aborted_latched)
      recover_defined!()

      assert {:ok, %{record: :released}} = recover(ctx, id)
    end

    for variant <- [
          :aborted_reserved_unlatched,
          :aborted_failed_unlatched,
          :aborted_sent_latched,
          :finished_never_sent,
          :finished_unlatched
        ] do
      test "#{variant} is inconsistent: kept, ticket ended", ctx do
        %{invocation_id: id, state: state} = craft!(ctx, unquote(variant))
        recover_defined!()

        assert {:stop, :calibration_record_inconsistent, summary} = recover(ctx, id)
        assert {summary.record, summary.ticket} == {{:kept, state}, :ended}
      end
    end

    test "the nil-target exception: an aborted record with no candidate, only via recover(nil)",
         ctx do
      product!(ctx, :aborted_nil)
      recover_defined!()

      assert {:stop, :calibration_target_ambiguous, _} = recover(ctx, Ash.UUIDv7.generate())

      assert {:ok, summary} = recover(ctx, nil, answers: %{recover: "RECOVER ABORTED"})
      assert {summary.record, summary.invocation_id} == {:released, nil}
      refute File.exists?(lock(ctx))
    end

    test "recover(nil) against any other record is ambiguous", ctx do
      product!(ctx, :pending_sent)
      recover_defined!()

      assert {:stop, :calibration_target_ambiguous, %{ticket: :ended}} =
               recover(ctx, nil, answers: %{recover: "RECOVER ABORTED"})
    end
  end

  ## Evidence and the ticket after effects

  describe "evidence and the ticket" do
    test "an unlatched valid file is reused unchanged: its hash is latched", ctx do
      %{invocation_id: id} = product!(ctx, :launched_file_unlatched)
      [file] = File.ls!(ctx.evidence)
      bytes = File.read!(Path.join(ctx.evidence, file))
      recover_defined!()

      assert {:ok, summary} = recover(ctx, id, stopped: true)
      assert File.read!(Path.join(ctx.evidence, file)) == bytes
      assert summary.evidence.sha256 == sha(bytes)
      assert [%ModelResultRelease{evidence_sha256: latched}] = releases(id)
      assert latched == sha(bytes)
    end

    test "an unlatched file that does not validate is a conflict, never replaced", ctx do
      %{invocation_id: id} = product!(ctx, :launched_file_unlatched)
      [file] = File.ls!(ctx.evidence)
      path = Path.join(ctx.evidence, file)
      File.chmod!(path, 0o600)
      File.write!(path, "{}")
      recover_defined!()

      assert {:stop, :calibration_evidence_conflict, _summary} = recover(ctx, id, stopped: true)
      assert File.read!(path) == "{}"
    end

    test "a post-effect stop keeps the ticket and reports the published file", ctx do
      %{invocation_id: id} = product!(ctx, :pending_sent)
      fail_events!(["model.result.calibration"])
      recover_defined!()

      assert {:stop, :calibration_finish_failed, summary} = recover(ctx, id, stopped: true)
      assert {summary.record, summary.ticket} == {{:kept, "launch_pending"}, :kept}
      assert %{path: path, sha256: digest} = summary.evidence
      assert sha(File.read!(path)) == digest
      assert File.exists?(Path.join([lock(ctx), "recover", "attestation.json"]))
      assert [_attested] = attested_events(ctx)
    end
  end

  ## Fixtures

  defp recover_defined! do
    assert Code.ensure_loaded?(Calibrate)
    assert function_exported?(Calibrate, :recover, 2), "Calibrate.recover/2 is not defined"
  end

  defp base_opts(ctx) do
    [
      tenant: ctx.tenant.id,
      root: ctx.root,
      evidence_dir: ctx.evidence,
      confirm: confirm(%{}),
      probe: RecoverProbe,
      record: [],
      stopped: false
    ]
  end

  # `answers` override the typed lines (`recover:`, `stopped:`); `change`
  # merges or replaces options.
  defp recover(ctx, id, change \\ []) do
    {answers, change} = Keyword.pop(change, :answers, %{})
    answers = Map.merge(%{recover: "RECOVER #{id}", stopped: "STOPPED #{id}"}, answers)

    opts =
      ctx
      |> base_opts()
      |> Keyword.put(:confirm, confirm(answers))
      |> Keyword.merge(change)

    Calibrate.recover(id, opts)
  end

  # Reports which prompt it was shown (STOPPED or RECOVER), then answers.
  defp confirm(answers) do
    test = self()

    fn prompt ->
      kind = if prompt =~ "STOPPED", do: :stopped, else: :recover
      send(test, {:confirm, kind, prompt})
      Map.get(answers, kind, "")
    end
  end

  # The positions of each kind of observation in this process's mailbox.
  defp ordered(kind) do
    {:messages, messages} = Process.info(self(), :messages)

    messages
    |> Enum.with_index()
    |> Enum.filter(fn {message, _i} -> elem(message, 0) == kind end)
    |> Enum.map(&elem(&1, 1))
  end

  defp position({:confirm, kind}) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.find_index(messages, &match?({:confirm, ^kind, _}, &1))
  end

  ## Record states left by calibrate under the stale-owner probe

  defp product!(ctx, kind, opts \\ []) do
    result = Calibrate.run(@profile, product_opts(ctx, kind))
    if Keyword.get(opts, :owner, :gone) == :gone, do: RecoverProbe.owner_gone()
    drop_triggers!()
    flush_confirms()

    id =
      case result do
        {_kind, %{invocation_id: id}} -> id
        {_kind, _reason, %{invocation_id: id}} -> id
      end

    if kind == :claimed_sent, do: rewrite_claimed!(ctx)
    expected = expected_state(kind)
    assert record_state(ctx) == expected, "fixture #{kind}: #{inspect(result)}"
    %{invocation_id: id, state: expected}
  end

  defp product_opts(ctx, kind) do
    base = [
      tenant: ctx.tenant.id,
      root: ctx.root,
      evidence_dir: ctx.evidence,
      confirm: fn _prompt -> "CALIBRATE claude_cli_opus" end,
      probe: RecoverProbe,
      server: [command: ctx.cli, executable: ctx.executable, environment: %{}, clock_from: self()],
      isolation: [],
      record: []
    ]

    case kind do
      k when k in [:pending_sent, :claimed_sent] ->
        LaunchProbe.put(:identity_absent)
        base

      :launched_live ->
        LaunchProbe.put(:then_phantom)
        base

      :claimed_reserved ->
        Keyword.put(base, :record, replace: fail_writing("launch_pending"))

      :claimed_zero ->
        RecoverProbe.group({:plus, 999_999})
        base

      :finished_kept ->
        Keyword.put(base, :record, remove: fn _path -> {:error, :eio} end)

      :aborted_latched ->
        base
        |> Keyword.put(:record, remove: fn _path -> {:error, :eio} end)
        |> Keyword.put(:hook, fn
          :before_issue, _context -> :ok = stop_supervised(Authority)
          _phase, _context -> :ok
        end)

      :aborted_nil ->
        base
        |> Keyword.put(:record, remove: fn _path -> {:error, :eio} end)
        |> Keyword.put(:confirm, fn _prompt -> "no" end)

      :launched_file_unlatched ->
        fail_events!(["model.result.calibration"])
        base
    end
  end

  defp expected_state(kind) do
    %{
      pending_sent: "launch_pending",
      claimed_sent: "claimed",
      launched_live: "launched",
      claimed_reserved: "claimed",
      claimed_zero: "claimed",
      finished_kept: "finished",
      aborted_latched: "aborted",
      aborted_nil: "aborted",
      launched_file_unlatched: "launched"
    }
    |> Map.fetch!(kind)
  end

  # A claimed record carrying sent history: the launch_pending record of a
  # sent call, rewritten on disk (it is the authority) to `claimed`.
  defp rewrite_claimed!(ctx) do
    path = record_path(ctx)

    record =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"state" => "claimed", "invocation_id" => nil})

    File.write!(path, Canonical.encode!(record))
  end

  ## Record states built through LaunchRecord's own transitions

  defp craft!(ctx, :aborted_sent_latched) do
    %{invocation_id: id} = product!(ctx, :pending_sent, owner: :alive)
    {:ok, record} = LaunchRecord.read(ctx.root)
    {:ok, _aborted} = LaunchRecord.advance(ctx.root, record, :aborted, %{}, probe: RecoverProbe)
    latch!(ctx, id)
    RecoverProbe.owner_gone()
    %{invocation_id: id, state: "aborted"}
  end

  defp craft!(ctx, :finished_unlatched) do
    %{invocation_id: id} = product!(ctx, :launched_live, owner: :alive)
    RecoverProbe.group(:real)
    {:ok, record} = LaunchRecord.read(ctx.root)
    {:ok, _finished} = LaunchRecord.advance(ctx.root, record, :finished, %{}, probe: RecoverProbe)
    RecoverProbe.owner_gone()
    %{invocation_id: id, state: "finished"}
  end

  defp craft!(ctx, kind) do
    opts = [probe: RecoverProbe]
    {:ok, claimed} = LaunchRecord.claim(ctx.root, opts)
    invocation = reserve_for_claim!(ctx, claimed.instance_id)

    {:ok, pending} =
      LaunchRecord.advance(
        ctx.root,
        claimed,
        :launch_pending,
        %{invocation_id: invocation.id},
        opts
      )

    launched = %{root_pid: 999_998, root_identity: "Mon 10:01 gone", process_group_id: 999_998}

    state =
      case kind do
        :launched_never_sent ->
          {:ok, _} = LaunchRecord.advance(ctx.root, pending, :launched, launched, opts)
          "launched"

        :aborted_reserved_unlatched ->
          {:ok, _} = LaunchRecord.advance(ctx.root, pending, :aborted, %{}, opts)
          "aborted"

        :aborted_failed_unlatched ->
          fail!(ctx, invocation)
          {:ok, _} = LaunchRecord.advance(ctx.root, pending, :aborted, %{}, opts)
          "aborted"

        :finished_never_sent ->
          {:ok, done} = LaunchRecord.advance(ctx.root, pending, :launched, launched, opts)
          {:ok, _} = LaunchRecord.advance(ctx.root, done, :finished, %{}, opts)
          "finished"
      end

    RecoverProbe.owner_gone()
    %{invocation_id: invocation.id, state: state}
  end

  # A real calibration reservation bound to `claim` (its original event
  # records the claim), on its own proof run.
  defp reserve_for_claim!(ctx, claim) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
    {:ok, binding} = Agents.select_calibration_grant(ctx.tenant.id, @profile, actor: agent)

    marker =
      CalibrationAdmission.context(@profile, AdmissionFixtures.entry(@profile, @v3),
        claim: claim,
        binding: binding
      )

    prompt = Prompt.prompt_ref()
    schema = Prompt.schema_ref()

    attrs =
      "recover-#{System.unique_integer([:positive])}"
      |> AgentsFixtures.claude_attrs()
      |> Map.merge(%{
        prompt_template_id: prompt.id,
        prompt_template_version: prompt.version,
        prompt_template_sha256: prompt.sha256,
        output_schema_id: schema.id,
        output_schema_version: schema.version,
        output_schema_sha256: schema.sha256
      })

    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs, actor: agent, calibration: marker)
      end)

    reserved
  end

  defp fail!(ctx, invocation) do
    agent = system_actor(:agent_runtime, ctx.tenant)

    {:ok, _failed} =
      Agents.fail_model_invocation(invocation, %{error: %{"kind" => "provider_error"}},
        actor: agent
      )
  end

  defp latch!(ctx, id) do
    agent = system_actor(:agent_runtime, ctx.tenant)

    {:ok, _latched} =
      Agents.finish_calibration(invocation!(id), %{sha256: String.duplicate("0", 64)},
        actor: agent
      )
  end

  ## Assertions and small helpers

  # The published file validates against the committed rows and is the one
  # the latch names. Returns the decoded document.
  defp assert_latched(ctx, id, summary) do
    agent = system_actor(:agent_runtime, ctx.tenant)
    %{path: path, sha256: digest} = summary.evidence
    invocation = invocation!(id)

    target = %{
      invocation_id: id,
      run_id: invocation.agent_run_id,
      tenant_id: ctx.tenant.id,
      profile_id: @profile
    }

    assert {:ok, _validated} = Evidence.validate(path, target, actor: agent)
    bytes = File.read!(path)
    assert digest == sha(bytes)

    assert [%ModelResultRelease{disposition: :calibration, evidence_sha256: ^digest}] =
             releases(id)

    Jason.decode!(bytes)
  end

  defp attested_events(ctx), do: events_of_type(ctx.tenant, "calibration.owner_attested")

  defp releases(id) do
    ModelResultRelease
    |> Ash.Query.filter(model_invocation_id == ^id)
    |> Ash.read!(authorize?: false)
  end

  defp invocation!(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp lock(ctx), do: Path.join(ctx.root, "run.lock")
  defp record_path(ctx), do: Path.join(lock(ctx), "record.json")
  defp ticket?(ctx), do: File.exists?(Path.join(lock(ctx), "recover"))

  defp record_state(ctx) do
    case LaunchRecord.read(ctx.root) do
      {:ok, %{state: state}} -> state
      {:ok, :none} -> :none
    end
  end

  defp tree(ctx) do
    ctx
    |> lock()
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(&{&1, if(File.regular?(&1), do: File.read!(&1))})
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp flush_confirms do
    receive do
      {:confirm, _kind, _prompt} -> flush_confirms()
    after
      0 -> :ok
    end
  end

  defp fail_writing(state) do
    fn temp, final ->
      if File.read!(temp) =~ ~s("state":"#{state}"),
        do: {:error, :eio},
        else: File.rename(temp, final)
    end
  end

  defp fail_events!(event_types) do
    name = "sdr_test_fail_#{System.unique_integer([:positive])}"
    types = Enum.map_join(event_types, ", ", &"'#{&1}'")
    Process.put(:recover_triggers, [name | Process.get(:recover_triggers, [])])

    Ecto.Adapters.SQL.query!(
      SdrAgent.Repo,
      "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
        "$$ BEGIN RAISE EXCEPTION 'injected event failure'; END $$",
      []
    )

    Ecto.Adapters.SQL.query!(
      SdrAgent.Repo,
      "CREATE TRIGGER #{name} BEFORE INSERT ON audit_events FOR EACH ROW " <>
        "WHEN (NEW.event_type IN (#{types})) EXECUTE FUNCTION #{name}()",
      []
    )
  end

  # A product's own trigger never outlives the product.
  defp drop_triggers! do
    for name <- Process.get(:recover_triggers, []) do
      Ecto.Adapters.SQL.query!(SdrAgent.Repo, "DROP TRIGGER #{name} ON audit_events", [])
    end

    Process.put(:recover_triggers, [])
  end

  defp shell_cli!(ctx) do
    path = Path.join(ctx.tmp, "cli")

    init =
      ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"2.1.294","tools":[],"mcp_servers":[],"slash_commands":[]})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"blue\\",\\"confidence\\":0.9}","usage":{"input_tokens":1,"output_tokens":1}})

    File.write!(path, """
    #!/bin/sh
    echo run >> '#{ctx.ran}'
    cat > /dev/null
    sleep 1
    printf '%s\\n' '#{init}'
    printf '%s\\n' '#{result}'
    """)

    File.chmod!(path, 0o555)
    path
  end

  defp private_dir!(parent, name) do
    path = Path.join(parent, name)
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp g_r0!(tenant) do
    AgentsFixtures.grant!(tenant, %{
      name: "G-R0",
      profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
      total_attempts: 4,
      starts_at: ~U[2026-10-12 00:00:00.000000Z],
      expires_at: ~U[2026-10-19 05:59:00.000000Z],
      allocations: [
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_opus},
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
      ]
    })
  end
end
