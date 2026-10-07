defmodule SdrAgent.Audit.AuditToolsWrapperTest do
  use ExUnit.Case, async: true

  setup do
    path = Path.join(System.tmp_dir!(), "audit-tools-#{Ecto.UUID.generate()}")
    File.mkdir!(path)
    File.cp!("test/fixtures/audit_tools/fake-nix", Path.join(path, "nix"))
    File.chmod!(Path.join(path, "nix"), 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    %{path: path, wrapper: Path.expand("bin/with-audit-tools")}
  end

  test "wrapper uses the locked input, preserves literal argv, and clears secrets", ctx do
    args = ["ots", "verify", "two words;$()", "quote'and\"double"]

    {output, 0} =
      System.cmd(ctx.wrapper, args,
        stderr_to_stdout: true,
        env: [
          {"PATH", ctx.path <> ":" <> System.fetch_env!("PATH")},
          {"SDR_AUDIT_ANCHOR_PRIVATE_KEY", "test-only-not-a-real-key"},
          {"OPENAI_API_KEY", "test-only-not-a-real-token"},
          {"TOKEN_SIGNING_SECRET", "test-only-not-a-real-secret"}
        ]
      )

    expected = [
      "shell",
      "--no-write-lock-file",
      "--inputs-from",
      File.cwd!(),
      "nixpkgs#opentimestamps-client",
      "--command" | args
    ]

    assert output == Enum.map_join(expected, "", &"<#{&1}>\n")
  end

  test "missing nix fails with a clear error and no credential output", ctx do
    File.rm!(Path.join(ctx.path, "nix"))
    bash = System.find_executable("bash")

    {output, 127} =
      System.cmd(bash, [ctx.wrapper, "ots", "--version"],
        stderr_to_stdout: true,
        env: [{"PATH", ctx.path}]
      )

    assert output =~ "nix is missing"
  end

  test "wrapper refuses an empty command", ctx do
    {output, 64} = System.cmd(ctx.wrapper, [], stderr_to_stdout: true)
    assert output =~ "usage:"
  end
end
