defmodule SdrAgent.Scripts.DemoPinnedCLITest do
  @moduledoc """
  `bin/demo run` with `SDR_MODEL_PROVIDER=claude_cli` (R0-02): without
  `SDR_CLAUDE_CLI_BIN` it resolves the app's pinned CLI with
  `bin/app-claude-cli-root` and exports the printed path to the server; if
  that fails, the server never starts. A value already set is used as is
  (the boot check still verifies it).

  `bin/demo` runs from a copy in a temporary root next to a stub
  `bin/app-claude-cli-root`, with a stub `mix` first on `PATH` that records
  its arguments and the `SDR_CLAUDE_CLI_BIN` it was given: no build, no
  database and no server.
  """
  # Spawns shell processes; each test owns its temporary root.
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/demo", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "demo-pin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "stubs"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(@script, Path.join(root, "bin/demo"))
    File.chmod!(Path.join(root, "bin/demo"), 0o755)

    executable!(Path.join(root, "stubs/mix"), """
    #!/bin/sh
    echo "$* SDR_CLAUDE_CLI_BIN=${SDR_CLAUDE_CLI_BIN:-unset}" >> '#{root}/mix-calls'
    if [ "$1" = run ]; then echo "SDR_DEMO_REPO localhost 5520 sdr_agent_dev"; fi
    exit 0
    """)

    %{root: root}
  end

  test "resolves the pinned CLI with bin/app-claude-cli-root and hands it to the server",
       ctx do
    pinned = "/nix/store/#{String.duplicate("0", 32)}-app-claude-cli-0/bin/claude-code"
    resolver!(ctx, "echo resolved >> '#{ctx.root}/resolver-calls'; echo '#{pinned}'")

    assert {out, 0} = demo(ctx, [{"SDR_MODEL_PROVIDER", "claude_cli"}])
    assert out =~ "model: claude_cli via pinned CLI #{pinned}"
    assert out =~ "real model calls stay staged"
    assert File.read!(Path.join(ctx.root, "resolver-calls")) == "resolved\n"
    assert List.last(mix_calls(ctx)) == "phx.server SDR_CLAUDE_CLI_BIN=#{pinned}"
  end

  test "a failing resolver stops before the server starts", ctx do
    resolver!(ctx, "echo 'app-claude-cli-root: nix build failed' >&2; exit 1")

    assert {out, 1} = demo(ctx, [{"SDR_MODEL_PROVIDER", "claude_cli"}])
    assert out =~ "could not build or locate the app's pinned Claude CLI"
    refute Enum.any?(mix_calls(ctx), &String.starts_with?(&1, "phx.server"))
  end

  test "an explicit SDR_CLAUDE_CLI_BIN is passed through without resolving", ctx do
    resolver!(ctx, "echo resolved >> '#{ctx.root}/resolver-calls'; exit 1")
    given = "/nix/store/#{String.duplicate("1", 32)}-app-claude-cli-0/bin/claude-code"

    assert {_out, 0} =
             demo(ctx, [{"SDR_MODEL_PROVIDER", "claude_cli"}, {"SDR_CLAUDE_CLI_BIN", given}])

    refute File.exists?(Path.join(ctx.root, "resolver-calls"))
    assert List.last(mix_calls(ctx)) == "phx.server SDR_CLAUDE_CLI_BIN=#{given}"
  end

  test "the fake provider never resolves a pinned CLI", ctx do
    resolver!(ctx, "echo resolved >> '#{ctx.root}/resolver-calls'; exit 1")

    assert {out, 0} = demo(ctx, [{"SDR_MODEL_PROVIDER", nil}])
    refute out =~ "pinned CLI"
    refute File.exists?(Path.join(ctx.root, "resolver-calls"))
    assert List.last(mix_calls(ctx)) == "phx.server SDR_CLAUDE_CLI_BIN=unset"
  end

  defp resolver!(ctx, body),
    do: executable!(Path.join(ctx.root, "bin/app-claude-cli-root"), "#!/bin/sh\n#{body}\n")

  defp executable!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp mix_calls(ctx) do
    case File.read(Path.join(ctx.root, "mix-calls")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp demo(ctx, extra) do
    env =
      [
        {"PATH", Path.join(ctx.root, "stubs") <> ":" <> System.get_env("PATH")},
        {"MIX_ENV", nil},
        {"DATABASE_URL", nil},
        {"SDR_CLAUDE_CLI_BIN", nil},
        {"PORT", to_string(free_port())}
      ] ++ extra

    System.cmd(Path.join(ctx.root, "bin/demo"), ["run"], env: env, stderr_to_stdout: true)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
