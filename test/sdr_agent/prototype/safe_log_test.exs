defmodule SdrAgent.Prototype.SafeLogTest do
  @moduledoc """
  IF-8 content-free logging (interfaces r6; F6, R2), with synthetic canary
  markers only, in three separately reachable groups:

  - the pure filter contract: `SafeLog.filter/2` on constructed `:logger`
    events (formatted strings, format/args, reports, crash and supervisor
    reports, forged tags), needing no attachment;
  - `event/2` and `say/2`: what they emit or print, needing no attachment;
  - attachment: `attach/1` installs the primary filter, after which a real
    log call is withheld, and `detach/0` removes it.

  The attached filter is VM-wide, so this module is `async: false` and
  detaches after every test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

  alias SdrAgent.Prototype.SafeLog

  @marker "CANARY-d237-safelog-7f3a"
  @withheld "prototype: log content withheld"
  # An output call: IO., Logger.<function>, :io., :logger. or Mix.shell().
  # A module path (Logger.Formatter, SdrAgent.Logger.ExceptionFilter) is not
  # one; an explicit Elixir. prefix at a module boundary still is. Unlike a
  # leading \b, the lookbehinds also match :io. and :logger. after a space
  # or a parenthesis. Only two exact passive reads are not output calls:
  # :logger.get_primary_config() and :logger.get_handler_ids() (Codex
  # 872f565d V-1); every other :logger. call, get_handler_config included,
  # still is. ADR-0022 adds exactly two more for LaunchPrelude (Codex
  # 19a0b70e): the argument-free getter Logger.default_formatter() and the
  # fixed formatter-only setter :logger.update_handler_config(:ssl_handler,
  # :formatter, replacement); any other arguments still match.
  @output_call ~r/(?<![\w.])(?:Elixir\.)?(IO\.|Logger\.(?!default_formatter\(\))[a-z_])|(?<![\w.]):(?:io\.|logger\.(?!get_primary_config\(\)|get_handler_ids\(\)|update_handler_config\(:ssl_handler, :formatter, replacement\)))|\bMix\.shell\(\)/

  setup do
    on_exit(fn -> SafeLog.detach() end)
    :ok
  end

  defp log_event(msg, meta \\ %{}) do
    %{
      level: :error,
      msg: msg,
      meta: Map.merge(%{pid: self(), time: :logger.timestamp(), gl: Process.group_leader()}, meta)
    }
  end

  defp filtered(event), do: SafeLog.filter(event, :sdr_prototype_content_free)

  defp assert_withheld(result, what) do
    assert match?(%{msg: {:string, @withheld}, meta: %{sdr_prototype_code: :withheld}}, result),
           "#{what}: not withheld: #{inspect(result)}"

    refute inspect(result) =~ @marker, "#{what}: the marker survived the filter"
    assert result.level == :error
  end

  describe "the filter contract (pure)" do
    test "a formatted string, a format with args and a report are withheld" do
      assert_withheld(filtered(log_event({:string, "formatted #{@marker}"})), "string")
      assert_withheld(filtered(log_event({~c"erlang format ~s", [@marker]})), "format/args")
      assert_withheld(filtered(log_event({:report, %{secret: @marker}})), "report")
    end

    test "crash and supervisor reports are withheld" do
      crash =
        {:report,
         %{
           label: {:proc_lib, :crash},
           report: [[error_info: {:error, %RuntimeError{message: @marker}, []}]]
         }}

      supervisor =
        {:report,
         %{
           label: {:supervisor, :start_error},
           report: [errorContext: :start_error, reason: @marker, offender: [id: :canary]]
         }}

      assert_withheld(filtered(log_event(crash, %{domain: [:otp, :sasl]})), "crash report")

      assert_withheld(
        filtered(log_event(supervisor, %{domain: [:otp, :sasl]})),
        "supervisor report"
      )
    end

    test "a valid tagged event is rebuilt from its code and refs" do
      refs = [result: :refused, reason: :binding_absent]

      result =
        filtered(
          log_event({:string, "prototype: boot"}, %{
            sdr_prototype_code: :boot,
            sdr_prototype_refs: refs
          })
        )

      assert match?(
               %{msg: {:string, "prototype: boot"}, meta: %{sdr_prototype_code: :boot}},
               result
             ),
             "a valid event was not kept: #{inspect(result)}"

      assert result.meta.sdr_prototype_refs == refs
    end

    test "a forged valid-shape tag on a content message is rebuilt, discarding the content" do
      meta = %{
        sdr_prototype_code: :boot,
        sdr_prototype_refs: [result: :ok, reason: :none],
        note: @marker
      }

      result = filtered(log_event({:string, "forged #{@marker}"}, meta))

      assert match?(%{msg: {:string, "prototype: boot"}}, result),
             "a forged valid-shape tag was not rebuilt: #{inspect(result)}"

      refute inspect(result) =~ @marker
    end

    test "an unknown code, an extra key or a wrong value type is withheld" do
      cases = [
        unknown: %{sdr_prototype_code: :no_such_code, sdr_prototype_refs: []},
        extra: %{
          sdr_prototype_code: :boot,
          sdr_prototype_refs: [result: :ok, reason: :none, x: 1]
        },
        wrong_type: %{
          sdr_prototype_code: :provisioned,
          sdr_prototype_refs: [grant_id: @marker, result: :created, reason: :none]
        },
        out_of_range: %{
          sdr_prototype_code: :import_row,
          sdr_prototype_refs: [row_index: 15, result: :imported, reason: :none]
        },
        forged_withheld: %{sdr_prototype_code: :withheld, sdr_prototype_refs: [note: @marker]}
      ]

      for {name, meta} <- cases do
        assert_withheld(filtered(log_event({:string, "prototype: #{name}"}, meta)), "#{name}")
      end
    end
  end

  describe "event/2 and say/2" do
    test "a valid event emits only the fixed line" do
      output =
        capture_log(fn ->
          assert SafeLog.event(:boot, result: :refused, reason: :binding_absent) == :ok
        end)

      assert output =~ "prototype: boot"
    end

    test "a malformed event emits no ref value and no code line" do
      output =
        capture_log(fn ->
          SafeLog.event(:no_such_code, note: @marker)
          SafeLog.event(:boot, result: :ok, reason: :none, extra: @marker)
          SafeLog.event(:provisioned, grant_id: @marker, result: :created, reason: :none)
        end)

      refute output =~ @marker
      refute output =~ "prototype: provisioned"
      assert output =~ @withheld
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

      refute bad =~ @marker, "say/2 printed a malformed ref"
    end
  end

  describe "attachment" do
    test "attach/1 installs the primary filter and detach/0 removes it" do
      assert SafeLog.attach(file: nil) == :ok
      assert List.keymember?(:logger.get_primary_config().filters, :sdr_prototype_content_free, 0)
      assert SafeLog.detach() == :ok
      refute List.keymember?(:logger.get_primary_config().filters, :sdr_prototype_content_free, 0)
    end

    test "once attached, a real log call is withheld" do
      assert SafeLog.attach(file: nil) == :ok
      output = capture_log(fn -> Logger.error("attached #{@marker}") end)
      refute output =~ @marker
      assert output =~ @withheld
    end
  end

  test "prototype code has no output path outside SafeLog and the bundle writer" do
    files =
      Path.wildcard("lib/sdr_agent/prototype/**/*.ex") ++
        Path.wildcard("lib/mix/tasks/sdr.prototype.*.ex")

    allowed = ["lib/sdr_agent/prototype/safe_log.ex", "lib/sdr_agent/prototype/output.ex"]

    offenders =
      for file <- files,
          file not in allowed,
          Regex.match?(@output_call, File.read!(file)),
          do: file

    assert offenders == []
  end

  test "the output-call pattern matches each output form and no module path" do
    calls = [
      "IO.puts(x)",
      " IO.write(x)",
      "IO.inspect(x)",
      "Logger.error(x)",
      "Logger.log(:info, x)",
      "Elixir.Logger.error(x)",
      "Elixir.IO.puts(x)",
      " :io.format(x)",
      "(:io.put_chars(x))",
      " :logger.log(:info, x)",
      "Mix.shell().info(x)",
      " :logger.get_handler_config(:default)",
      " :logger.get_handler_config()",
      " :logger.add_handler(x)",
      "Logger.configure(level: :none)",
      "Logger.default_formatter(colors: [enabled: true])",
      " :logger.update_handler_config(:ssl_handler, :level, :none)",
      " :logger.update_handler_config(:ssl_handler, :formatter, other)",
      " :logger.update_handler_config(:default, :formatter, replacement)",
      " :logger.update_handler_config(:ssl_handler, %{})"
    ]

    paths = [
      "{Logger.Formatter, template, metadata, truncate}",
      "formatter({Logger.Formatter, %Logger.Formatter{}})",
      "{SdrAgent.Logger.ExceptionFilter, :filter, 2}",
      "require Logger",
      "Foo.IO.bar(x)",
      "case :logger.get_primary_config() do",
      "handler_ids(:logger.get_handler_ids(), restarts)",
      "ssl(Logger.default_formatter())",
      "with :ok <- :logger.update_handler_config(:ssl_handler, :formatter, replacement),"
    ]

    for call <- calls, do: assert(Regex.match?(@output_call, call), "not matched: #{call}")
    for path <- paths, do: refute(Regex.match?(@output_call, path), "matched: #{path}")
  end
end
