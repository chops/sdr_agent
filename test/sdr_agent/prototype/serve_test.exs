defmodule SdrAgent.Prototype.ServeTest do
  @moduledoc """
  `mix sdr.prototype.serve` (interfaces r6 IF-2 "Process kinds", serve
  row; plan r7 section 3): the endpoint on 4120 only if `lsof` shows the
  port free, never stopping or signalling another listener; the provider
  must already be the configured `claude_cli` (never switched or defaulted
  here); the queues stay on.
  """
  use ExUnit.Case, async: true

  @serve Mix.Tasks.Sdr.Prototype.Serve
  @source "lib/mix/tasks/sdr.prototype.serve.ex"
  @claude_cli SdrAgent.AI.ModelProvider.ClaudeCLI
  @busy "COMMAND PID USER FD TYPE\nbeam.smp 1 x 20u IPv4 TCP 127.0.0.1:4120 (LISTEN)\n"

  defp preflight(opts),
    do: @serve.preflight(Keyword.merge([provider: @claude_cli, listeners: fn -> "" end], opts))

  test "a listener on 4120 refuses the start; a free port passes" do
    assert preflight(listeners: fn -> @busy end) == {:error, :port_busy}
    assert preflight([]) == :ok
  end

  test "an unreadable listener listing refuses (unknown is not free)" do
    assert preflight(listeners: fn -> :error end) == {:error, :port_unknown}
  end

  test "a provider other than the configured claude_cli refuses" do
    assert preflight(provider: SdrAgent.AI.ModelProvider.Fake) ==
             {:error, :provider_not_claude_cli}

    assert preflight(provider: nil) == {:error, :provider_not_claude_cli}
  end

  test "the overrides serve the endpoint on 4120 and never disable the queues" do
    overrides = @serve.overrides()
    assert is_list(overrides), "no overrides: #{inspect(overrides)}"
    endpoint = Keyword.fetch!(overrides, SdrAgentWeb.Endpoint)
    assert Keyword.fetch!(endpoint, :server) == true
    assert get_in(endpoint, [:http, :port]) == 4120
    refute Keyword.has_key?(overrides, Oban)
    refute Keyword.has_key?(overrides, :model_provider)
  end

  # The executable code only: @moduledoc, @doc and @shortdoc strings are
  # dropped, so prose can never satisfy or fail a code check (Codex S4
  # bounded review: a moduledoc match is not evidence).
  defp code_ast do
    {:ok, ast} = @source |> File.read!() |> Code.string_to_quoted()

    Macro.prewalk(ast, fn
      {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :shortdoc] -> nil
      node -> node
    end)
  end

  test "source check: the executable code never stops, kills or signals a process" do
    code = Macro.to_string(code_ast())

    for forbidden <- ["kill", "pkill", "System.stop", ":init.stop", "Process.exit", "pg_ctl"] do
      refute code =~ forbidden, "#{@source} code contains #{forbidden}"
    end
  end

  test "the real entry probes lsof -nP -iTCP:4120 -sTCP:LISTEN with a ChildEnv environment" do
    {_ast, found} =
      Macro.prewalk(code_ast(), false, fn
        {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, [_command, args, opts]} = node, acc ->
          probe? =
            args == ["-nP", "-iTCP:4120", "-sTCP:LISTEN"] and
              Macro.to_string(opts) =~ "ChildEnv"

          {node, acc or probe?}

        node, acc ->
          {node, acc}
      end)

    assert found,
           "#{@source}: no executable System.cmd(lsof, [\"-nP\", \"-iTCP:4120\", " <>
             "\"-sTCP:LISTEN\"], env: ChildEnv...) (the real entry is not implemented yet)"
  end
end
