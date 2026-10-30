defmodule SdrAgent.Prototype.EndpointRepinTest do
  @moduledoc """
  Owner-authorized prototype endpoint repin: fresh namespace on socket5542,
  never the active foreign project's5541 or the retained failed-attempt root.
  Pure configuration/source checks only: no cluster, file-content, socket or
  model operation. Runtime configuration reads restore the two environment keys.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Prototype.Authority
  alias SdrAgent.Prototype.Cluster
  alias SdrAgent.Prototype.Setup

  @root "/Users/charles/.local/state/sdr-agent/prototype/d237-5542"
  @socket "/private/tmp/d237-pg-5542"
  @old_root "/Users/charles/.local/state/sdr-agent/prototype/d237"
  @old_socket "/private/tmp/d237-pg"
  @bin "/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6/bin"
  @target [database: "sdr_agent_prototype", port: 5542, socket_dir: @socket]

  test "the active cluster pins select only the fresh5542 namespace" do
    assert Cluster.pinned() == %{root: @root, socket_dir: @socket, port: 5542, pg_bin: @bin}
  end

  test "maintenance uses postgres on the same5542 socket" do
    assert Authority.maintenance_target() ==
             [database: "postgres", port: 5542, socket_dir: @socket, username: "postgres"]
  end

  test "the exact target admits5542 and rejects every old-port or old-socket combination" do
    assert Authority.check_repo_target(@target) == :ok

    for wrong <- [
          Keyword.put(@target, :port, 5541),
          Keyword.put(@target, :socket_dir, @old_socket),
          @target |> Keyword.put(:port, 5541) |> Keyword.put(:socket_dir, @old_socket)
        ] do
      assert Authority.check_repo_target(wrong) == {:error, :repo_target_mismatch}
    end
  end

  test "setup accepts the new marker data directory and refuses the retained old root" do
    marker = %{system_identifier: 123, data_dir: @root <> "/pgdata"}
    identity = %{database: "postgres", system_identifier: 123, data_directory: marker.data_dir}
    assert Setup.cluster_identity_check(marker, identity) == :ok

    old_marker = %{marker | data_dir: @old_root <> "/pgdata"}
    old_identity = %{identity | data_directory: old_marker.data_dir}
    assert Setup.cluster_identity_check(old_marker, old_identity) == {:error, :unexpected}
  end

  test "runtime dev configuration selects5542 with no old endpoint fallback" do
    vars = %{
      "SDR_PROTOTYPE" => "d237-prototype/1",
      "SDR_PROTOTYPE_INSTANCE" => "10000000-0000-0000-0000-000000000042"
    }

    previous = Map.new(vars, fn {key, _value} -> {key, System.get_env(key)} end)

    config =
      try do
        Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)
        Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
      after
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end

    repo = get_in(config, [:sdr_agent, SdrAgent.Repo])
    assert Keyword.take(repo, [:database, :port, :socket_dir]) |> Enum.sort() == @target
  end

  test "the existing cluster script pins the same port, root and socket exactly" do
    script = File.read!("bin/prototype-pg")
    assert script =~ "readonly PORT='5542'"
    assert script =~ "readonly ROOT='#{@root}'"
    assert script =~ "readonly SOCKET_DIR='#{@socket}'"
  end
end
