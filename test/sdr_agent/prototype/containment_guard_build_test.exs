defmodule SdrAgent.Prototype.ContainmentGuardBuildTest do
  @moduledoc """
  The prod- and dev-absence proof of the guard test protocol (D-237 S4
  K0/guard RED packet r1, section 3.4). It follows
  `prod_artifact_proof_test.exs`: `:external`, owned fresh build paths,
  compiled artifacts compared with this (test) build.

  - the test build holds `SdrAgent.Prototype.ContainmentGuard` and its
    `TestSeam` (positive control);
  - the dev build (prototype authority, no test seams) holds the guard but
    no `TestSeam` beam, and no dev beam names the `TestSeam` atom (so no dev
    guard path can reach the seam, even by apply);
  - the prod build holds neither module and no prod beam names either;
  - `prototype_test_seams: true` is set only in `config/test.exs`.

  At RED the prod and absence assertions hold vacuously (no guard exists
  anywhere); they become meaningful only once GREEN adds the module.
  """
  use ExUnit.Case, async: false

  @moduletag :external
  @moduletag timeout: 1_800_000

  @guard "Elixir.SdrAgent.Prototype.ContainmentGuard"
  @seam "Elixir.SdrAgent.Prototype.ContainmentGuard.TestSeam"

  setup_all do
    %{prod: build!("d237-guard-prod", "prod"), dev: build!("d237-guard-dev", "dev")}
  end

  # Compiles `env` into an owned, exclusively created build path.
  defp build!(prefix, env) do
    build = SdrAgent.PrototypeOutreachFixtures.exclusive_root!(prefix)
    cmd_env = [{"MIX_ENV", env}, {"MIX_BUILD_PATH", build}]
    opts = [env: cmd_env, stderr_to_stdout: true]
    {deps_out, deps_status} = System.cmd("mix", ["deps.compile"], opts)
    {out, status} = System.cmd("mix", ["compile", "--force"], opts)

    %{
      ebin: Path.join([build, "lib", "sdr_agent", "ebin"]),
      compiled?: deps_status == 0 and status == 0,
      log: String.slice(deps_out <> out, -4000, 4000)
    }
  end

  defp compiled!(build), do: assert(build.compiled?, "the compile failed:\n#{build.log}")

  defp beam_names(ebin),
    do: ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.map(&Path.basename/1)

  # Basenames of beams whose imports or atoms name an atom starting with `prefix`.
  defp naming(ebin, prefix) do
    for path <- Path.wildcard(Path.join(ebin, "*.beam")),
        {:ok, {_mod, [imports: imports, atoms: atoms]}} =
          :beam_lib.chunks(String.to_charlist(path), [:imports, :atoms]),
        names =
          Enum.map(imports, fn {m, _f, _a} -> Atom.to_string(m) end) ++
            Enum.map(atoms, fn {_i, a} -> Atom.to_string(a) end),
        Enum.any?(names, &String.starts_with?(&1, prefix)),
        do: Path.basename(path)
  end

  test "the test build holds the guard and its test seam (positive control)" do
    ebin = :code.lib_dir(:sdr_agent) |> Path.join("ebin")
    names = beam_names(ebin)
    assert (@guard <> ".beam") in names, "the test build has no ContainmentGuard"
    assert (@seam <> ".beam") in names, "the test build has no ContainmentGuard.TestSeam"
  end

  test "the dev build holds the guard but no seam, and no dev beam names the seam", ctx do
    compiled!(ctx.dev)
    names = beam_names(ctx.dev.ebin)
    assert (@guard <> ".beam") in names, "the dev build has no ContainmentGuard"
    refute (@seam <> ".beam") in names, "the dev build holds the test seam"
    assert naming(ctx.dev.ebin, @seam) == [], "a dev beam names the test seam"
  end

  test "the prod build holds neither module and no prod beam names the guard", ctx do
    compiled!(ctx.prod)
    held = Enum.filter(beam_names(ctx.prod.ebin), &String.starts_with?(&1, @guard))
    assert held == [], "prod holds guard modules: #{inspect(held)}"
    assert naming(ctx.prod.ebin, @guard) == [], "a prod beam names the guard"
  end

  test "prototype_test_seams is set only in config/test.exs" do
    setting = ~r/config\s+:sdr_agent,\s*(\n\s*)?prototype_test_seams:\s*true/

    for file <- Path.wildcard("config/*.exs") do
      expected? = Path.basename(file) == "test.exs"
      assert Regex.match?(setting, File.read!(file)) == expected?, "#{file}: seam flag is wrong"
    end
  end
end
