defmodule SdrAgent.PostgresLogAuditTest do
  @moduledoc """
  5b (D-178; Codex 5b plan r2 amendment 2), DB-free: the extension and
  loaded-module audit `SdrAgent.Test.PostgresLogAudit.classify/1` over fixed
  inventories. Each source is classified on its own (installed extensions,
  modules loaded in this backend, the three preload settings,
  `dynamic_library_path`, dotted GUC names): a pinned benign identity passes,
  a known logging facility fails, anything else is unknown and fails, and an
  unavailable source fails closed. Required extensions are not required
  loaded modules: an empty loaded-module inventory passes. Scope is one
  backend and one database; the live check is
  `SdrAgent.PostgresLogSettingsTest`.
  """
  use ExUnit.Case, async: true

  @audit SdrAgent.Test.PostgresLogAudit

  @clean %{
    extensions: [{"plpgsql", "1.0"}, {"citext", "1.8"}],
    loaded_modules: [],
    preloads: %{
      "shared_preload_libraries" => "",
      "session_preload_libraries" => "",
      "local_preload_libraries" => ""
    },
    dynamic_library_path: "$libdir",
    dotted_gucs: []
  }

  defp classify(inventory) do
    assert Code.ensure_loaded?(@audit), "5b: #{inspect(@audit)} must exist"
    @audit.classify(inventory)
  end

  defp source(result, key), do: Map.fetch!(result.sources, key)

  test "the project's own inventory passes, every source reported" do
    result = classify(@clean)
    assert result.verdict == :pass

    for key <- [:extensions, :loaded_modules, :preloads, :dynamic_library_path, :dotted_gucs] do
      assert source(result, key) == {:pass, []}, "5b: #{key} must be reported and pass"
    end
  end

  test "an empty extension list beyond plpgsql passes; citext is benign, not required" do
    assert classify(%{@clean | extensions: [{"plpgsql", "1.0"}]}).verdict == :pass
  end

  test "pinned benign loaded modules pass on either platform's file name" do
    for file <- ["citext.so", "citext.dylib"] do
      inv = %{
        @clean
        | loaded_modules: [{"plpgsql", "18.6", "plpgsql.so"}, {"citext", "18.6", file}]
      }

      assert classify(inv).verdict == :pass, "5b: #{file}"
    end
  end

  test "a benign name with another version or file name is unknown" do
    for module <- [
          {"citext", "17.2", "citext.so"},
          {"citext", "18.6", "citext_shim.so"},
          {"citext", "18.6", "/opt/evil/citext.so"}
        ] do
      result = classify(%{@clean | loaded_modules: [module]})
      assert result.verdict == :fail
      assert {:fail, [{^module, :unknown}]} = source(result, :loaded_modules)
    end
  end

  test "a module whose name differs from its file's stem fails (calibrated: auto_explain loaded as citext.dylib)" do
    renamed = {"auto_explain", "18.6", "citext.dylib"}
    result = classify(%{@clean | loaded_modules: [renamed]})
    assert {:fail, [{^renamed, :logging}]} = source(result, :loaded_modules)

    odd = {"citext", "18.6", "plpgsql.dylib"}

    assert {:fail, [{^odd, :unknown}]} =
             source(classify(%{@clean | loaded_modules: [odd]}), :loaded_modules)
  end

  test "known logging facilities fail as :logging in each source" do
    for name <- ~w(auto_explain pgaudit pg_stat_statements log_fdw passwordcheck pg_stat_monitor) do
      ext = classify(%{@clean | extensions: @clean.extensions ++ [{name, "1.0"}]})
      assert {:fail, [{{^name, "1.0"}, :logging}]} = source(ext, :extensions)

      mod = {name, "18.6", name <> ".so"}
      loaded = classify(%{@clean | loaded_modules: [mod]})
      assert {:fail, [{^mod, :logging}]} = source(loaded, :loaded_modules)

      pre =
        classify(%{@clean | preloads: %{@clean.preloads | "shared_preload_libraries" => name}})

      assert {:fail, [{{"shared_preload_libraries", ^name}, :logging}]} = source(pre, :preloads)
    end
  end

  test "an unknown extension, module, preload or dotted GUC fails as :unknown" do
    ext = classify(%{@clean | extensions: @clean.extensions ++ [{"pg_trgm", "1.6"}]})
    assert {:fail, [{{"pg_trgm", "1.6"}, :unknown}]} = source(ext, :extensions)

    version = classify(%{@clean | extensions: [{"plpgsql", "1.0"}, {"citext", "1.7"}]})
    assert {:fail, [{{"citext", "1.7"}, :unknown}]} = source(version, :extensions)

    pre = classify(%{@clean | preloads: %{@clean.preloads | "session_preload_libraries" => "x"}})
    assert {:fail, [{{"session_preload_libraries", "x"}, :unknown}]} = source(pre, :preloads)

    guc = classify(%{@clean | dotted_gucs: ["myext.setting"]})
    assert {:fail, [{"myext.setting", :unknown}]} = source(guc, :dotted_gucs)

    logging_guc = classify(%{@clean | dotted_gucs: ["auto_explain.log_min_duration"]})

    assert {:fail, [{"auto_explain.log_min_duration", :logging}]} =
             source(logging_guc, :dotted_gucs)
  end

  test "a dynamic_library_path other than $libdir fails" do
    result = classify(%{@clean | dynamic_library_path: "$libdir:/opt/extra"})
    assert {:fail, [{"$libdir:/opt/extra", :unknown}]} = source(result, :dynamic_library_path)
  end

  test "an unavailable source fails closed; the others are still reported" do
    for key <- [:extensions, :loaded_modules, :preloads, :dynamic_library_path, :dotted_gucs] do
      result = classify(Map.put(@clean, key, :unavailable))
      assert result.verdict == :fail
      assert source(result, key) == {:fail, [:unavailable]}

      for other <- Map.keys(@clean) -- [key] do
        assert source(result, other) == {:pass, []}
      end
    end
  end

  test "a missing source key fails closed" do
    result = classify(Map.delete(@clean, :dotted_gucs))
    assert result.verdict == :fail
    assert source(result, :dotted_gucs) == {:fail, [:unavailable]}
  end
end
