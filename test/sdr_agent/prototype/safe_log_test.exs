defmodule SdrAgent.Prototype.SafeLogTest do
  @moduledoc """
  IF-8 content-free logging (interfaces r6; F6, R2), with synthetic canary
  markers only: once attached, formatted strings, reports, crash and
  supervisor reports and forged tags yield zero marker hits; a valid event
  is rebuilt from its code and refs; `say/2` prints counts and ids only;
  prototype code has no other output path.

  The filter is a VM-wide primary filter, so this module is `async: false`
  and detaches after every test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

  alias SdrAgent.Prototype.SafeLog

  @marker "CANARY-d237-safelog-7f3a"
  @withheld "prototype: log content withheld"

  setup do
    on_exit(fn -> SafeLog.detach() end)
    :ok
  end

  defp attach! do
    assert SafeLog.attach(file: nil) == :ok
    filters = :logger.get_primary_config().filters
    assert List.keymember?(filters, :sdr_prototype_content_free, 0)
  end

  defp refute_marker(output, what) do
    refute String.contains?(output, @marker), "#{what}: the marker reached the log output"
  end

  test "attach/1 installs the content-free primary filter" do
    attach!()
  end

  test "a formatted string, a lazy message and a report are withheld" do
    attach!()

    output =
      capture_log(fn ->
        Logger.error("formatted #{@marker}")
        Logger.error(fn -> "lazy #{@marker}" end)
        Logger.error(%{report: @marker})
        :logger.error(~c"erlang format ~s", [@marker])
      end)

    refute_marker(output, "formatted/lazy/report")
    assert String.contains?(output, @withheld)
  end

  test "crash and supervisor reports are withheld" do
    attach!()
    Process.flag(:trap_exit, true)

    output =
      capture_log(fn ->
        {:ok, pid} = Task.start(fn -> raise "crash #{@marker}" end)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

        child = %{id: :canary, start: {:erlang, :apply, [fn -> {:error, @marker} end, []]}}
        {:error, _} = Supervisor.start_link([child], strategy: :one_for_one)
        Process.sleep(50)
      end)

    refute_marker(output, "crash/supervisor report")
  end

  test "a valid event is rebuilt from its code and refs" do
    attach!()

    output =
      capture_log(fn ->
        assert SafeLog.event(:boot, result: :refused, reason: :binding_absent) == :ok
      end)

    assert String.contains?(output, "prototype: boot")
  end

  test "a forged valid-shape tag on a content message yields no content" do
    attach!()

    output =
      capture_log(fn ->
        :logger.error("forged #{@marker}", %{
          sdr_prototype_code: :boot,
          sdr_prototype_refs: [result: :ok, reason: :none]
        })
      end)

    refute_marker(output, "forged valid-shape tag")
  end

  test "an unknown code, an extra key or a wrong type is withheld" do
    attach!()

    output =
      capture_log(fn ->
        SafeLog.event(:no_such_code, note: @marker)
        SafeLog.event(:boot, result: :ok, reason: :none, extra: @marker)
        SafeLog.event(:provisioned, grant_id: @marker, result: :created, reason: :none)
        SafeLog.event(:import_row, row_index: 15, result: :imported, reason: :none)
      end)

    refute_marker(output, "malformed events")
    refute String.contains?(output, "prototype: provisioned")
    refute String.contains?(output, "prototype: import_row")
  end

  test "say/2 prints one line of codes, counts and ids, never content" do
    id = Ecto.UUID.generate()

    out =
      capture_io(fn ->
        assert SafeLog.say(:op_result, command: :assign, id: id, result: :ok, reason: :none) ==
                 :ok
      end)

    assert out == "prototype: op_result command=assign id=#{id} result=ok reason=none\n"

    bad =
      capture_io(fn ->
        SafeLog.say(:op_result, command: :assign, id: @marker, result: :ok, reason: :none)
        SafeLog.say(:bundle_written, bundle_id: id, items: @marker)
      end)

    refute String.contains?(bad, @marker), "say/2 printed a malformed ref"
  end

  test "prototype code has no output path outside SafeLog and the bundle writer" do
    files =
      Path.wildcard("lib/sdr_agent/prototype/**/*.ex") ++
        Path.wildcard("lib/mix/tasks/sdr.prototype.*.ex")

    allowed = ["lib/sdr_agent/prototype/safe_log.ex", "lib/sdr_agent/prototype/output.ex"]
    pattern = ~r/\b(IO\.|Logger\.|:io\.|:logger\.|Mix\.shell\(\))/

    offenders =
      for file <- files, file not in allowed, Regex.match?(pattern, File.read!(file)), do: file

    assert offenders == []
  end
end
