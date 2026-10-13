defmodule SdrAgent.CalibrationConsole.ProcessProbeTest do
  @moduledoc """
  R0-07 slice E4b (row R11-1): the OS process probe the launch record uses
  (`SdrAgent.CalibrationConsole.LaunchRecord`'s `probe:`), on macOS.

    * `self_pid/0` — `{:ok, pid}` of this VM.
    * `start_identity/1` — `{:ok, identity}` (the process start time from
      `ps -o lstart=`), `:absent` when no such process exists, or
      `{:error, _}` when `ps` fails or answers malformed text. Never
      `:absent` for a failure.
    * `session_members/1` — the live members of a **process group**
      (macOS `ps` reports no session id: `sess` is 0 for every process),
      zombies excluded: `{:ok, pids}` or `{:error, _}`, never `{:ok, []}`
      for a failure.

  Every `ps` runs through `SdrAgent.ChildEnv`. Failures and malformed
  output use the test-seam `ps:` override. The fixtures are harmless
  `sleep` processes led by `perl setpgrp`; no CLI or model is launched.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.CalibrationConsole.LaunchRecord
  alias SdrAgent.CalibrationConsole.ProcessProbe

  setup do
    previous = Application.get_env(:sdr_agent, ProcessProbe)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, ProcessProbe, previous),
        else: Application.delete_env(:sdr_agent, ProcessProbe)
    end)

    # After the fixtures: a missing module fails as an assertion.
    assert Code.ensure_loaded?(ProcessProbe),
           "SdrAgent.CalibrationConsole.ProcessProbe is not defined"

    :ok
  end

  test "self_pid is this VM's OS pid" do
    assert ProcessProbe.self_pid() == {:ok, String.to_integer(System.pid())}
  end

  test "the start identity of a live process is stable, and absent once it is gone" do
    {:ok, self} = ProcessProbe.self_pid()
    assert {:ok, identity} = ProcessProbe.start_identity(self)
    assert identity =~ ~r/\A\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4}\z/
    assert ProcessProbe.start_identity(self) == {:ok, identity}

    {leader, _port} = group!(1)
    assert {:ok, _} = ProcessProbe.start_identity(leader)
    kill_group!(leader)
    assert eventually(fn -> ProcessProbe.start_identity(leader) == :absent end)
  end

  test "a group's live members, and none once it is stopped" do
    {leader, _port} = group!(2)
    assert {:ok, members} = ProcessProbe.session_members(leader)
    assert leader in members
    assert length(members) == 2

    kill_group!(leader)
    assert eventually(fn -> ProcessProbe.session_members(leader) == {:ok, []} end)
  end

  test "invalid pids are errors, never absence" do
    for pid <- [0, -1, "1", nil, 1.5] do
      assert {:error, :invalid_pid} = ProcessProbe.start_identity(pid), inspect(pid)
      assert {:error, :invalid_pid} = ProcessProbe.session_members(pid), inspect(pid)
    end
  end

  test "a failing ps is an error, never absence or an empty group" do
    Application.put_env(:sdr_agent, ProcessProbe, ps: "/usr/bin/false")
    {:ok, self} = ProcessProbe.self_pid()

    assert {:error, _} = ProcessProbe.start_identity(self)
    assert {:error, _} = ProcessProbe.session_members(self)
  end

  test "malformed ps output is an error", %{tmp_dir: tmp} do
    {:ok, self} = ProcessProbe.self_pid()

    for output <- ["garbage line", "12 x Z\nnot numbers", "  12  34  \n"] do
      Application.put_env(:sdr_agent, ProcessProbe, ps: script!(tmp, output))
      assert {:error, _} = ProcessProbe.start_identity(self), output
      assert {:error, _} = ProcessProbe.session_members(self), output
    end
  end

  test "the launch record's quiescence through the real probe", %{tmp_dir: tmp} do
    {leader, _port} = group!(2)
    {:ok, identity} = ProcessProbe.start_identity(leader)

    record = %{
      state: "launched",
      root_pid: leader,
      root_identity: identity,
      session_id: leader,
      owner_attested_at: nil
    }

    assert :not_quiescent = LaunchRecord.quiescence(record, probe: ProcessProbe)
    kill_group!(leader)

    assert eventually(fn ->
             LaunchRecord.quiescence(record, probe: ProcessProbe) == :quiescent
           end)

    assert File.dir?(tmp)
  end

  # A process group of `count` sleeping processes, led by the first.
  defp group!(count) do
    script =
      "setpgrp(0,0); for (2..#{count}) { if (fork() == 0) { exec 'sleep', '30' } } " <>
        "exec 'sleep', '30'"

    port = Port.open({:spawn_executable, "/usr/bin/perl"}, [:binary, args: ["-e", script]])
    {:os_pid, leader} = Port.info(port, :os_pid)

    assert eventually(fn ->
             {out, _} = System.cmd("ps", ["-A", "-o", "pid=,pgid="])

             out
             |> String.split("\n", trim: true)
             |> Enum.count(&(String.split(&1) |> List.last() == Integer.to_string(leader))) ==
               count
           end)

    on_exit(fn -> kill_group!(leader) end)
    {leader, port}
  end

  defp kill_group!(leader) do
    System.cmd("kill", ["-KILL", "-#{leader}"], stderr_to_stdout: true)
    :ok
  end

  defp script!(tmp, output) do
    path = Path.join(tmp, "ps-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' '#{output}'\n")
    File.chmod!(path, 0o700)
    path
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
