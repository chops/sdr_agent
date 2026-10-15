defmodule SdrAgent.Scripts.CalibrationConsoleWitnessTest do
  @moduledoc """
  R0-07f RED (contract PASS at `0ee216e`, C5, C5a, tests 4, 7 and 9):
  `bin/calibration-console` and the witness store root.

    * **The outer guard (C5a).** `calibrate` and `calibrate-recover ID`
      refuse an unset `SDR_WITNESS_STORE_ROOT` before any Mix command; a
      stub `mix` first on `PATH` proves none ran. `calibrate-recover
      --release-aborted` and the other commands are unaffected.
    * **The witness line (C5).** `check` reads exactly one plan line and
      exactly one `SDR_CALIBRATION_WITNESS` line, compares the root byte for
      byte with its own variable (a space round-trips), and refuses a
      missing, duplicate, forged or mismatched line. The plan line is
      unchanged.
    * One test runs the real `mix sdr.calibration.console check` with
      `HOME` in a temporary directory; it touches no database.

  No test creates, migrates, serves or drops `sdr_agent_calibration`; no
  model call.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Test.WitnessRoot

  @script Path.expand("../../bin/calibration-console", __DIR__)
  @good_plan "SDR_CALIBRATION_CONSOLE sdr_agent_calibration localhost 5520 127.0.0.1 4124 " <>
               "SdrAgent.AI.ModelProvider.Fake none"
  @moduletag timeout: 300_000

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "calibration-witness-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "bin"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Answers check with STUB_OUTPUT verbatim (one line per printf line).
    stub = Path.join(tmp, "bin/mix")

    File.write!(stub, """
    #!/bin/sh
    echo "$*" >> "#{tmp}/mix-calls"
    if [ "$2" = check ]; then printf '%s\\n' "$STUB_OUTPUT"; fi
    exit 0
    """)

    File.chmod!(stub, 0o755)

    root = WitnessRoot.mkdir!("r007f wrapper")
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      tmp: tmp,
      root: root,
      stub_path: Path.join(tmp, "bin") <> ":" <> System.get_env("PATH"),
      calls: Path.join(tmp, "mix-calls")
    }
  end

  defp console(args, env), do: System.cmd(@script, args, env: env, stderr_to_stdout: true)

  defp stubbed(ctx, output, extra) do
    [
      {"PATH", ctx.stub_path},
      {"HOME", ctx.tmp},
      {"MIX_ENV", nil},
      {"DATABASE_URL", nil},
      {"PORT", nil},
      {"SDR_MODEL_PROVIDER", nil},
      {"SDR_CLAUDE_CLI_BIN", nil},
      {"SDR_WITNESS_STORE_ROOT", nil},
      {"STUB_OUTPUT", output}
    ]
    |> then(&Enum.reduce(extra, &1, fn {k, _} = kv, env -> List.keystore(env, k, 0, kv) end))
  end

  defp mix_calls(ctx) do
    case File.read(ctx.calls) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp set_line(root), do: "SDR_CALIBRATION_WITNESS set " <> root
  @unset_line "SDR_CALIBRATION_WITNESS unset"

  describe "the outer guard: capture-required commands need the root" do
    for args <- [
          ["calibrate", "claude_cli_opus"],
          ["calibrate", "claude_cli_sonnet"],
          ["calibrate-recover", "01a13522-3260-73a7-a5c3-87aca9f1d310"],
          [
            "calibrate-recover",
            "01a13522-3260-73a7-a5c3-87aca9f1d310",
            "--owner-verified-stopped"
          ]
        ] do
      test "#{Enum.join(args, " ")} refuses an unset root before any Mix command", ctx do
        for value <- [nil, ""] do
          env =
            stubbed(ctx, @good_plan <> "\n" <> @unset_line, [{"SDR_WITNESS_STORE_ROOT", value}])

          assert {out, 2} = console(unquote(args), env)
          assert out =~ "SDR_WITNESS_STORE_ROOT is not set"
          assert mix_calls(ctx) == [], "a Mix command ran before the refusal"
        end
      end
    end

    test "release-aborted, check and bootstrap-admin run without it", ctx do
      env = stubbed(ctx, @good_plan <> "\n" <> @unset_line, [])

      assert {_out, 0} = console(["calibrate-recover", "--release-aborted"], env)
      assert {_out, 0} = console(["check"], env)
      assert {_out, 0} = console(["bootstrap-admin", "--email", "a@example.test"], env)
    end
  end

  describe "check reports the witness store" do
    test "a set root, with a space, round-trips and is reported", ctx do
      env =
        stubbed(ctx, @good_plan <> "\n" <> set_line(ctx.root), [
          {"SDR_WITNESS_STORE_ROOT", ctx.root}
        ])

      assert {out, 0} = console(["check"], env)
      assert out =~ "witness store #{ctx.root} (trusted at check)"
    end

    test "an unset root is reported, and check still exits 0", ctx do
      assert {out, 0} = console(["check"], stubbed(ctx, @good_plan <> "\n" <> @unset_line, []))

      assert out =~
               "witness store unset: calibrate and calibrate-recover ID will refuse; " <>
                 "set SDR_WITNESS_STORE_ROOT"
    end

    test "a missing, duplicate, forged or mismatched line is refused", ctx do
      other = ctx.root <> "-other"
      present = [{"SDR_WITNESS_STORE_ROOT", ctx.root}]

      cases = [
        {"no witness line", @good_plan, present},
        {"two witness lines",
         Enum.join([@good_plan, set_line(ctx.root), set_line(ctx.root)], "\n"), present},
        {"a second plan line", Enum.join([@good_plan, @good_plan, set_line(ctx.root)], "\n"),
         present},
        {"a different root", @good_plan <> "\n" <> set_line(other), present},
        {"a trailing space", @good_plan <> "\n" <> set_line(ctx.root) <> " ", present},
        {"set while the variable is unset", @good_plan <> "\n" <> set_line(ctx.root), []},
        {"unset while the variable is set", @good_plan <> "\n" <> @unset_line, present}
      ]

      for {label, output, extra} <- cases do
        {out, status} = console(["check"], stubbed(ctx, output, extra))
        assert status == 2, "#{label}: exit #{status}"
        assert out =~ "refusing", label
      end
    end
  end

  describe "the real check task" do
    test "prints the unchanged plan line and exactly one witness line", ctx do
      env = [
        {"MIX_ENV", "test"},
        {"HOME", ctx.tmp},
        {"DATABASE_URL", nil},
        {"PORT", nil},
        {"SDR_MODEL_PROVIDER", "fake"},
        {"SDR_WITNESS_STORE_ROOT", ctx.root}
      ]

      assert {out, 0} =
               System.cmd("mix", ["sdr.calibration.console", "check"],
                 env: env,
                 stderr_to_stdout: true
               )

      lines = String.split(out, "\n")

      assert Enum.filter(lines, &String.starts_with?(&1, "SDR_CALIBRATION_CONSOLE ")) == [
               @good_plan
             ]

      assert Enum.filter(lines, &String.starts_with?(&1, "SDR_CALIBRATION_WITNESS")) == [
               set_line(ctx.root)
             ]
    end
  end
end
