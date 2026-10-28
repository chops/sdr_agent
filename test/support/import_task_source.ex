defmodule SdrAgent.ImportTaskSource do
  @moduledoc """
  A pure, lexical source guard for `mix sdr.prototype.import`
  (`lib/mix/tasks/sdr.prototype.import.ex`; interfaces r6 IF-2 task row,
  IF-8 "Attached before any private input" and the prototype-code source
  rule; supplement 1 r2 §5 "Callers"; Codex 8ff184e4). `violations/1`
  parses a source text (never runs or compiles it) and returns the closed,
  sorted list of rule violations; `[]` means the source passes every rule.

  Only the body of `defmodule Mix.Tasks.Sdr.Prototype.Import` is analysed
  (it may sit inside a compile-time gate), with that module's aliases
  resolved (`alias A.B`, `alias A.B, as: C`, `alias A.{B, C}`).

  | Violation | Rule |
  |---|---|
  | `:no_module` | the task module is defined |
  | `:not_mix_task` | it has `use Mix.Task` |
  | `:no_moduledoc` | it has a non-empty `@moduledoc` |
  | `:no_run` | it defines `run/1` |
  | `:attach_not_first` | the first statement of `run/1` is `SafeLog.attach/0` |
  | `:outside_run` | `SafeLog.attach`, `Session.enter` and every `DossierParser.read` / `SpotcheckManifest.read` call sit lexically inside `run/1`, never in another function or at module level |
  | `:enter_count` | `Session.enter` is called exactly once |
  | `:enter_arity` | it is called with exactly one argument |
  | `:read_before_enter` | every `DossierParser.read` and `SpotcheckManifest.read` call comes after it in source order |
  | `:missing_reader` | `DossierParser.read/2`, `SpotcheckManifest.read/3`, `DossierImport.prepare/5`, `import/2` and `cap_used/1` are each called |
  | `:start_call` | no `BootCheck.verify!/check`, `Prototype.enter_session`, `Application.ensure_all_started/ensure_started`, `Mix.Task.run`, `Repo.start_link`, `Oban.start_link`, `Supervisor.start_link` or `Ecto.Migrator.with_repo` (no double boot or start) |
  | `:env_read` | the only environment read is one `System.get_env("SDR_PROTOTYPE_SESSION")` |
  | `:file_call` | no `File` or `:file` call |
  | `:say_shape` | every `SafeLog.say` has exactly two arguments, the first a literal `:import_row` or `:import_summary`, and both codes occur |
  | `:other_channel` | no `IO`, `Logger`, `:io`, `:logger`, `Mix.shell` or `SafeLog.event` call |
  | `:raise_not_literal` | `Mix.raise/1` takes a literal string only |
  | `:exit_not_literal` | `exit/1` takes a literal `{:shutdown, integer}` only |
  | `:indirect_dispatch` | no `import`, `apply`, `Kernel.apply`, `:erlang.apply`, `Function.capture`, remote capture `&M.f/n`, or call on a variable module: such dispatch is flagged, never analysed |

  **Honest scope.** This is a lexical, source-order guard over explicit
  remote calls. It is not control flow or runtime dominance: it cannot show
  that `attach/0` succeeded before a read, that the session entry precedes a
  read on every path, that the environment value is the correlation it
  passes, or that nothing is printed on a refusal. Those need runtime task
  tests once the sink and startup holds lift.
  """

  @task [:Mix, :Tasks, :Sdr, :Prototype, :Import]

  @safe_log SdrAgent.Prototype.SafeLog
  @session SdrAgent.Prototype.Session
  @readers [
    {SdrAgent.Prototype.DossierParser, :read},
    {SdrAgent.Prototype.SpotcheckManifest, :read}
  ]
  @required [
    {SdrAgent.Prototype.DossierParser, :read, 2},
    {SdrAgent.Prototype.SpotcheckManifest, :read, 3},
    {SdrAgent.Prototype.DossierImport, :prepare, 5},
    {SdrAgent.Prototype.DossierImport, :import, 2},
    {SdrAgent.Prototype.DossierImport, :cap_used, 1}
  ]
  @starts [
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
  @env_funs [:get_env, :fetch_env, :fetch_env!]
  @say_codes [:import_row, :import_summary]
  @channels [IO, Logger, :io, :logger]
  @dispatch [{Kernel, :apply}, {:erlang, :apply}, {Function, :capture}]

  @doc "The sorted, unique violations of `source` (see the moduledoc)."
  @spec violations(String.t()) :: [atom()]
  def violations(source) when is_binary(source) do
    case find_module(Code.string_to_quoted!(source)) do
      nil -> [:no_module]
      body -> body |> module_violations() |> Enum.uniq() |> Enum.sort()
    end
  end

  defp module_violations(body) do
    aliases = aliases(body)
    calls = calls(body, aliases)
    run = run_body(body)
    run_calls = if run, do: calls(run, aliases), else: []

    [
      unless(flag?(body, &use_mix_task?/1), do: :not_mix_task),
      unless(flag?(body, &moduledoc?/1), do: :no_moduledoc),
      unless(run, do: :no_run),
      run && attach_not_first(run, aliases),
      outside_run(calls -- run_calls),
      enter(calls),
      read_before_enter(calls),
      missing_reader(calls),
      if(Enum.any?(calls, &start?(&1)), do: :start_call),
      env_read(calls),
      if(Enum.any?(calls, fn {m, _, _, _} -> m in [File, :file] end), do: :file_call),
      say_shape(calls),
      if(Enum.any?(calls, &channel?/1), do: :other_channel),
      raise_literal(calls),
      exit_literal(body),
      indirect(body, calls)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false]))
  end

  ## The module, its aliases and its calls

  defp find_module(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, @task}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    found
  end

  defp aliases(body) do
    {_ast, acc} =
      Macro.prewalk(body, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn
             {:__aliases__, _, parts}, acc ->
               Map.put(acc, List.last(parts), Module.concat(base ++ parts))

             _other, acc ->
               acc
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
  defp resolve(_variable_or_expression, _aliases), do: :dynamic

  # Every explicit remote call, in source order: {module, function, args, line}.
  # A field access without parentheses on a variable (`opts.agent`) is not a
  # call; a call on a variable module with parentheses is `:dynamic`.
  defp calls(node, aliases) do
    {_ast, acc} =
      Macro.prewalk(node, [], fn
        {{:., _, [{name, _, context}, _fun]}, meta, []} = node, acc
        when is_atom(name) and is_atom(context) ->
          if meta[:no_parens], do: {node, acc}, else: {node, call(node, aliases, acc)}

        {{:., _, [_target, fun]}, _meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, call(node, aliases, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp call({{:., _, [target, fun]}, meta, args}, aliases, acc) when is_atom(fun),
    do: [{resolve(target, aliases), fun, args, meta[:line]} | acc]

  defp call(_node, _aliases, acc), do: acc

  defp run_body(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {:def, _, [{:run, _, [_args]}, [do: run]]} = node, nil ->
          {node, run}

        {:def, _, [{:when, _, [{:run, _, [_args]}, _guard]}, [do: run]]} = node, nil ->
          {node, run}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp flag?(body, fun) do
    {_ast, found} = Macro.prewalk(body, false, fn node, acc -> {node, acc or fun.(node)} end)
    found
  end

  defp use_mix_task?({:use, _, [{:__aliases__, _, [:Mix, :Task]} | _]}), do: true
  defp use_mix_task?(_node), do: false

  defp moduledoc?({:@, _, [{:moduledoc, _, [doc]}]}) when is_binary(doc),
    do: String.trim(doc) != ""

  defp moduledoc?(_node), do: false

  ## The rules

  defp attach_not_first(run, aliases) do
    first =
      case run do
        {:__block__, _, [first | _]} -> first
        single -> single
      end

    unless match?([{@safe_log, :attach, [], _}], calls(first, aliases)), do: :attach_not_first
  end

  defp outside_run(outside) do
    if Enum.any?(outside, fn {module, fun, _args, _line} ->
         {module, fun} in [{@safe_log, :attach}, {@session, :enter} | @readers]
       end),
       do: :outside_run
  end

  defp enter(calls) do
    enters = for {@session, :enter, args, _line} <- calls, do: args

    [
      if(length(enters) != 1, do: :enter_count),
      if(Enum.any?(enters, &(length(&1) != 1)), do: :enter_arity)
    ]
  end

  defp read_before_enter(calls) do
    case for({@session, :enter, _args, line} <- calls, do: line) do
      [enter_line] ->
        if Enum.any?(calls, &read_at_or_before?(&1, enter_line)), do: :read_before_enter

      _none_or_many ->
        nil
    end
  end

  defp read_at_or_before?({module, fun, _args, line}, enter_line),
    do: {module, fun} in @readers and line <= enter_line

  defp missing_reader(calls) do
    present? = fn {module, fun, arity} ->
      Enum.any?(calls, fn {m, f, args, _line} ->
        m == module and f == fun and length(args) == arity
      end)
    end

    unless Enum.all?(@required, present?), do: :missing_reader
  end

  defp start?({module, fun, _args, _line}), do: {module, fun} in @starts

  defp env_read(calls) do
    env =
      for {module, fun, args, _line} <- calls,
          (module == System and fun in @env_funs) or {module, fun} == {:os, :getenv},
          do: {module, fun, args}

    unless env == [{System, :get_env, ["SDR_PROTOTYPE_SESSION"]}], do: :env_read
  end

  defp say_shape(calls) do
    says = for {@safe_log, :say, args, _line} <- calls, do: args

    well_formed? =
      Enum.all?(says, fn
        [code, _refs] -> code in @say_codes
        _other -> false
      end)

    codes = for [code, _refs] <- says, do: code

    unless well_formed? and Enum.all?(@say_codes, &(&1 in codes)), do: :say_shape
  end

  defp channel?({module, fun, _args, _line}),
    do: module in @channels or {module, fun} in [{Mix, :shell}, {@safe_log, :event}]

  defp raise_literal(calls) do
    if Enum.any?(calls, fn
         {Mix, :raise, [message], _line} -> not is_binary(message)
         {Mix, :raise, _args, _line} -> true
         _other -> false
       end),
       do: :raise_not_literal
  end

  defp exit_literal(body) do
    {_ast, bad} =
      Macro.prewalk(body, false, fn
        {:exit, _, [{:shutdown, code}]} = node, acc when is_integer(code) -> {node, acc}
        {:exit, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    if bad, do: :exit_not_literal
  end

  defp indirect(body, calls) do
    {_ast, flagged} =
      Macro.prewalk(body, false, fn
        {:import, _, args} = node, _acc when is_list(args) ->
          {node, true}

        {:apply, _, args} = node, _acc when is_list(args) and length(args) in [2, 3] ->
          {node, true}

        {:&, _, [{:/, _, [{{:., _, _}, _, []}, _arity]}]} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    if flagged or
         Enum.any?(calls, fn {module, fun, _args, _line} ->
           module == :dynamic or {module, fun} in @dispatch
         end),
       do: :indirect_dispatch
  end
end
