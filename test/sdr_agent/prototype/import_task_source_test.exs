defmodule SdrAgent.Prototype.ImportTaskSourceTest do
  @moduledoc """
  Source rules of `mix sdr.prototype.import` (`lib/mix/tasks/sdr.prototype.import.ex`;
  interfaces r6 IF-2 "Process kinds" task row, IF-8 "Attached before any
  private input" and the prototype-code source rule; supplement 1 r2 §5
  "Callers"), checked on the parsed source only. Nothing here runs the task
  or reads an input file.

  - `SdrAgent.Prototype.SafeLog.attach/0` is the first statement of `run/1`.
  - The task enters only through S1's common entry
    `SdrAgent.Prototype.Session.enter/1`, exactly once, before any input is
    read, with the correlation from `SDR_PROTOTYPE_SESSION` (the only
    environment read); it boots and starts nothing itself (no
    `BootCheck.verify!/0`, `enter_session/2`, application, Repo, Oban,
    supervisor or migrator start, no `Mix.Task.run/2`).
  - Inputs are read only through the bounded readers
    (`DossierParser.read/2`, `SpotcheckManifest.read/3`), then
    `DossierImport.prepare/5`, `import/2` and `cap_used/1`; no `File` or
    `:file` call.
  - Output is `SafeLog.say/2` with the codes `:import_row` and
    `:import_summary` only; no `IO`, `Logger`, `:io`, `:logger`,
    `Mix.shell` or `SafeLog.event`.
  - `Mix.raise/1` takes a literal string only and `exit/1` a literal
    `{:shutdown, integer}` only: fixed codes, never a value.

  Aliases are resolved (`alias A.B`, `alias A.B, as: C`, `alias A.{B, C}`),
  so a call is matched by its full module.
  """
  use ExUnit.Case, async: true

  @task "lib/mix/tasks/sdr.prototype.import.ex"

  @safe_log SdrAgent.Prototype.SafeLog
  @session SdrAgent.Prototype.Session

  defp ast!, do: @task |> File.read!() |> Code.string_to_quoted!()

  # The module's aliases: short name => full module.
  defp aliases(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn {:__aliases__, _, parts}, acc ->
             Map.put(acc, List.last(parts), Module.concat(base ++ parts))
           end)}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [short]}]]} = node, acc ->
          {node, Map.put(acc, short, Module.concat(parts))}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp resolve({:__aliases__, _, [first | rest]}, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> Module.concat([full | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp resolve(module, _aliases) when is_atom(module), do: module
  defp resolve(_other, _aliases), do: :dynamic

  # Every remote call in source order: {module, function, args, line},
  # under the whole module's aliases.
  defp calls(ast), do: calls(ast, aliases(ast))

  defp calls(node, aliases) do
    {_ast, acc} =
      Macro.prewalk(node, [], fn
        {{:., _, [module, fun]}, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, [{resolve(module, aliases), fun, args, meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Local calls by name (exit/1).
  defp local_calls(ast, name) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {^name, _, args} = node, acc when is_list(args) -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp run_body(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{:run, _, [_args]}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    found
  end

  defp first_statement({:__block__, _, [first | _]}), do: first
  defp first_statement(single), do: single

  defp called?(calls, module, fun), do: Enum.any?(calls, &match?({^module, ^fun, _, _}, &1))

  defp lines(calls, module, fun),
    do: for({^module, ^fun, _args, line} <- calls, do: line)

  # The module may sit inside the prototype-authority compile gate (the
  # production build has no DossierImport), so it is found anywhere.
  test "the task module exists: Mix.Tasks.Sdr.Prototype.Import, a Mix.Task with a moduledoc" do
    ast = ast!()

    {_ast, flags} =
      Macro.prewalk(ast, %{module: false, use: false, doc: false}, fn
        {:defmodule, _, [{:__aliases__, _, [:Mix, :Tasks, :Sdr, :Prototype, :Import]}, _]} = node,
        acc ->
          {node, %{acc | module: true}}

        {:use, _, [{:__aliases__, _, [:Mix, :Task]} | _]} = node, acc ->
          {node, %{acc | use: true}}

        {:@, _, [{:moduledoc, _, [doc]}]} = node, acc when is_binary(doc) ->
          {node, %{acc | doc: String.trim(doc) != ""}}

        node, acc ->
          {node, acc}
      end)

    assert flags == %{module: true, use: true, doc: true}
  end

  test "SafeLog.attach/0 is the first statement of run/1" do
    ast = ast!()
    body = run_body(ast)
    assert body, "no def run/1"

    assert [{@safe_log, :attach, [], _line}] = calls(first_statement(body), aliases(ast)),
           "the first statement of run/1 is not SafeLog.attach/0"
  end

  test "it enters only through Session.enter/1, before any input read, and starts nothing itself" do
    calls = calls(ast!())

    assert [enter_line] = lines(calls, @session, :enter),
           "Session.enter/1 must be called exactly once"

    [read_line | _] = lines(calls, SdrAgent.Prototype.DossierParser, :read)
    assert enter_line < read_line, "an input is read before the session entry"

    forbidden = [
      {SdrAgent.Prototype.BootCheck, :verify!},
      {SdrAgent.Prototype.BootCheck, :check},
      {SdrAgent.Prototype, :enter_session},
      {Application, :ensure_all_started},
      {Application, :ensure_started},
      {Mix.Task, :run},
      {SdrAgent.Repo, :start_link},
      {Oban, :start_link},
      {Supervisor, :start_link},
      {Ecto.Migrator, :with_repo}
    ]

    for {module, fun} <- forbidden do
      refute called?(calls, module, fun), "the task calls #{inspect(module)}.#{fun}"
    end

    env =
      for {System, fun, args, _} <- calls, fun in [:get_env, :fetch_env, :fetch_env!], do: args

    assert env == [["SDR_PROTOTYPE_SESSION"]], "environment reads: #{inspect(env)}"
  end

  test "inputs are read only through the bounded readers, then prepare, import and cap_used" do
    calls = calls(ast!())

    for {module, fun, arity} <- [
          {SdrAgent.Prototype.DossierParser, :read, 2},
          {SdrAgent.Prototype.SpotcheckManifest, :read, 3},
          {SdrAgent.Prototype.DossierImport, :prepare, 5},
          {SdrAgent.Prototype.DossierImport, :import, 2},
          {SdrAgent.Prototype.DossierImport, :cap_used, 1}
        ] do
      assert Enum.any?(calls, &match?({^module, ^fun, args, _} when length(args) == arity, &1)),
             "no #{inspect(module)}.#{fun}/#{arity} call"
    end

    files = for {module, fun, _, line} <- calls, module in [File, :file], do: {module, fun, line}
    assert files == [], "direct file calls: #{inspect(files)}"
  end

  test "output is SafeLog.say/2 with :import_row and :import_summary only; no IO, Logger or Mix.shell" do
    calls = calls(ast!())

    says = for {@safe_log, :say, [code | _], _} <- calls, do: code
    assert says != [] and Enum.all?(says, &(&1 in [:import_row, :import_summary])), inspect(says)
    assert :import_row in says and :import_summary in says

    channels =
      for {module, fun, _, line} <- calls,
          module in [IO, Logger, :io, :logger] or {module, fun} in [{Mix, :shell}] or
            {module, fun} == {@safe_log, :event},
          do: {module, fun, line}

    assert channels == [], "other output channels: #{inspect(channels)}"
  end

  test "Mix.raise and exit carry fixed literals only" do
    ast = ast!()

    raises = for {Mix, :raise, args, line} <- calls(ast), do: {args, line}

    for {args, line} <- raises do
      assert match?([message] when is_binary(message), args),
             "Mix.raise at line #{line} is not a literal string"
    end

    for args <- local_calls(ast, :exit) do
      assert match?([{:shutdown, code}] when is_integer(code), args),
             "exit/1 with a non-literal reason: #{inspect(args)}"
    end
  end
end
