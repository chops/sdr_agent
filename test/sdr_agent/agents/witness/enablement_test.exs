defmodule SdrAgent.Agents.Witness.EnablementTest do
  @moduledoc """
  S12d enablement (plan R3/P5; ADR-0005, proof 3 and Codex evidence PASS
  c9a2bba3). The shipped (dev/prod) runtime allowlist holds exactly one
  exact entry: (claude_cli, 2.1.291, claude-message-json/3+prompt-builder/1,
  propagated_id). Any other tuple stays inferred. The test environment keeps
  an empty allowlist so that hermetic fixtures stay inferred by default. The
  end-to-end "exactly this tuple reconciles" check is in `ReconcilerTest` (R3).

  The reconciliation queue stays at concurrency 1. The witness store stays
  unconfigured by default (unset means inert: skipped). It is opt-in through
  `SDR_WITNESS_STORE_ROOT` in non-test environments. An explicitly
  configured invalid root refuses boot, with a fixed message.

  Every store read revalidates the root, including explicit overrides. The
  root must be absolute and syntactically clean, every ancestor must be a
  non-symlink directory owned by root or the effective UID and not group-
  or world-writable, and the root itself must be owned by the effective
  UID. A failure is a typed unreadable store, never "unconfigured".
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.Test.WitnessRoot

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

    root = WitnessRoot.mkdir!("enable")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      Application.put_env(:sdr_agent, Witness, config)
      File.rm_rf!(root)
    end)

    %{root: root}
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

  describe "store root (opt-in; boot refusal; validated on use)" do
    test "SDR_WITNESS_STORE_ROOT configures non-test envs verbatim; test and unset stay nil",
         ctx do
      System.put_env(@env, ctx.root)
      assert witness(runtime(:dev))[:store_root] == ctx.root
      assert witness(runtime(:test))[:store_root] == nil

      System.delete_env(@env)
      assert witness(runtime(:dev))[:store_root] == nil
    end

    test "validate_root/2: only an absolute, trusted, symlink-free directory", ctx do
      uid = call(:effective_uid, [], Store)
      assert is_integer(uid)
      assert call(:validate_root, [ctx.root, uid], Store) == {:ok, ctx.root}

      file = Path.join(ctx.root, "file")
      File.write!(file, "")
      sub = Path.join(ctx.root, "sub")
      File.mkdir!(sub)
      File.chmod!(sub, 0o700)
      link = Path.join(ctx.root, "link")
      File.ln_s!(sub, link)
      File.mkdir!(Path.join(sub, "inner"))
      File.chmod!(Path.join(sub, "inner"), 0o700)

      group_writable = Path.join(ctx.root, "gw")
      File.mkdir!(group_writable)
      File.chmod!(group_writable, 0o770)

      open_parent = Path.join(ctx.root, "open")
      File.mkdir!(open_parent)
      File.chmod!(open_parent, 0o777)
      under_open = Path.join(open_parent, "store")
      File.mkdir!(under_open)
      File.chmod!(under_open, 0o700)

      for {label, path, expected_uid} <- [
            {"relative", "tmp/witness-roots", uid},
            {"dot segment", ctx.root <> "/./sub", uid},
            {"dot-dot segment", ctx.root <> "/sub/..", uid},
            {"empty segment", ctx.root <> "//sub", uid},
            {"trailing slash", sub <> "/", uid},
            {"NUL", ctx.root <> <<0>>, uid},
            {"URL", "file://" <> ctx.root, uid},
            {"symlink leaf", link, uid},
            {"symlink ancestor", Path.join(link, "inner"), uid},
            {"regular file", file, uid},
            {"missing", Path.join(ctx.root, "missing"), uid},
            {"group-writable root", group_writable, uid},
            {"world-writable ancestor", under_open, uid},
            {"wrong owner", sub, uid + 1},
            {"empty", "", uid},
            {"not a string", nil, uid}
          ] do
        result = call(:validate_root, [path, expected_uid], Store)
        assert match?({:error, _}, result), "#{label}: #{inspect(result)}"
      end

      assert call(:validate_root, [sub, uid], Store) == {:ok, sub}
    end

    test "an explicitly configured invalid root refuses boot without naming it", ctx do
      link = Path.join(ctx.root, "link")
      File.ln_s!(ctx.root, link)

      for {root, outcome} <- [
            {nil, :ok},
            {ctx.root, :ok},
            {link, :raise},
            {"relative", :raise},
            {Path.join(ctx.root, "missing"), :raise}
          ] do
        put_witness(store_root: root)

        case outcome do
          :ok ->
            assert call(:check_configured_root!, [], Witness) == :ok, inspect(root)

          :raise ->
            result =
              try do
                call(:check_configured_root!, [], Witness)
              rescue
                error -> {:raised, Exception.message(error)}
              end

            assert match?({:raised, _}, result), inspect(result)
            {:raised, message} = result
            refute message =~ to_string(root)
        end
      end
    end

    test "store reads validate the root, including explicit overrides", ctx do
      link = Path.join(ctx.root, "link")
      File.ln_s!(ctx.root, link)
      invocation = Ash.UUIDv7.generate()

      for {label, root} <- [{"symlinked root", link}, {"relative root", "tmp/witness-roots"}] do
        for {fun, args} <- [
              {:inventory, [root, invocation]},
              {:fingerprint, [root, invocation]},
              {:blob, [root, String.duplicate("a", 64)]},
              {:blob_identity, [root, String.duplicate("a", 64)]}
            ] do
          result = apply(Store, fun, args)

          assert result in [{:error, :store_root_untrusted}, {:error, :store_root_missing}],
                 "#{label} #{fun}: #{inspect(result)}"
        end
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

  defp put_witness(overrides) do
    Application.put_env(
      :sdr_agent,
      Witness,
      Keyword.merge(Application.get_env(:sdr_agent, Witness, []), overrides)
    )
  end
end
