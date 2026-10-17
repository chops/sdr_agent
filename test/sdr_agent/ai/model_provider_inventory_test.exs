defmodule SdrAgent.AI.ModelProviderInventoryTest do
  @moduledoc """
  R0-04-5 (`docs/product/r0/r0-04-seam.md`): every `prepare/2` and
  `complete/2` call on a model provider in `lib/` goes through the
  `ModelProvider` facade, apart from three exceptions named exactly.
  Characterization of main; its sensitivity was shown with temporary
  local edits, which were then reverted.

  **It flags:**
  - a remote call with two arguments on a module that implements
    `SdrAgent.AI.ModelProvider`. The module may be fully qualified or
    aliased: a plain `alias`, `alias ..., as:`, or a grouped
    `alias A.{B, C}`, each scoped to the module or function body it is
    written in;
  - a remote call on a dynamic receiver (`var.prepare(_, _)` or
    `var.complete(_, _)`);
  - a capture (`&Mod.prepare/2`, `&Mod.complete/2`);
  - `apply/3` or `Kernel.apply/3` with a literal `:prepare` or
    `:complete` and two arguments, or an argument list computed at
    runtime.

  **Its limits:** a function name computed at runtime is not seen. A
  provider module's own internals are exempt only for calls to its own
  module.
  """
  use ExUnit.Case, async: true

  @behaviour_module SdrAgent.AI.ModelProvider
  @names [:prepare, :complete]
  @root Path.expand("../../../lib", __DIR__)

  # {caller module, caller function, receiver, called function}
  @exceptions MapSet.new([
                {SdrAgent.AI.ModelProvider, :prepare, :dynamic, :prepare},
                {SdrAgent.AI.ModelProvider, :provider_call, :dynamic, :complete},
                {SdrAgent.AI.ModelProvider.CalibrationCall, :target,
                 SdrAgent.AI.ModelProvider.ClaudeCLI, :prepare},
                {SdrAgent.AI.ModelProvider.Runtime, :prepared, :dynamic, :prepare}
              ])

  test "every provider prepare/complete call goes through the facade or a named exception" do
    calls = inventory(@root)
    unexpected = Enum.reject(calls, &MapSet.member?(@exceptions, Map.fetch!(&1, :key)))

    assert unexpected == [],
           "provider calls outside the facade:\n" <>
             Enum.map_join(unexpected, "\n", &"  #{&1.file}:#{&1.line} #{inspect(&1.key)}")

    found = MapSet.new(calls, & &1.key)

    for exception <- @exceptions do
      assert exception in found, "named exception not found any more: #{inspect(exception)}"
    end
  end

  test "each enforced form is detected (synthetic sources, no lib edits)" do
    sources = %{
      "direct" => """
      defmodule Probe.Direct do
        alias SdrAgent.AI.ModelProvider.ClaudeCLI
        def go(r), do: ClaudeCLI.complete(r, [])
      end
      """,
      "qualified" => """
      defmodule Probe.Qualified do
        def go(r), do: SdrAgent.AI.ModelProvider.Fake.prepare(r, [])
      end
      """,
      "dynamic" => """
      defmodule Probe.Dynamic do
        def go(mod, r), do: mod.complete(r, [])
      end
      """,
      "grouped_alias" => """
      defmodule Probe.Grouped do
        alias SdrAgent.AI.ModelProvider.{ClaudeCLI, Fake}
        def go(r), do: ClaudeCLI.complete(r, [])
      end
      """,
      "function_scoped_alias" => """
      defmodule Probe.FunctionScoped do
        def go(r) do
          alias SdrAgent.AI.ModelProvider.Fake
          Fake.prepare(r, [])
        end
      end
      """,
      "capture" => """
      defmodule Probe.Capture do
        def go, do: &SdrAgent.AI.ModelProvider.Fake.complete/2
      end
      """,
      "apply" => """
      defmodule Probe.Apply do
        def go(m, r), do: apply(m, :prepare, [r, []])
      end
      """,
      "kernel_apply" => """
      defmodule Probe.KernelApply do
        def go(m, r), do: Kernel.apply(m, :complete, [r, []])
      end
      """
    }

    for {name, source} <- sources do
      assert [_] = scan(source, name), "#{name} was not detected"
    end

    other = """
    defmodule Probe.Other do
      def go(changeset), do: Map.get(changeset, :complete) || Task.yield(changeset, 1)
    end
    """

    assert scan(other, "other") == []

    # An alias made inside one function does not reach the next one: there
    # `Fake` is the unaliased module `Fake`, not a provider.
    scoped = """
    defmodule Probe.Scope do
      def a(r) do
        alias SdrAgent.AI.ModelProvider.Fake
        Fake.prepare(r, [])
      end

      def b(r), do: Fake.prepare(r, [])
    end
    """

    assert [%{key: {Probe.Scope, :a, SdrAgent.AI.ModelProvider.Fake, :prepare}}] =
             scan(scoped, "scope")
  end

  ## Inventory

  defp inventory(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path -> scan(File.read!(path), Path.relative_to(path, root)) end)
  end

  defp scan(source, file) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    {_ast, acc} = Macro.traverse(ast, %{stack: [], aliases: %{}, calls: []}, &pre/2, &post/2)
    Enum.map(acc.calls, &Map.put(&1, :file, file))
  end

  # Each module and function body opens a lexical scope: aliases made in
  # it are dropped when it ends (the alias map is saved on the stack).
  defp pre({:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc) do
    module = Module.concat(parts)
    {node, %{acc | stack: [{:module, module, acc.aliases} | acc.stack]}}
  end

  defp pre({kind, _, [{name, _, _} | _]} = node, acc)
       when kind in [:def, :defp] and is_atom(name) do
    {node, %{acc | stack: [{:function, name, acc.aliases} | acc.stack]}}
  end

  # Grouped alias: `alias A.B.{C, D.E}` aliases `C` and `E`.
  defp pre({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]} = node, acc) do
    aliases =
      Enum.reduce(children, acc.aliases, fn
        {:__aliases__, _, parts}, aliases ->
          Map.put(aliases, List.last(parts), Module.concat(base ++ parts))

        _other, aliases ->
          aliases
      end)

    {node, %{acc | aliases: aliases}}
  end

  defp pre({:alias, _, [{:__aliases__, _, parts} | rest]} = node, acc) do
    target = Module.concat(parts)

    as =
      case rest do
        [[as: {:__aliases__, _, [as]}]] -> as
        _ -> List.last(parts)
      end

    {node, %{acc | aliases: Map.put(acc.aliases, as, target)}}
  end

  defp pre({{:., _, [receiver, name]}, meta, args} = node, acc)
       when name in @names and is_list(args) and length(args) == 2 do
    {node, record(acc, receiver(receiver, acc), name, meta)}
  end

  defp pre({:&, meta, [{:/, _, [{{:., _, [receiver, name]}, _, []}, 2]}]} = node, acc)
       when name in @names do
    {node, record(acc, receiver(receiver, acc), name, meta)}
  end

  defp pre({:apply, meta, [_m, name, args]} = node, acc) when name in @names do
    {node, if(two_args?(args), do: record(acc, :dynamic, name, meta), else: acc)}
  end

  defp pre({{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, meta, [_m, name, args]} = node, acc)
       when name in @names do
    {node, if(two_args?(args), do: record(acc, :dynamic, name, meta), else: acc)}
  end

  defp pre(node, acc), do: {node, acc}

  # A literal argument list must have two elements; a computed one is
  # flagged, since its arity can't be seen.
  defp two_args?(args) when is_list(args), do: length(args) == 2
  defp two_args?(_computed), do: true

  defp post({:defmodule, _, _} = node, acc), do: {node, pop(acc, :module)}

  defp post({kind, _, [{name, _, _} | _]} = node, acc)
       when kind in [:def, :defp] and is_atom(name),
       do: {node, pop(acc, :function)}

  defp post(node, acc), do: {node, acc}

  defp pop(%{stack: [{kind, _, aliases} | rest]} = acc, kind),
    do: %{acc | stack: rest, aliases: aliases}

  defp pop(acc, _kind), do: acc

  defp current(acc, kind) do
    Enum.find_value(acc.stack, fn
      {^kind, value, _aliases} -> value
      _ -> nil
    end)
  end

  defp receiver({:__aliases__, _, [first | rest]}, acc) do
    case Map.fetch(acc.aliases, first) do
      {:ok, target} -> Module.concat([target | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp receiver({:__MODULE__, _, _}, acc), do: current(acc, :module)
  defp receiver(atom, _acc) when is_atom(atom), do: atom
  defp receiver(_other, _acc), do: :dynamic

  # A known module is flagged only if it implements the behaviour; a
  # dynamic receiver is always flagged. A provider calling its own module
  # is exempt.
  defp record(acc, receiver, name, meta) do
    module = current(acc, :module)

    cond do
      receiver == :dynamic -> add(acc, receiver, name, meta)
      receiver == module -> acc
      provider?(receiver) -> add(acc, receiver, name, meta)
      true -> acc
    end
  end

  defp add(acc, receiver, name, meta) do
    call = %{
      key: {current(acc, :module), current(acc, :function), receiver, name},
      line: meta[:line]
    }

    %{acc | calls: [call | acc.calls]}
  end

  defp provider?(module) do
    Code.ensure_loaded?(module) and
      @behaviour_module in List.flatten(
        Keyword.get_values(module.module_info(:attributes), :behaviour)
      )
  end
end
