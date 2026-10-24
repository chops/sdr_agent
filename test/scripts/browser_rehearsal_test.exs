defmodule SdrAgent.Scripts.BrowserRehearsalTest do
  @moduledoc """
  The Fake-browser rehearsal must refuse unsafe caller inputs before it
  starts Mix, a database utility or a browser. These cases deliberately use
  recording command stubs and need no demo server or database in the body.
  Each candidate runs from a temporary fixture root with a private PATH;
  inherited shell startup files and a real CHROME executable are excluded.
  Controls below exercise the refusal oracle independently of the absent
  wrapper. They are not evidence of rehearsal implementation behavior.

  RED checkpoint: the wrapper does not exist yet. Its presence assertion is
  a structural guard, not evidence that any refusal behavior was exercised.
  The remaining effective-config, lifecycle and full-browser cases belong
  to later authoring slices in the approved rehearsal plan.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "bin/browser-rehearsal")
  @offering Path.join(@root, "test/fixtures/browser_rehearsal_offering.json")
  @offering_sha256 "9c34818ba69acd6818cd5e4c206a401b93fc405af5fc1f9b83efc75f6110adaf"
  @secret_canary "do-not-print"

  setup do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    tmp = Path.join(System.tmp_dir!(), "browser-rehearsal-test-#{suffix}")
    stub_dir = Path.join(tmp, "bin")
    calls = Path.join(tmp, "external-calls")
    File.mkdir_p!(stub_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    for command <- ~w(mix elixir erl node createdb dropdb psql pg_isready lsof curl wget
                      google-chrome chromium chromium-browser open claude claude-code
                      demo app-claude-cli-root) do
      executable!(Path.join(stub_dir, command), """
      printf '#{command}\\n' >> "$REHEARSAL_TEST_CALLS"
      exit 97
      """)
    end

    # Permit only these read-only path utilities for locating the wrapper's
    # root. Do not append the caller's PATH, which contains real tools.
    for command <- ~w(basename dirname) do
      executable = System.find_executable(command)
      assert is_binary(executable), "required path utility is unavailable: #{command}"
      File.ln_s!(executable, Path.join(stub_dir, command))
    end

    %{root: tmp, calls: calls, stub_dir: stub_dir}
  end

  @tag :rehearsal_harness
  test "P3 is one hash-pinned synthetic fixture with an empty revision note" do
    bytes = File.read!(@offering)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @offering_sha256

    assert %{
             "name" => "Example Widgets Co",
             "revision_note" => "",
             "items" => [
               %{"id" => "pallet_counter", "kind" => "feature"},
               %{"id" => "synthetic_only", "kind" => "limit"}
             ]
           } = Jason.decode!(bytes)
  end

  @tag :rehearsal_harness
  test "control: the oracle accepts an exact refusal with no external call", ctx do
    candidate = control!(ctx, "printf 'refusing: MIX_ENV must be test\\n'; exit 2")

    assert_refused(ctx, [], [{"MIX_ENV", "dev"}], "MIX_ENV must be test", candidate)
  end

  for {label, body, message} <- [
        {"a successful exit", "printf 'refusing: MIX_ENV must be test\\n'; exit 0",
         "expected refusal exit status 2, got 0"},
        {"a missing refusal marker", "printf 'MIX_ENV must be test\\n'; exit 2",
         "missing refusal marker"},
        {"an unrelated refusal reason", "printf 'refusing: unrelated failure\\n'; exit 2",
         "missing expected refusal reason: MIX_ENV must be test"},
        {"a leaked secret canary",
         "printf 'refusing: MIX_ENV must be test do-not-print\\n'; exit 2",
         "refusal output exposed the synthetic secret canary"}
      ] do
    @tag :rehearsal_harness
    test "control: the oracle rejects #{label}", ctx do
      candidate = control!(ctx, unquote(body))

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_refused(ctx, [], [{"MIX_ENV", "dev"}], "MIX_ENV must be test", candidate)
        end

      assert error.message == unquote(message)
      assert File.read(ctx.calls) == {:error, :enoent}
    end
  end

  for {label, command, recorded} <- [
        {"a PATH-resolved Mix call", "mix", "mix"},
        {"a repository-relative demo call", "bin/demo", "demo"},
        {"a CHROME override call", ~s("$CHROME"), "google-chrome"}
      ] do
    @tag :rehearsal_harness
    test "control: the oracle detects #{label} before refusal", ctx do
      candidate =
        control!(ctx, unquote(command) <> "\nprintf 'refusing: MIX_ENV must be test\\n'\nexit 2")

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_refused(ctx, [], [{"MIX_ENV", "dev"}], "MIX_ENV must be test", candidate)
        end

      assert error.message == "unsafe input reached an external command"
      assert File.read!(ctx.calls) == unquote(recorded) <> "\n"
    end
  end

  @tag :rehearsal_harness
  test "control: the child receives only the private tool path and no shell startup hooks", ctx do
    candidate =
      control!(ctx, """
      [ "$PATH" = "$REHEARSAL_TEST_ROOT/bin" ] || exit 81
      [ "$CHROME" = "$REHEARSAL_TEST_ROOT/bin/google-chrome" ] || exit 82
      [ -z "${BASH_ENV+x}" ] || exit 83
      [ -z "${ENV+x}" ] || exit 84
      [ -z "${CDPATH+x}" ] || exit 85
      [ "$PWD" -ef "$REHEARSAL_TEST_ROOT" ] || exit 86
      printf 'refusing: MIX_ENV must be test\\n'
      exit 2
      """)

    assert_refused(ctx, [], [{"MIX_ENV", "dev"}], "MIX_ENV must be test", candidate)
  end

  for {label, env, reason} <- [
        {"a dev environment", [{"MIX_ENV", "dev"}], "MIX_ENV must be test"},
        {"a production environment", [{"MIX_ENV", "prod"}], "MIX_ENV must be test"},
        {"DATABASE_URL", [{"DATABASE_URL", "ecto://fixture:do-not-print@localhost/dev"}],
         "DATABASE_URL is set"},
        {"the real model provider", [{"SDR_MODEL_PROVIDER", "claude_cli"}],
         "model provider must be fake"},
        {"an unknown model provider", [{"SDR_MODEL_PROVIDER", "unreviewed"}],
         "model provider must be fake"},
        {"a differently cased real provider", [{"SDR_MODEL_PROVIDER", "ClaudeCLI"}],
         "model provider must be fake"},
        {"the dev port", [{"PORT", "4120"}], "port must be 4122"},
        {"a silently substituted port", [{"PORT", "4999"}], "port must be 4122"},
        {"a URL in the port variable", [{"PORT", "http://127.0.0.1:4122"}], "port must be 4122"},
        {"a caller-selected partition", [{"MIX_TEST_PARTITION", "_reused_demo"}],
         "MIX_TEST_PARTITION is set"},
        {"a partition with shell syntax", [{"MIX_TEST_PARTITION", "_x;exit 0"}],
         "MIX_TEST_PARTITION is set"}
      ] do
    @tag :rehearsal_red
    test "refuses #{label} before an external command", ctx do
      assert_refused(ctx, [], unquote(Macro.escape(env)), unquote(reason))
    end
  end

  for {label, args} <- [
        {"a dev-mode flag", ["--dev"]},
        {"a forced cleanup flag", ["--force"]},
        {"a reused-target flag", ["--reuse"]},
        {"a caller-selected database", ["--database", "sdr_agent_dev"]},
        {"a caller-selected dev URL", ["http://127.0.0.1:4120"]},
        {"a caller-selected remote URL", ["https://app.example.test"]},
        {"a path-traversal target", ["--database", "../sdr_agent_dev"]}
      ] do
    @tag :rehearsal_red
    test "refuses #{label} before an external command", ctx do
      assert_refused(ctx, unquote(args), [], "does not accept arguments")
    end
  end

  defp assert_refused(ctx, args, overrides, reason, candidate \\ @script) do
    assert File.regular?(candidate),
           "RED structural guard: bin/browser-rehearsal is not implemented; no behavior exercised"

    script = Path.join(ctx.stub_dir, "browser-rehearsal")
    File.cp!(candidate, script)

    env =
      %{
        "PATH" => ctx.stub_dir,
        "BASH_ENV" => nil,
        "ENV" => nil,
        "CDPATH" => nil,
        "SHELLOPTS" => nil,
        "BASHOPTS" => nil,
        "CHROME" => Path.join(ctx.stub_dir, "google-chrome"),
        "REHEARSAL_TEST_CALLS" => ctx.calls,
        "REHEARSAL_TEST_ROOT" => ctx.root,
        "MIX_ENV" => nil,
        "DATABASE_URL" => nil,
        "SDR_MODEL_PROVIDER" => nil,
        "SDR_CLAUDE_CLI_BIN" => nil,
        "SDR_WITNESS_STORE_ROOT" => nil,
        "MIX_TEST_PARTITION" => nil,
        "PORT" => nil
      }
      |> Map.merge(Map.new(overrides))
      |> Map.to_list()

    {output, status} =
      System.cmd("/bin/bash", ["--noprofile", "--norc", script | args],
        cd: ctx.root,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 2, "expected refusal exit status 2, got #{status}"
    assert output =~ "refusing:", "missing refusal marker"
    assert output =~ reason, "missing expected refusal reason: #{reason}"

    refute output =~ @secret_canary, "refusal output exposed the synthetic secret canary"

    assert File.read(ctx.calls) == {:error, :enoent}, "unsafe input reached an external command"
  end

  defp control!(ctx, body) do
    path = Path.join(ctx.root, "control.sh")
    executable!(path, body)
    path
  end

  defp executable!(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end
end
