defmodule SdrAgent.ChildEnvTest do
  @moduledoc """
  Security: external processes never inherit the application's secrets.
  When the server runs under `bin/with-secrets SDR_AUDIT_ANCHOR_PRIVATE_KEY
  -- bin/demo run`, every child it launches — the ClaudeCLI port, the
  anchoring Git and OpenTimestamps subprocesses, the provenance `git` — gets
  an explicit environment allowlist; every other name of the parent
  environment is removed, and secret-looking names (`*_KEY`, `*_TOKEN`,
  `*_SECRET`, …) are removed even if allowlisted. Each launcher is exercised
  with a real child process that records only the NAMES of its environment.
  """
  # Sets process environment variables and PATH.
  use ExUnit.Case, async: false

  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit.AnchorSinks.GitSink
  alias SdrAgent.Audit.AnchorSinks.OpenTimestampsSink
  alias SdrAgent.Audit.Provenance
  alias SdrAgent.ChildEnv

  @fake Path.expand("../support/fake_claude_cli.exs", __DIR__)

  setup do
    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.encode16()
    # Canary names are built at runtime: no literal secret name to match.
    canaries = [
      "SDR_AUDIT_ANCHOR_PRIVATE_KEY",
      "SDR_CANARY_#{suffix}_KEY",
      "SDR_CANARY_#{suffix}_TOKEN",
      "SDR_CANARY_#{suffix}_SECRET",
      "SDR_CANARY_#{suffix}_UNLISTED"
    ]

    previous = Map.new(["PATH" | canaries], &{&1, System.get_env(&1)})
    Enum.each(canaries, &System.put_env(&1, "canary-value-#{suffix}"))

    dir = Path.join(System.tmp_dir!(), "sdr-child-env-#{suffix}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      File.rm_rf!(dir)
    end)

    %{canaries: canaries, dir: dir, suffix: suffix}
  end

  defp assert_clean(names, canaries) do
    for canary <- canaries, do: refute(canary in names, "#{canary} reached the child")
    assert "PATH" in names
  end

  # A fake executable that appends its environment's NAMES to `dump`. As
  # `git`, `rev-parse` succeeds silently (GitSink asks it for Git's local
  # variables first); everything else exits with `exit_status`.
  defp fake_tool!(dir, name, dump, exit_status) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    env | cut -d= -f1 >> '#{dump}'
    case "$1" in rev-parse) exit 0 ;; esac
    exit #{exit_status}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp names(dump), do: dump |> File.read!() |> String.split("\n", trim: true)

  describe "ChildEnv" do
    test "removes every name outside the allowlist, keeps the base, applies sets", ctx do
      env = Map.new(ChildEnv.cmd(["EXTRA_ALLOWED"], [{"TZ", "UTC"}]))

      for canary <- ctx.canaries, do: assert(Map.fetch!(env, canary) == nil)
      refute Map.has_key?(env, "PATH")
      assert env["TZ"] == "UTC"
    end

    test "never keeps a secret-looking name even when allowlisted", ctx do
      [key | _] = Enum.filter(ctx.canaries, &String.ends_with?(&1, "_KEY"))
      env = Map.new(ChildEnv.cmd([key, "SDR_AUDIT_ANCHOR_PRIVATE_KEY"], []))

      assert env[key] == nil and Map.has_key?(env, key)
      assert Map.has_key?(env, "SDR_AUDIT_ANCHOR_PRIVATE_KEY")
    end

    test "an overlay never restores a secret-looking name (cmd and port, present or absent)",
         ctx do
      absent = "SDR_OVERLAY_#{ctx.suffix}_SECRET"
      [present | _] = Enum.filter(ctx.canaries, &String.ends_with?(&1, "_TOKEN"))

      for name <- [absent, present, "SDR_AUDIT_ANCHOR_PRIVATE_KEY"] do
        overlays = [[{name, "synthetic"}], [{name, nil}, {name, "synthetic"}]]

        for overlay <- overlays do
          refute Enum.any?(
                   ChildEnv.cmd([], overlay),
                   &match?({^name, value} when is_binary(value), &1)
                 ),
                 "cmd overlay restored a secret-looking name"

          charname = String.to_charlist(name)

          refute Enum.any?(
                   ChildEnv.port([], overlay),
                   &match?({^charname, value} when is_list(value), &1)
                 ),
                 "port overlay restored a secret-looking name"
        end
      end

      assert {"SDR_TRACEPARENT", "00-x"} in ChildEnv.cmd([], [{"SDR_TRACEPARENT", "00-x"}])
    end

    test "known application secrets are removed even when absent from the snapshot" do
      env = Map.new(ChildEnv.cmd([]))

      for name <- ~w(SDR_AUDIT_ANCHOR_PRIVATE_KEY SDR_WEBHOOK_HMAC_KEY SECRET_KEY_BASE
                     TOKEN_SIGNING_SECRET DATABASE_URL) do
        assert Map.fetch(env, name) == {:ok, nil}, "#{name} is not unconditionally removed"
      end
    end

    test "locale and XDG names are an exact set, not whole namespaces", ctx do
      for name <- ["LC_#{ctx.suffix}", "XDG_#{ctx.suffix}"] do
        refute ChildEnv.kept?(name, ChildEnv.xdg()), "#{name} passed as part of a namespace"
      end

      assert ChildEnv.kept?("LC_ALL", [])
      assert ChildEnv.kept?("XDG_CONFIG_HOME", ChildEnv.xdg())
    end

    test "the port form uses charlists and false for removal", ctx do
      env = Map.new(ChildEnv.port([], [{"SDR_TRACEPARENT", "00-x"}]))

      for canary <- ctx.canaries, do: assert(Map.fetch!(env, ~c"#{canary}") == false)
      assert env[~c"SDR_TRACEPARENT"] == ~c"00-x"
    end
  end

  test "the ClaudeCLI child sees no parent secret, only the allowlist and its witness", ctx do
    dump = Path.join(ctx.dir, "claude-env.json")

    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "env_names", dump]
      )

    witness = %{
      model_invocation_id: Ash.UUIDv7.generate(),
      traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
    }

    request = %{
      id: "child-env",
      operation: "model.complete",
      prompt: "qualify",
      schema: Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}),
      witness: witness
    }

    assert {:ok, _} = ClaudeCLI.complete(request, server: server)
    names = dump |> File.read!() |> JSON.decode!()

    assert_clean(names, ctx.canaries)
    assert "SDR_MODEL_INVOCATION_ID" in names
    assert "SDR_TRACEPARENT" in names
  end

  test "the anchoring Git subprocesses see no parent secret", ctx do
    dump = Path.join(ctx.dir, "git-env")
    bin = Path.join(ctx.dir, "bin")
    File.mkdir_p!(bin)
    fake_tool!(bin, "git", dump, 1)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    assert {:error, _} =
             GitSink.publish("{}",
               repository: "git@github.com:chops/sdr_agent-audit-anchors.git",
               anchor_number: 1
             )

    assert_clean(names(dump), ctx.canaries)
  end

  test "the OpenTimestamps tool wrapper sees no parent secret", ctx do
    dump = Path.join(ctx.dir, "ots-env")
    wrapper = fake_tool!(ctx.dir, "with-audit-tools", dump, 1)
    hash = :crypto.hash(:sha256, "child-env")

    proof =
      <<0, "OpenTimestamps", 0, 0, "Proof", 0, 0xBF, 0x89, 0xE2, 0xE8, 0x84, 0xE8, 0x92, 0x94, 1,
        8>> <> hash

    assert {:error, _} = OpenTimestampsSink.Calendar.verify(proof, hash, wrapper: wrapper)
    assert_clean(names(dump), ctx.canaries)
    assert "TZ" in names(dump)
  end

  test "ClaudeCLI's process-tree cleanup children (pgrep, kill) see no parent secret", ctx do
    dump = Path.join(ctx.dir, "cleanup-env")
    bin = Path.join(ctx.dir, "bin")
    File.mkdir_p!(bin)
    fake_tool!(bin, "pgrep", dump, 1)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "malformed"]
      )

    request = %{
      id: "child-env-cleanup",
      operation: "model.complete",
      prompt: "qualify",
      schema: Zoi.object(%{answer: Zoi.string()}),
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
      }
    }

    assert {:error, :invalid_cli_stream} = ClaudeCLI.complete(request, server: server)
    assert_clean(names(dump), ctx.canaries)
  end

  test "the witness store's uid probe sees no parent secret", ctx do
    dump = Path.join(ctx.dir, "id-env")
    bin = Path.join(ctx.dir, "bin")
    File.mkdir_p!(bin)
    tool = "sdr-fake-id-#{ctx.suffix}"

    File.write!(Path.join(bin, tool), """
    #!/bin/sh
    env | cut -d= -f1 >> '#{dump}'
    echo 4242
    """)

    File.chmod!(Path.join(bin, tool), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    assert Store.effective_uid(tool) == 4242
    assert_clean(names(dump), ctx.canaries)
  end

  test "provenance's git sees no parent secret", ctx do
    dump = Path.join(ctx.dir, "provenance-env")
    bin = Path.join(ctx.dir, "bin")
    File.mkdir_p!(bin)
    fake_tool!(bin, "git", dump, 1)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    assert %{git_sha: "unknown"} = Provenance.collect()
    assert_clean(names(dump), ctx.canaries)
  end
end
