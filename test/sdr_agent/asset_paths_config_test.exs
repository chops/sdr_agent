defmodule SdrAgent.AssetPathsConfigTest do
  @moduledoc """
  Asset builds must find the Mix deps and build outputs where Mix keeps them.
  Under devenv those are `$MIX_DEPS_PATH` / `$MIX_BUILD_ROOT`, not `./deps`
  and `./_build`, so a fresh worktree's `mix tailwind sdr_agent` failed to
  resolve daisyUI (S13). The binaries themselves are not run here: they are
  downloaded on first use, and tests stay hermetic.
  """
  use ExUnit.Case, async: true

  @toolchain_tag ~r/toolchainTag = "([^"]+)";/

  defp asset_env(tool) do
    "config/config.exs"
    |> Config.Reader.read!(env: :dev, target: :host)
    |> get_in([tool, :sdr_agent, :env])
  end

  for tool <- [:tailwind, :esbuild] do
    test "#{tool} resolves packages from the Mix deps and build paths" do
      env = asset_env(unquote(tool))

      assert env["NODE_PATH"] == [Mix.Project.deps_path(), Mix.Project.build_path()]
      assert env["MIX_DEPS_PATH"] == Mix.Project.deps_path()
    end
  end

  test "the heroicons plugin reads icons from the Mix deps path" do
    plugin = File.read!("assets/vendor/heroicons.js")

    assert plugin =~ "process.env.MIX_DEPS_PATH"
  end

  test "devenv source paths in app.css follow devenv.nix's toolchain tag" do
    [_, tag] = Regex.run(@toolchain_tag, File.read!("devenv.nix"))
    css = File.read!("assets/css/app.css")

    assert css =~ ~s(@source "../../.devenv/state/deps/#{tag}/ash_authentication_phoenix";)

    assert css =~
             ~s(@source "../../.devenv/state/build/#{tag}/dev/phoenix-colocated/sdr_agent/*/";)
  end
end
