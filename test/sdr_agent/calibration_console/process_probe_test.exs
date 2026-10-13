defmodule SdrAgent.CalibrationConsole.ProcessProbeTest do
  @moduledoc """
  R0-07 slice E4b (row R11-1; staged process-group delta, Codex 6052424a):
  the macOS OS process probe of `SdrAgent.CalibrationConsole.LaunchRecord`.

    * `self_pid/0` — `{:ok, pid}` of this VM.
    * `start_identity/1` and `group_members/1` read one successful,
      well-formed snapshot of `/bin/ps -A -o pid=,pgid=,stat=,lstart=` run
      with `LC_ALL=C` and `TZ=UTC` through `SdrAgent.ChildEnv` (the
      inherited TZ changes `lstart`).
    * A pid is `:absent` only when that snapshot has no row for it; a
      failed, empty, diagnostic-bearing or malformed snapshot is an error —
      including exit 1 with empty output — never absence or an empty group.
    * `group_members/1` lists a process group's runnable members (zombies
      excluded). macOS `ps` reports no session id, so the observable is the
      CLI's own process group; group emptiness is not a whole-descendant
      proof (a descendant can change its group).

  The `ps:` override is honoured only in test-seam builds. Fixtures are
  harmless `sleep` processes led by `perl setpgrp`, launched and signalled
  only through `SdrAgent.ChildEnv`, cleaned up before any readiness
  assertion, and signalled only as positively identified groups. No CLI or
  model is launched.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.CalibrationConsole.LaunchRecord
  alias SdrAgent.CalibrationConsole.ProcessProbe
  alias SdrAgent.ChildEnv

  @identity ~r/\A\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4}\z/

  setup do
    previous = Application.get_env(:sdr_agent, ProcessProbe)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, ProcessProbe, previous),
        else: Application.delete_env(:sdr_agent, ProcessProbe)
    end)

    # A missing module fails as an assertion.
    assert Code.ensure_loaded?(ProcessProbe),
           "SdrAgent.CalibrationConsole.ProcessProbe is not defined"

    :ok
  end

  test "self_pid is this VM's OS pid" do
    assert ProcessProbe.self_pid() == {:ok, String.to_integer(System.pid())}
  end

  test "a live start identity is the fixed C/UTC form and stable" do
    {:ok, self} = ProcessProbe.self_pid()
    assert {:ok, identity} = ProcessProbe.start_identity(self)
    assert identity =~ @identity
    assert ProcessProbe.start_identity(self) == {:ok, identity}
  end

  test "the parent's locale and TZ never change an identity" do
    {:ok, self} = ProcessProbe.self_pid()
    {:ok, identity} = ProcessProbe.start_identity(self)
    previous = Map.new(~w(TZ LC_ALL LANG), &{&1, System.get_env(&1)})

    try do
      System.put_env("TZ", "America/Denver")
      System.put_env("LC_ALL", "fr_FR.UTF-8")
      System.put_env("LANG", "fr_FR.UTF-8")
      assert ProcessProbe.start_identity(self) == {:ok, identity}
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "a stopped process is absent from a successful snapshot" do
    {leader, _port} = group!(1)
    assert {:ok, _} = ProcessProbe.start_identity(leader)
    kill_group!(leader)
    assert eventually(fn -> ProcessProbe.start_identity(leader) == :absent end)
  end

  test "a group's runnable members, and none once it is stopped" do
    {leader, _port} = group!(2)
    assert {:ok, members} = ProcessProbe.group_members(leader)
    assert leader in members
    assert length(members) == 2

    kill_group!(leader)
    assert eventually(fn -> ProcessProbe.group_members(leader) == {:ok, []} end)
  end

  test "a dead root with a surviving member of its group" do
    {leader, _port} = group!(2)
    {:ok, [_, _] = members} = ProcessProbe.group_members(leader)
    [child] = members -- [leader]

    System.cmd("kill", ["-KILL", Integer.to_string(leader)], env: ChildEnv.cmd([]))
    assert eventually(fn -> ProcessProbe.group_members(leader) == {:ok, [child]} end)
    {:ok, identity} = ProcessProbe.start_identity(child)

    record = launched(leader, "a previous root identity")
    assert :not_quiescent = LaunchRecord.quiescence(record, probe: ProcessProbe)
    assert identity =~ @identity
  end

  test "invalid pids are errors, never absence" do
    for pid <- [0, -1, "1", nil, 1.5] do
      assert {:error, :invalid_pid} = ProcessProbe.start_identity(pid), inspect(pid)
      assert {:error, :invalid_pid} = ProcessProbe.group_members(pid), inspect(pid)
    end
  end

  describe "a failed or malformed snapshot is an error" do
    test "exit 1 with empty output (false) is not absence", %{tmp_dir: tmp} do
      ps!(tmp, "", 1)
      {:ok, self} = ProcessProbe.self_pid()
      assert {:error, _} = ProcessProbe.start_identity(self)
      assert {:error, _} = ProcessProbe.group_members(self)
    end

    test "a nonzero exit, a diagnostic or an empty table", %{tmp_dir: tmp} do
      {:ok, self} = ProcessProbe.self_pid()

      for {output, status} <- [
            {"ps: unsupported field", 2},
            {"#{self} #{self} Ss Tue Oct 13 03:49:40 2026\nps: warning", 0},
            {"", 0}
          ] do
        ps!(tmp, output, status)
        assert {:error, _} = ProcessProbe.start_identity(self), inspect(output)
        assert {:error, _} = ProcessProbe.group_members(self), inspect(output)
      end
    end

    test "malformed rows, numbers, states or times", %{tmp_dir: tmp} do
      {:ok, self} = ProcessProbe.self_pid()
      good = "#{self} #{self} Ss Tue Oct 13 03:49:40 2026"

      for bad <- [
            "garbage line",
            "x #{self} Ss Tue Oct 13 03:49:40 2026",
            "#{self} 0x1 Ss Tue Oct 13 03:49:40 2026",
            "#{self} #{self} Tue Oct 13 03:49:40 2026",
            "#{self} #{self} Ss 2026-10-13T03:49:40Z",
            "#{self} #{self}"
          ] do
        ps!(tmp, good <> "\n" <> bad, 0)
        assert {:error, _} = ProcessProbe.start_identity(self), bad
        assert {:error, _} = ProcessProbe.group_members(self), bad
      end
    end

    test "zombies are not runnable members", %{tmp_dir: tmp} do
      ps!(
        tmp,
        "100 100 Ss Tue Oct 13 03:49:40 2026\n101 100 Z Tue Oct 13 03:49:41 2026\n" <>
          "102 7 S Tue Oct 13 03:49:42 2026",
        0
      )

      assert ProcessProbe.group_members(100) == {:ok, [100]}
      assert ProcessProbe.start_identity(101) == {:ok, "Tue Oct 13 03:49:41 2026"}
      assert ProcessProbe.start_identity(103) == :absent
    end
  end

  test "the launch record's quiescence through the real probe" do
    {leader, _port} = group!(2)
    {:ok, identity} = ProcessProbe.start_identity(leader)
    record = launched(leader, identity)

    assert :not_quiescent = LaunchRecord.quiescence(record, probe: ProcessProbe)
    kill_group!(leader)

    assert eventually(fn ->
             LaunchRecord.quiescence(record, probe: ProcessProbe) == :quiescent
           end)
  end

  defp launched(leader, identity) do
    %{
      state: "launched",
      root_pid: leader,
      root_identity: identity,
      process_group_id: leader,
      owner_attested_at: nil
    }
  end

  # A process group of `count` sleeping processes led by the first (perl
  # setpgrp, checked). Its cleanup is registered before any readiness
  # assertion and signals only that identified group.
  defp group!(count) do
    script =
      "use POSIX; setpgid(0, 0) == 0 or die; " <>
        "for (2..#{count}) { if (fork() == 0) { exec 'sleep', '30' } } exec 'sleep', '30'"

    port =
      Port.open({:spawn_executable, "/usr/bin/perl"}, [
        :binary,
        {:env, ChildEnv.port([])},
        args: ["-e", script]
      ])

    {:os_pid, leader} = Port.info(port, :os_pid)
    on_exit(fn -> kill_group!(leader) end)
    assert eventually(fn -> group_size(leader) == count end)
    {leader, port}
  end

  defp group_size(leader) do
    {out, 0} = System.cmd("/bin/ps", ["-A", "-o", "pid=,pgid=,stat="], env: ChildEnv.cmd([]))

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split/1)
    |> Enum.count(fn [_pid, pgid, stat] ->
      pgid == Integer.to_string(leader) and not String.starts_with?(stat, "Z")
    end)
  end

  # Signals the group only while its leader still leads it.
  defp kill_group!(leader) do
    {out, _} =
      System.cmd("/bin/ps", ["-o", "pgid=", "-p", Integer.to_string(leader)],
        env: ChildEnv.cmd([]),
        stderr_to_stdout: true
      )

    if String.trim(out) == Integer.to_string(leader),
      do:
        System.cmd("kill", ["-KILL", "-#{leader}"], env: ChildEnv.cmd([]), stderr_to_stdout: true)

    :ok
  end

  # A test-seam ps that prints `output` and exits with `status`.
  defp ps!(tmp, output, status) do
    path = Path.join(tmp, "ps-#{System.unique_integer([:positive])}")
    data = Path.join(tmp, "ps-data-#{System.unique_integer([:positive])}")
    File.write!(data, output)
    File.write!(path, "#!/bin/sh\ncat '#{data}'\nexit #{status}\n")
    File.chmod!(path, 0o700)
    Application.put_env(:sdr_agent, ProcessProbe, ps: path)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
