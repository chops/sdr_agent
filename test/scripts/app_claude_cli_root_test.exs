defmodule SdrAgent.Scripts.AppClaudeCLIRootTest do
  @moduledoc """
  Tests for `bin/app-claude-cli-root` (R0-02; ADR-0004 R0 amendment item
  1): the GC roots that keep the app's pinned Claude CLI and its rollback
  build alive.

  The script runs from a copy in a temporary project root with stub `nix`
  and `nix-store` first on `PATH`: no real build, no root registration and
  no garbage collection. The stub `nix build` links its staging root to a
  stand-in "store path" (`STUB_OUT`); the stub `nix-store --add-root` links
  the root (failing on request for one root), and `--check-validity` tests
  that the path exists. The temporary `nix/app-claude-cli.identity` records
  the expected stand-in for every platform.
  """
  # Spawns shell processes; each test owns its temporary root.
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/app-claude-cli-root", __DIR__)
  @systems ~w(aarch64-darwin x86_64-darwin aarch64-linux x86_64-linux)

  setup do
    root = Path.join(System.tmp_dir!(), "app-cli-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "nix"))
    File.mkdir_p!(Path.join(root, "stubs"))
    on_exit(fn -> File.rm_rf!(root) end)
    # The script resolves its root physically (pwd -P; macOS /tmp -> /private/tmp).
    {physical, 0} = System.cmd("pwd", ["-P"], cd: root)
    root = String.trim(physical)

    File.cp!(@script, Path.join(root, "bin/app-claude-cli-root"))
    File.chmod!(Path.join(root, "bin/app-claude-cli-root"), 0o755)

    stub!(root, "nix", """
    #!/bin/sh
    # nix build --out-link LINK -f FILE
    echo "nix $*" >> '#{root}/calls'
    [ "$1" = build ] || exit 2
    [ "${STUB_FAIL:-}" = build ] && exit 1
    mkdir '#{root}/busy' 2>/dev/null || echo overlap >> '#{root}/overlaps'
    sleep "${STUB_BUILD_SLEEP:-0}"
    ln -s "$STUB_OUT" "$3"
    rmdir '#{root}/busy'
    exit 0
    """)

    stub!(root, "nix-store", """
    #!/bin/sh
    echo "nix-store $*" >> '#{root}/calls'
    case "$1" in
      --check-validity) [ -e "$2" ]; exit $? ;;
      --add-root)
        [ -n "${STUB_FAIL:-}" ] && [ "$(basename "$2")" = "$STUB_FAIL" ] && exit 1
        ln -sfn "$4" "$2"
        echo "$4"
        exit 0
        ;;
    esac
    exit 2
    """)

    %{root: root, gcroots: Path.join(root, ".gcroots")}
  end

  test "a first run registers current only and prints the binary", ctx do
    a = build!(ctx, "a")
    pin!(ctx, a)

    assert {out, 0} = run(ctx, a)
    assert out == "#{a}/bin/claude-code\n"
    assert target(ctx, "current") == a
    assert target(ctx, "previous") == nil
    assert leftovers(ctx) == []
  end

  test "repeating the same pin rotates nothing", ctx do
    a = build!(ctx, "a")
    p0 = build!(ctx, "p0")
    pin!(ctx, a)
    link!(ctx, "current", a)
    link!(ctx, "previous", p0)

    assert {out, 0} = run(ctx, a)
    assert out == "#{a}/bin/claude-code\n"
    assert {target(ctx, "current"), target(ctx, "previous")} == {a, p0}
    refute Enum.any?(calls(ctx), &String.contains?(&1, "--add-root"))
    assert leftovers(ctx) == []
  end

  test "a changed pin rotates current to previous, then registers the build", ctx do
    a = build!(ctx, "a")
    b = build!(ctx, "b")
    pin!(ctx, b)
    link!(ctx, "current", a)

    assert {out, 0} = run(ctx, b)
    assert out == "#{b}/bin/claude-code\n"
    assert {target(ctx, "current"), target(ctx, "previous")} == {b, a}

    roots = Enum.filter(calls(ctx), &String.contains?(&1, "--add-root"))

    assert roots == [
             "nix-store --add-root #{ctx.gcroots}/app-claude-cli-previous --realise #{a}",
             "nix-store --add-root #{ctx.gcroots}/app-claude-cli-current --realise #{b}"
           ]

    assert leftovers(ctx) == []
  end

  describe "a failure at any step leaves current untouched and exits non-zero" do
    setup ctx do
      a = build!(ctx, "a")
      b = build!(ctx, "b")
      p0 = build!(ctx, "p0")
      pin!(ctx, b)
      link!(ctx, "current", a)
      link!(ctx, "previous", p0)
      %{a: a, b: b, p0: p0}
    end

    test "the build", ctx do
      assert {out, status} = run(ctx, ctx.b, [{"STUB_FAIL", "build"}])
      assert status != 0
      assert out =~ "nix build of nix/app-claude-cli-package.nix failed"
      assert {target(ctx, "current"), target(ctx, "previous")} == {ctx.a, ctx.p0}
      assert leftovers(ctx) == []
    end

    test "a build that is not the reviewed pin", ctx do
      other = build!(ctx, "other")
      assert {out, status} = run(ctx, other)
      assert status != 0
      assert out =~ "but nix/app-claude-cli.identity records #{ctx.b}"
      assert {target(ctx, "current"), target(ctx, "previous")} == {ctx.a, ctx.p0}
      assert leftovers(ctx) == []
    end

    test "registering the rollback root", ctx do
      assert {out, status} = run(ctx, ctx.b, [{"STUB_FAIL", "app-claude-cli-previous"}])
      assert status != 0
      assert out =~ "could not register the rollback root; current is unchanged"
      assert {target(ctx, "current"), target(ctx, "previous")} == {ctx.a, ctx.p0}
      assert leftovers(ctx) == []
    end

    test "registering current (the rollback root is restored)", ctx do
      assert {out, status} = run(ctx, ctx.b, [{"STUB_FAIL", "app-claude-cli-current"}])
      assert status != 0
      assert out =~ "could not register the current root; current is unchanged"
      assert {target(ctx, "current"), target(ctx, "previous")} == {ctx.a, ctx.p0}
      assert leftovers(ctx) == []
    end

    test "a platform the identity record does not list", ctx do
      File.write!(Path.join(ctx.root, "nix/app-claude-cli.identity"), "# no platforms\n")
      assert {out, status} = run(ctx, ctx.b)
      assert status != 0
      assert out =~ "no reviewed pin for"
      assert calls(ctx) == []
      assert target(ctx, "current") == ctx.a
    end
  end

  test "concurrent callers are serialized by the lock", ctx do
    a = build!(ctx, "a")
    pin!(ctx, a)

    results =
      1..3
      |> Enum.map(fn _ -> Task.async(fn -> run(ctx, a, [{"STUB_BUILD_SLEEP", "1"}]) end) end)
      |> Task.await_many(60_000)

    for result <- results, do: assert({_, 0} = result)
    refute File.exists?(Path.join(ctx.root, "overlaps")), "two builds overlapped"
    assert target(ctx, "current") == a
    assert leftovers(ctx) == []
  end

  test "a lock held by a live process times out; one left by a dead process is taken over",
       ctx do
    a = build!(ctx, "a")
    pin!(ctx, a)
    lock = Path.join(ctx.gcroots, "app-claude-cli.lock")
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "pid"), System.pid())

    assert {out, status} = run(ctx, a, [{"APP_CLAUDE_CLI_ROOT_LOCK_WAIT", "1"}])
    assert status != 0
    assert out =~ "another bin/app-claude-cli-root holds"
    assert target(ctx, "current") == nil
    assert File.read!(Path.join(lock, "pid")) == System.pid()

    {dead, 0} = System.cmd("sh", ["-c", "sh -c 'echo $$' "])
    File.write!(Path.join(lock, "pid"), String.trim(dead))

    assert {out, 0} = run(ctx, a)
    assert out =~ "took over a stale lock"
    assert target(ctx, "current") == a
    assert leftovers(ctx) == []
  end

  ## Helpers

  defp stub!(root, name, body) do
    path = Path.join([root, "stubs", name])
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  # A stand-in "store path" with an executable bin/claude-code.
  defp build!(ctx, name) do
    out = Path.join([ctx.root, "store", String.duplicate("0", 32) <> "-app-claude-cli-#{name}"])
    File.mkdir_p!(Path.join(out, "bin"))
    File.write!(Path.join(out, "bin/claude-code"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(out, "bin/claude-code"), 0o555)
    out
  end

  defp pin!(ctx, out) do
    lines = Enum.map(@systems, &"#{&1} #{out} #{String.duplicate("a", 64)}\n")
    File.write!(Path.join(ctx.root, "nix/app-claude-cli.identity"), ["# test\n" | lines])
  end

  defp link!(ctx, name, target) do
    File.mkdir_p!(ctx.gcroots)
    File.ln_s!(target, Path.join(ctx.gcroots, "app-claude-cli-#{name}"))
  end

  defp target(ctx, name) do
    case File.read_link(Path.join(ctx.gcroots, "app-claude-cli-#{name}")) do
      {:ok, target} -> target
      {:error, _} -> nil
    end
  end

  # Staging roots, locks and stale-lock leftovers must all be gone.
  defp leftovers(ctx) do
    ctx.gcroots
    |> File.ls!()
    |> Enum.reject(&(&1 in ["app-claude-cli-current", "app-claude-cli-previous"]))
  end

  defp calls(ctx) do
    case File.read(Path.join(ctx.root, "calls")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp run(ctx, out, extra \\ []) do
    env =
      [
        {"PATH", Path.join(ctx.root, "stubs") <> ":/usr/bin:/bin"},
        {"STUB_OUT", out},
        {"STUB_FAIL", nil},
        {"STUB_BUILD_SLEEP", nil},
        {"APP_CLAUDE_CLI_ROOT_LOCK_WAIT", nil},
        {"APP_CLAUDE_CLI_ROOT_LOCK_STALE", nil}
      ] ++ extra

    System.cmd(Path.join(ctx.root, "bin/app-claude-cli-root"), [],
      env: env,
      stderr_to_stdout: true
    )
  end
end
