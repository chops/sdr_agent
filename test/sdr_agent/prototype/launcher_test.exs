defmodule SdrAgent.Prototype.LauncherTest do
  @moduledoc """
  HELD. Refusal controls for the D-237 launcher `bin/d237` and its serve
  output helper `bin/d237-serve-out` (S1b plan r4 §2, I2 r2).

  - **Not run in I2.** Every case starts a short-lived `/bin/sh` through
    `/usr/bin/env -i`, so the module is tagged `:external` (excluded by
    `test/test_helper.exs`). It runs only under its own process-execution
    grant, with an explicit include, on a build compiled in a prior step.
  - **No case may start Mix.** Every launcher case triggers a refusal that
    the launcher checks BEFORE `exec`, in this fixed order: `debug_env`,
    `otel_env`, `vm_flags_env`, `loader_env`, `crash_dump_env`,
    `mix_override_env`, `listener_env`, `mix_env`, `switch_env`,
    `unknown_command`, `toolchain_mismatch`. The serve output checks
    (`log_dir_unsafe`, `log_file_unsafe`) are exercised on the helper
    only, against fresh 0700 scratch directories, never the real
    prototype root.
  - **Special files are SOURCE ONLY.** The FIFO and device-symlink
    controls are tagged `:d237_special_files` and must not run without
    their own grant: no FIFO or device is created or opened under any
    I2 grant.
  - At the base the launcher and the helper are absent, so every case
    fails on a structural prerequisite (the script is missing), not a
    semantic one. The launcher source belongs to GREEN.
  - An expected refusal line alone does NOT prove that Mix was never
    started. A later execution grant must add child ownership and lifetime
    accounting for these shells; none is claimed here.
  - The positive scratch fixture must itself satisfy EVERY ancestor rule
    (no symlink component, owner the uid or root, no group/other write).
    An unsuitable fixture raises `fixture_unsuitable` in setup: a STOP for
    the run, never a reason to weaken the production rule.

  Output assertions compare the whole captured output with the one closed
  line; a value planted in a refused variable must never appear.
  """
  use ExUnit.Case, async: false

  @moduletag :external

  @env "/usr/bin/env"
  @sh "/bin/sh"
  @launcher Path.expand("bin/d237")
  @helper Path.expand("bin/d237-serve-out")
  @elixir_bin "/nix/store/f3f6n5g6x3v5zazdrp6hns9vhhjqkri9-elixir-1.20.4/bin"
  @erlang_bin "/nix/store/0npp3qpr68phld0d5jffn13si9qngvk7-erlang-29.0.5/bin"
  @path Enum.join([@elixir_bin, @erlang_bin, "/usr/bin", "/bin"], ":")
  @value "S1B-I2-L-0123456789abcdef"

  # A complete, otherwise valid environment; each case adds exactly one
  # trigger and a command that would otherwise reach `exec`.
  defp base do
    [
      {"PATH", @path},
      {"HOME", System.tmp_dir!()},
      {"MIX_ENV", "dev"},
      {"SDR_PROTOTYPE", "d237-prototype/1"},
      {"SDR_PROTOTYPE_INSTANCE", "00000000-0000-4000-8000-000000000237"}
    ]
  end

  defp launch(pairs, args) do
    env_args = Enum.map(pairs, fn {k, v} -> k <> "=" <> v end)
    System.cmd(@env, ["-i" | env_args] ++ [@sh, @launcher | args], stderr_to_stdout: true)
  end

  defp refused(code), do: {"prototype: launcher_refused reason=#{code}\n", 64}

  defp put(pairs, name, value), do: List.keystore(pairs, name, 0, {name, value})
  defp drop(pairs, name), do: List.keydelete(pairs, name, 0)

  describe "bin/d237 environment refusals (presence, never the value)" do
    for {name, code} <- [
          {"MIX_DEBUG", "debug_env"},
          {"MIX_PROFILE", "debug_env"},
          {"MIX_PROFILE_FLAGS", "debug_env"},
          {"OTEL_TRACES_EXPORTER", "otel_env"},
          {"OTEL_SDK_DISABLED", "otel_env"},
          {"OTEL_X", "otel_env"},
          {"ERL_FLAGS", "vm_flags_env"},
          {"ERL_ZFLAGS", "vm_flags_env"},
          {"ELIXIR_ERL_OPTIONS", "vm_flags_env"},
          {"ERL_LIBS", "loader_env"},
          {"ERL_CRASH_DUMP", "crash_dump_env"},
          {"MIX_EXS", "mix_override_env"},
          {"MIX_TARGET", "mix_override_env"},
          {"PHX_SERVER", "listener_env"},
          {"PORT", "listener_env"}
        ] do
      test "#{name} present (also when empty) refuses with #{code}" do
        for value <- [@value, ""] do
          {out, status} = launch(put(base(), unquote(name), value), ["op", "status"])
          refute String.contains?(out, @value)
          assert {out, status} == refused(unquote(code))
        end
      end
    end

    test "ERL_CRASH_DUMP_BYTES other than exactly 0 refuses; 0 does not" do
      for value <- ["1", "00", " 0", ""] do
        assert launch(put(base(), "ERL_CRASH_DUMP_BYTES", value), ["bogus"]) ==
                 refused("crash_dump_env")
      end

      assert launch(put(base(), "ERL_CRASH_DUMP_BYTES", "0"), ["bogus"]) ==
               refused("unknown_command")
    end

    test "ERL_AFLAGS (set by the pinned devenv) is dropped, not refused" do
      pairs = put(base(), "ERL_AFLAGS", "-kernel shell_history enabled")
      assert launch(pairs, ["bogus"]) == refused("unknown_command")
    end

    test "MIX_ENV must be exactly dev" do
      for pairs <- [drop(base(), "MIX_ENV"), put(base(), "MIX_ENV", "test")] do
        assert launch(pairs, ["op", "status"]) == refused("mix_env")
      end
    end

    test "both switch variables must be present" do
      for name <- ["SDR_PROTOTYPE", "SDR_PROTOTYPE_INSTANCE"] do
        assert launch(drop(base(), name), ["op", "status"]) == refused("switch_env")
      end
    end

    test "the first failing check in the fixed order is the one reported" do
      pairs = base() |> put("PORT", "1") |> put("MIX_DEBUG", "1") |> put("OTEL_X", "1")
      assert launch(pairs, ["bogus"]) == refused("debug_env")
    end
  end

  describe "bin/d237 command and toolchain refusals" do
    test "anything but the five mapped commands is refused" do
      for args <- [
            [],
            ["bogus"],
            ["export"],
            ["sdr.prototype.op"],
            ["op;true"],
            ["OP"],
            [" op"]
          ] do
        assert launch(base(), args) == refused("unknown_command")
      end
    end

    test "a PATH that does not resolve to the pinned toolchain is refused" do
      for path <- ["/usr/bin:/bin", @elixir_bin <> ":/usr/bin:/bin"] do
        assert launch(put(base(), "PATH", path), ["op", "status"]) ==
                 refused("toolchain_mismatch")
      end
    end
  end

  describe "bin/d237-serve-out (scratch directories only)" do
    setup do
      root = suitable_root!(real_tmp())
      parent = Path.join(root, "d237-launcher-" <> Ecto.UUID.generate())
      :ok = File.mkdir(parent)
      :ok = File.chmod(parent, 0o700)
      dir = Path.join(parent, "log")
      on_exit(fn -> File.rm_rf(parent) end)
      {:ok, parent: parent, dir: dir}
    end

    test "a fresh 0700 directory gets a new, empty, 0600 regular file", %{dir: dir} do
      private_dir!(dir)
      {out, status} = serve_out(dir)
      assert status == 0
      path = String.trim_trailing(out, "\n")
      assert Path.dirname(path) == dir
      assert Regex.match?(~r/\Aserve-\d{8}T\d{6}Z-[A-Za-z0-9]{8}\z/, Path.basename(path))
      assert {:ok, %File.Stat{type: :regular, size: 0} = stat} = File.lstat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "two runs never reuse a file", %{dir: dir} do
      private_dir!(dir)
      {first, 0} = serve_out(dir)
      {second, 0} = serve_out(dir)
      refute first == second
    end

    test "an unsafe log directory is refused before any file is created", %{
      parent: parent,
      dir: dir
    } do
      target = private_dir!(Path.join(parent, "target"))

      cases = [
        fn -> :ok end,
        fn -> File.write!(dir, "") end,
        fn -> File.ln_s!(target, dir) end,
        fn -> File.ln_s!(Path.join(parent, "absent"), dir) end,
        fn ->
          File.mkdir!(dir)
          File.chmod!(dir, 0o755)
        end,
        fn ->
          File.mkdir!(dir)
          File.chmod!(dir, 0o770)
        end,
        fn ->
          private_dir!(dir)
          File.chmod!(parent, 0o777)
        end
      ]

      for arrange <- cases do
        File.chmod(parent, 0o700)
        File.rm_rf!(dir)
        arrange.()
        assert serve_out(dir) == {"prototype: launcher_refused reason=log_dir_unsafe\n", 64}
        assert File.ls!(target) == []
      end

      assert serve_out("relative/log") ==
               {"prototype: launcher_refused reason=log_dir_unsafe\n", 64}
    end

    test "existing entries in the directory are never opened or changed", %{
      parent: parent,
      dir: dir
    } do
      private_dir!(dir)
      regular = Path.join(dir, "regular")
      File.write!(regular, "kept")
      File.ln_s!(regular, Path.join(dir, "link"))
      File.ln_s!(Path.join(parent, "absent"), Path.join(dir, "dangling"))
      before = File.ls!(dir) |> Enum.sort()

      {_out, 0} = serve_out(dir)

      added = Enum.sort(File.ls!(dir)) -- before
      assert File.read!(regular) == "kept"
      assert length(added) == 1
      refute File.exists?(Path.join(parent, "absent"))
    end

    @tag :d237_special_files
    test "SOURCE ONLY: a FIFO or a device symlink in the directory is never opened", %{
      dir: dir
    } do
      private_dir!(dir)
      {_out, 0} = System.cmd("/usr/bin/mkfifo", [Path.join(dir, "fifo")])
      File.ln_s!("/dev/null", Path.join(dir, "device"))
      assert {_path, 0} = serve_out(dir)
    end
  end

  defp serve_out(dir) do
    args = ["-i", "PATH=/usr/bin:/bin", @sh, @helper, dir]
    System.cmd(@env, args, stderr_to_stdout: true)
  end

  defp private_dir!(dir) do
    :ok = File.mkdir(dir)
    :ok = File.chmod(dir, 0o700)
    dir
  end

  # Every component from / down to `root` must satisfy the production
  # ancestor rule; otherwise the fixture is unsuitable (a STOP).
  defp suitable_root!(root) do
    {uid, 0} = System.cmd("/usr/bin/id", ["-u"])
    uid = uid |> String.trim_trailing("\n") |> String.to_integer()

    components =
      root
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))

    unless Enum.all?(components, &ancestor_ok?(&1, uid)), do: raise("fixture_unsuitable")
    root
  end

  defp ancestor_ok?(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} ->
        owner in [uid, 0] and Bitwise.band(mode, 0o022) == 0

      _other ->
        false
    end
  end

  defp real_tmp do
    script = "cd -P \"$1\" && pwd"
    {resolved, 0} = System.cmd(@sh, ["-c", script, "sh", System.tmp_dir!()])
    String.trim_trailing(resolved, "\n")
  end
end
