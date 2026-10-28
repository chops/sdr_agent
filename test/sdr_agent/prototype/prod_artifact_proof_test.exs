defmodule SdrAgent.Prototype.ProdArtifactProofTest do
  @moduledoc """
  The D-237 production-artifact proof (amendment item 2 "Development build
  only", item 9 "Activation needs"; interfaces r6 IF-1 "Production build";
  plan r7 section 6 row "Prod no path", `prod_artifact_proof_test.exs`).
  It is required before activation and is never cut.

  `:external`: it compiles the application with `MIX_ENV=prod` into an
  owned, fresh build path (never the shared build), then compares the
  compiled artifacts with this (test) build:

    * the test build holds `Elixir.SdrAgent.Prototype.Authority.beam`
      (the flag is set in `config/test.exs`); the prod build holds no
      `SdrAgent.Prototype.Authority` module at all;
    * no prod beam imports, or even names as an atom, any
      `SdrAgent.Prototype.Authority` module (no activation path by apply);
    * the prod facade, loaded in a separate VM from the prod ebin alone,
      exports refusal stubs only: `runtime/0` is `:ordinary`, `label/0` the
      constant, `operator?/1` false, every other function
      `{:error, :not_prototype_runtime}`;
    * the compile flag is set only in `config/dev.exs` and
      `config/test.exs`.
  """
  use ExUnit.Case, async: false

  @moduletag :external
  @moduletag timeout: 900_000

  @flag "prototype_authority_compiled"
  @authority "Elixir.SdrAgent.Prototype.Authority"

  setup_all do
    # An owned build path, created exclusively; only it is removed on exit.
    build = SdrAgent.PrototypeOutreachFixtures.exclusive_root!("d237-prod-proof")

    env = [{"MIX_ENV", "prod"}, {"MIX_BUILD_PATH", build}]

    {deps_out, deps_status} =
      System.cmd("mix", ["deps.compile"], env: env, stderr_to_stdout: true)

    {out, status} = System.cmd("mix", ["compile", "--force"], env: env, stderr_to_stdout: true)

    %{
      build: build,
      ebin: Path.join([build, "lib", "sdr_agent", "ebin"]),
      compiled?: deps_status == 0 and status == 0,
      compile_log: String.slice(deps_out <> out, -4000, 4000)
    }
  end

  defp compiled!(ctx) do
    assert ctx.compiled?, "the prod compile failed:\n#{ctx.compile_log}"
  end

  defp beams(ebin), do: Path.wildcard(Path.join(ebin, "*.beam"))

  test "the test build compiles the authority; the prod build holds none of it", ctx do
    compiled!(ctx)
    test_ebin = :code.lib_dir(:sdr_agent) |> Path.join("ebin")

    assert File.regular?(Path.join(test_ebin, @authority <> ".beam")),
           "the test build has no #{@authority}"

    prod_authority =
      for path <- beams(ctx.ebin), String.starts_with?(Path.basename(path), @authority), do: path

    assert prod_authority == [], "prod holds authority modules: #{inspect(prod_authority)}"

    assert File.regular?(Path.join(ctx.ebin, "Elixir.SdrAgent.Prototype.beam")),
           "prod has no facade"
  end

  test "no prod beam imports or names an authority module", ctx do
    compiled!(ctx)

    offenders =
      for path <- beams(ctx.ebin),
          {:ok, {_mod, [imports: imports, atoms: atoms]}} =
            :beam_lib.chunks(String.to_charlist(path), [:imports, :atoms]),
          names =
            Enum.map(imports, fn {m, _f, _a} -> Atom.to_string(m) end) ++
              Enum.map(atoms, fn {_i, a} -> Atom.to_string(a) end),
          Enum.any?(names, &String.starts_with?(&1, @authority)),
          do: Path.basename(path)

    assert offenders == [], "prod beams reference the authority: #{inspect(offenders)}"
  end

  test "the prod facade exports refusal stubs only (a separate VM on the prod ebin)", ctx do
    compiled!(ctx)

    script = ~S"""
    m = SdrAgent.Prototype
    {:module, ^m} = Code.ensure_loaded(m)
    results =
      for {f, a} <- m.__info__(:functions), f not in [:__info__, :module_info] do
        args = List.duplicate(Ecto.UUID.generate(), a)
        {{f, a}, apply(m, f, args)}
      end
    IO.write(:erlang.term_to_binary(results) |> Base.encode64())
    """

    deps = Path.wildcard(Path.join([ctx.build, "lib", "*", "ebin"]))
    args = Enum.flat_map(deps, &["-pa", &1]) ++ ["-e", script]
    {out, status} = System.cmd("elixir", args, stderr_to_stdout: false)
    assert status == 0, "the prod facade VM failed"
    results = out |> String.trim() |> Base.decode64!() |> :erlang.binary_to_term() |> Map.new()

    assert results[{:runtime, 0}] == :ordinary
    assert results[{:label, 0}] == "UNVERIFIED (PROTOTYPE)"
    assert results[{:operator?, 1}] == false

    others = Map.drop(results, [{:runtime, 0}, {:label, 0}, {:operator?, 1}])
    assert map_size(others) > 0

    for {fun, result} <- others do
      assert result == {:error, :not_prototype_runtime},
             "prod #{inspect(fun)} returned #{inspect(result)}"
    end
  end

  test "the compile flag is set only in config/dev.exs and config/test.exs" do
    setting = ~r/config\s+:sdr_agent,\s*(\n\s*)?#{@flag}:\s*true/

    for file <- Path.wildcard("config/*.exs") do
      expected? = Path.basename(file) in ["dev.exs", "test.exs"]

      assert Regex.match?(setting, File.read!(file)) == expected?,
             "#{file}: flag setting is wrong"
    end
  end
end
