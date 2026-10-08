defmodule SdrAgent.Agents.Witness.EnablementTest do
  @moduledoc """
  S12d enablement (plan R3/P5; ADR-0005, proof 3 and Codex evidence PASS
  c9a2bba3). The shipped (dev/prod) runtime allowlist holds exactly one
  exact entry: (claude_cli, 2.1.291, claude-message-json/3+prompt-builder/1,
  propagated_id). Any other tuple stays inferred. The test environment keeps
  an empty allowlist so that hermetic fixtures stay inferred by default. The
  end-to-end "exactly this tuple reconciles" check is in `ReconcilerTest` (R3).

  The reconciliation queue stays at concurrency 1. The witness store stays
  unconfigured by default. It is opt-in through `SDR_WITNESS_STORE_ROOT`
  (non-test environments), and it is validated on every use: the path must
  be absolute, have no dot segments, have no symlink component, and end in
  a directory. Otherwise reconciliation stays inert.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Store

  @entry %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }
  @env "SDR_WITNESS_STORE_ROOT"

  setup do
    previous =
      Map.new(
        [@env, "DATABASE_URL", "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET"],
        &{&1, System.get_env(&1)}
      )

    config = Application.get_env(:sdr_agent, Witness)

    root = Path.join(System.tmp_dir!(), "sdr-enable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "store"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      Application.put_env(:sdr_agent, Witness, config)
      File.rm_rf!(root)
    end)

    # realpath of the temp dir (macOS /var -> /private/var is a symlink).
    %{root: real(root)}
  end

  defp shipped(env), do: Config.Reader.read!("config/config.exs", env: env, target: :host)

  defp witness(config), do: config |> Keyword.get(:sdr_agent, []) |> Keyword.get(Witness, [])

  defp runtime(env), do: Config.Reader.read!("config/runtime.exs", env: env, target: :host)

  describe "shipped allowlist (R3)" do
    test "dev and prod ship exactly the one exact v3 entry, without test overrides" do
      for env <- [:dev, :prod] do
        config = witness(shipped(env))
        assert Keyword.get(config, :reconciled_methods) == [@entry], inspect(env)
        assert Keyword.get(config, :store_root) == nil, inspect(env)
        refute Keyword.get(config, :allow_method_override, false), inspect(env)
      end
    end

    test "the test environment keeps an empty allowlist (hermetic default)" do
      assert Keyword.get(Application.get_env(:sdr_agent, Witness, []), :reconciled_methods) == []
    end

    test "the reconciliation queue stays at concurrency 1" do
      for env <- [:dev, :prod] do
        queues =
          shipped(env)
          |> Keyword.fetch!(:sdr_agent)
          |> Keyword.fetch!(Oban)
          |> Keyword.fetch!(:queues)

        assert Keyword.fetch!(queues, :reconciliation) == 1, inspect(env)
      end
    end
  end

  describe "store root (opt-in, validated on use)" do
    test "SDR_WITNESS_STORE_ROOT configures dev; test stays unconfigured; unset is absent", ctx do
      store = Path.join(ctx.root, "store")
      System.put_env(@env, store)
      assert witness(runtime(:dev))[:store_root] == store
      assert witness(runtime(:test))[:store_root] == nil

      System.delete_env(@env)
      assert witness(runtime(:dev))[:store_root] == nil
    end

    test "only an absolute, symlink-free directory path is accepted", ctx do
      store = Path.join(ctx.root, "store")
      file = Path.join(ctx.root, "file")
      File.write!(file, "")
      link = Path.join(ctx.root, "link")
      File.ln_s!(store, link)
      File.mkdir_p!(Path.join(store, "sub"))

      assert call(:validate_root, [store], Store) == {:ok, store}

      for {label, path} <- [
            {"relative", "tmp/store"},
            {"dot segment", Path.join(store, "./sub")},
            {"dot-dot segment", Path.join(store, "sub/..")},
            {"symlink leaf", link},
            {"symlink component", Path.join(link, "sub")},
            {"regular file", file},
            {"missing", Path.join(ctx.root, "missing")},
            {"empty", ""},
            {"not a string", nil}
          ] do
        assert match?({:error, _}, call(:validate_root, [path], Store)), label
      end
    end

    test "an invalid configured root leaves reconciliation inert (nil)", ctx do
      store = Path.join(ctx.root, "store")
      link = Path.join(ctx.root, "link")
      File.ln_s!(store, link)

      for {path, expected} <- [{store, store}, {link, nil}, {"relative/path", nil}, {nil, nil}] do
        Application.put_env(
          :sdr_agent,
          Witness,
          Keyword.put(Application.get_env(:sdr_agent, Witness), :store_root, path)
        )

        assert Witness.store_root() == expected, inspect(path)
      end
    end
  end

  ## Helpers

  # A missing enablement interface fails the scenario's own assertion (RED).
  defp call(function, args, module) do
    Code.ensure_loaded(module)

    if function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: {:error, {:not_implemented, function}}
  end

  defp real(path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn
      "/", acc ->
        acc

      part, acc ->
        next = Path.join(acc, part)

        case File.read_link(next) do
          {:ok, target} -> Path.expand(target, acc) |> real()
          {:error, _} -> next
        end
    end)
  end
end
