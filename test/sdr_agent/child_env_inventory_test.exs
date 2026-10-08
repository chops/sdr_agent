defmodule SdrAgent.ChildEnvInventoryTest do
  @moduledoc """
  Security inventory: every external process launch in the application
  source (`lib/`) takes its environment from `SdrAgent.ChildEnv`. The AST
  of each file is walked:

    * every `System.cmd/3` call outside `SdrAgent.ChildEnv` passes a literal
      `env:` option whose expression calls `ChildEnv`;
    * every `Port.open/2` call passes a literal `{:env, expr}` option whose
      expression calls `ChildEnv`;
    * `System.cmd` is never captured (`&System.cmd/3`) as a default runner,
      `:os.cmd/1` and `System.shell/1,2` are never used.

  A new launcher that is not wired through `ChildEnv` fails here.
  """
  use ExUnit.Case, async: true

  @exempt "lib/sdr_agent/child_env.ex"

  defp sources, do: "lib/**/*.ex" |> Path.wildcard() |> Enum.reject(&(&1 == @exempt))

  defp findings(path) do
    {_ast, acc} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn node, acc -> {node, check(node, path, acc)} end)

    acc
  end

  defp check(
         {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, meta, [_cmd, _args, opts]},
         path,
         acc
       ),
       do:
         if(env_from_child_env?(opts),
           do: acc,
           else: [{path, meta[:line], "System.cmd without ChildEnv env"} | acc]
         )

  defp check({{:., _, [{:__aliases__, _, [:System]}, :cmd]}, meta, [_cmd, _args]}, path, acc),
    do: [{path, meta[:line], "System.cmd without env"} | acc]

  defp check({{:., _, [{:__aliases__, _, [:Port]}, :open]}, meta, [_spawn, opts]}, path, acc),
    do:
      if(env_from_child_env?(opts),
        do: acc,
        else: [{path, meta[:line], "Port.open without ChildEnv env"} | acc]
      )

  defp check(
         {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, _}, 3]}]},
         path,
         acc
       ),
       do: [{path, meta[:line], "captured System.cmd/3"} | acc]

  defp check({{:., _, [:os, :cmd]}, meta, _args}, path, acc),
    do: [{path, meta[:line], ":os.cmd"} | acc]

  defp check({{:., _, [{:__aliases__, _, [:System]}, :shell]}, meta, _args}, path, acc),
    do: [{path, meta[:line], "System.shell"} | acc]

  defp check(_node, _path, acc), do: acc

  # A literal keyword list / tuple list carrying env: <expr calling ChildEnv>.
  defp env_from_child_env?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {:env, expr} -> calls_child_env?(expr)
      {:{}, _, [:env, expr]} -> calls_child_env?(expr)
      _ -> false
    end)
  end

  defp env_from_child_env?(_opts), do: false

  defp calls_child_env?(expr) do
    {_ast, found} =
      Macro.prewalk(expr, false, fn
        {:__aliases__, _, parts} = node, _found
        when parts in [[:ChildEnv], [:SdrAgent, :ChildEnv]] ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found
  end

  test "every external launch in lib/ takes its environment from ChildEnv" do
    findings = Enum.flat_map(sources(), &findings/1)
    assert findings == [], "launches not wired through SdrAgent.ChildEnv: #{inspect(findings)}"
  end

  test "the inventory recognises the launch forms it guards" do
    bad = ~S"""
    defmodule Bad do
      def a, do: System.cmd("x", [])
      def b, do: System.cmd("x", [], stderr_to_stdout: true)
      def c, do: Port.open({:spawn, "x"}, [:binary])
      def d(opts), do: Keyword.get(opts, :command, &System.cmd/3)
      def e, do: :os.cmd(~c"x")
      def f, do: System.cmd("x", [], env: SdrAgent.ChildEnv.cmd([]))
    end
    """

    path = Path.join(System.tmp_dir!(), "sdr-inventory-#{System.unique_integer([:positive])}.ex")
    File.write!(path, bad)
    on_exit(fn -> File.rm(path) end)

    assert path |> findings() |> Enum.map(&elem(&1, 2)) |> Enum.sort() ==
             Enum.sort([
               "System.cmd without env",
               "System.cmd without ChildEnv env",
               "Port.open without ChildEnv env",
               "captured System.cmd/3",
               ":os.cmd"
             ])
  end
end
