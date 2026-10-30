defmodule SdrAgent.Prototype.ClusterRuntimeTest do
  @moduledoc """
  D-268 M1 marker refusals through the real filesystem identity reader.

  Each test owns one exclusive directory under the existing private handoff
  root. The subject may run the fixed `/usr/bin/id -u`; no test invokes
  initdb, pg_controldata, pg_ctl, a server, a model or an owner marker. These
  refusals precede the control-file command. The real happy-cluster proof
  remains a separately bounded provisioning run, not a fake command seam.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Prototype.Cluster

  @scratch_base "/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp"

  setup do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(@scratch_base, "d268-m1-cluster-test-" <> nonce)
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)

    on_exit(fn -> File.rm_rf!(root) end)

    paths = %{
      root: root,
      socket_dir: Path.join(root, "socket"),
      port: 5541,
      pg_bin: Cluster.pinned().pg_bin
    }

    %{root: root, marker: Path.join(root, "CLUSTER"), paths: paths}
  end

  test "a real owned root without its marker refuses before control-file work", ctx do
    assert Cluster.check(ctx.paths) == {:error, :marker_missing}
    refute File.exists?(ctx.marker)
  end

  test "a wide-mode marker refuses without changing its bytes or mode", ctx do
    bytes = "not a marker\n"
    File.write!(ctx.marker, bytes)
    File.chmod!(ctx.marker, 0o644)

    assert Cluster.check(ctx.paths) == {:error, :marker_not_owned}
    assert File.read!(ctx.marker) == bytes
    assert Bitwise.band(File.stat!(ctx.marker).mode, 0o7777) == 0o644
  end

  test "a symlink marker is refused without following or replacing it", ctx do
    target = Path.join(ctx.root, "synthetic-target")
    bytes = "synthetic target remains unchanged\n"
    File.write!(target, bytes)
    File.chmod!(target, 0o600)
    File.ln_s!(target, ctx.marker)

    assert Cluster.check(ctx.paths) == {:error, :marker_not_owned}
    assert File.lstat!(ctx.marker).type == :symlink
    assert File.read!(target) == bytes
  end

  test "an oversized regular marker gives the bounded marker refusal", ctx do
    File.write!(ctx.marker, String.duplicate("x", 4097))
    File.chmod!(ctx.marker, 0o600)

    assert Cluster.check(ctx.paths) == {:error, :marker_invalid}
    assert File.stat!(ctx.marker).size == 4097
  end
end
