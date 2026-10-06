defmodule SdrAgent.Scripts.WithSecretsTest do
  @moduledoc """
  Hermetic tests for `bin/with-secrets`: a stub `sops` on PATH stands in for
  decryption, so no real secret is read.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/with-secrets", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "with-secrets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "bin"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    sops = Path.join(tmp, "bin/sops")

    File.write!(sops, """
    #!/bin/sh
    echo "$3" >> "#{tmp}/sops-calls"
    printf 'stub-value-for-%s\\n' "$3"
    """)

    File.chmod!(sops, 0o755)
    %{tmp: tmp, env: [{"PATH", Path.join(tmp, "bin") <> ":" <> System.get_env("PATH")}]}
  end

  defp run(args, env), do: System.cmd(@script, args, env: env, stderr_to_stdout: true)

  test "exports only the mapped names into the child", %{env: env, tmp: tmp} do
    child = ~s(printf '%s|%s' "$SDR_AUDIT_ANCHOR_KEY_ID" "${SDR_AUDIT_ANCHOR_PRIVATE_KEY-unset}")

    assert {out, 0} = run(["SDR_AUDIT_ANCHOR_KEY_ID", "--", "sh", "-c", child], env)
    assert out == ~s(stub-value-for-["audit_anchor"]["key_id"]|unset)
    assert File.read!(Path.join(tmp, "sops-calls")) == ~s(["audit_anchor"]["key_id"]\n)
  end

  test "prints nothing of its own on success", %{env: env} do
    assert {"", 0} = run(["SDR_AUDIT_ANCHOR_PRIVATE_KEY", "--", "true"], env)
  end

  test "rejects unmapped names before decrypting anything", %{env: env, tmp: tmp} do
    assert {out, 2} = run(["HOME_SECRET", "--", "true"], env)
    assert out =~ "unknown secret name"
    refute File.exists?(Path.join(tmp, "sops-calls"))
  end

  test "requires a separator and a command", %{env: env} do
    assert {out, 2} = run(["SDR_AUDIT_ANCHOR_KEY_ID"], env)
    assert out =~ "usage"
    assert {_, 2} = run(["--", "true"], env)
  end

  test "propagates the child's exit status", %{env: env} do
    assert {_, 7} = run(["SDR_AUDIT_ANCHOR_KEY_ID", "--", "sh", "-c", "exit 7"], env)
  end
end
