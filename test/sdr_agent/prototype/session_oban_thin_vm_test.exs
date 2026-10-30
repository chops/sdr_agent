defmodule SdrAgent.Prototype.SessionObanThinVMTest do
  @moduledoc """
  D-268 M7 R1: Session's insert-only Oban start in a cold Mix VM (no
  product app, no `:oban` started before), against this run's synthetic test
  database, with no job inserted. Child output stays bounded and is reduced to
  a closed stage/exit summary. It does not prove a prototype session, an
  insert, serve execution or a live LLM.
  """
  use ExUnit.Case, async: false

  @child "test/support/session_oban_thin_child.exs"
  @db ~r/\Asdr_agent_test(?:_c[1-9])?\z/
  @clear ~w(BASH_ENV ENV SDR_PROTOTYPE SDR_PROTOTYPE_INSTANCE SDR_MODEL_PROVIDER SDR_CLAUDE_CLI_BIN SDR_WITNESS_STORE_ROOT PHX_SERVER PORT)
  @stages [:ok, :scope, :precondition, :attach, :oban, :roles, :tree, :failed]
  @cap 16_384
  @deadline 20_000

  @tag timeout: 30_000
  test "a cold VM starts the insert-only Oban with no producer, plugin or stager and no product tree" do
    config = SdrAgent.Repo.config()
    database = Keyword.get(config, :database)
    port = Keyword.get(config, :port)
    executable = System.find_executable("mix")

    scope? =
      is_binary(database) and Regex.match?(@db, database) and is_integer(port) and
        port in 1..65_535 and is_binary(executable) and
        Path.type(executable) == :absolute

    assert scope?, "prerequisite: synthetic database and current Mix executable required"

    actual = child(executable, [database, Integer.to_string(port)])
    assert actual == %{exit_status: 0, stage: :ok, withheld: 0}
  end

  defp child(executable, target) do
    env =
      [{~c"MIX_ENV", ~c"test"}, {~c"ERL_CRASH_DUMP_BYTES", ~c"0"}] ++
        Enum.map(@clear, &{String.to_charlist(&1), false})

    args = ["run", "--no-start", "--no-compile", "--no-deps-check", @child | target]

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: File.cwd!(),
        env: env
      ])

    try do
      collect(port, "", System.monotonic_time(:millisecond) + @deadline)
    after
      close_owned(port)
    end
  end

  defp collect(port, output, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      %{exit_status: :unconfirmed, stage: :timeout, withheld: 0}
    else
      receive do
        {^port, {:data, chunk}} -> append(port, output, chunk, deadline)
        {^port, {:exit_status, status}} -> summary(status, output)
      after
        left -> %{exit_status: :unconfirmed, stage: :timeout, withheld: 0}
      end
    end
  end

  defp append(port, output, chunk, deadline) do
    if byte_size(output) + byte_size(chunk) <= @cap,
      do: collect(port, output <> chunk, deadline),
      else: %{exit_status: :unconfirmed, stage: :output_over_cap, withheld: 0}
  end

  # SafeLog's content-free withheld lines are counted, never read further;
  # the rest must be exactly the one stage line.
  defp summary(status, output) do
    {withheld, rest} =
      output
      |> String.split("\n", trim: true)
      |> Enum.split_with(&(&1 == "prototype: log content withheld"))

    stage = Enum.find(@stages, :unrecognized_output, &(rest == ["SESSION_OBAN:#{&1}"]))
    %{exit_status: status, stage: stage, withheld: length(withheld)}
  end

  # Closing this owned port is not a claim that an unreported OS child
  # exited. An :unconfirmed result is a lifecycle STOP, never retried.
  defp close_owned(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
