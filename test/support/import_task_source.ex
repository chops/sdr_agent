defmodule SdrAgent.ImportTaskSource do
  @moduledoc """
  A pure, lexical source guard for `mix sdr.prototype.import`
  (`lib/mix/tasks/sdr.prototype.import.ex`; interfaces r6 IF-2 task row,
  IF-8 "Attached before any private input" and the prototype-code source
  rule; supplement 1 r2 §5 "Callers"; Codex 8ff184e4). `violations/1`
  parses a source text (never runs or compiles it) and returns the closed,
  sorted list of rule violations; `[]` means the source passes every rule.

  Only the body of `defmodule Mix.Tasks.Sdr.Prototype.Import` is analysed,
  and only inside a supported grammar (Codex task-harness review R1):

  - the file's top level is the task module alone, or one
    `if <gate> do <task module> end` with no `else`, and the task module is
    defined exactly once;
  - inside it there is no nested `defmodule`, `defprotocol`, `defimpl` or
    `Module.create`, no `defmacro`/`defmacrop`, no `use` other than
    `use Mix.Task`, no `@before_compile`, `@after_compile`,
    `@after_verify`, `@on_definition` or `@on_load`, no `require` with
    options (`require ..., as:` is an alias), and at most one `def run/1`
    clause, a top-level statement of the module (none is the closed
    `:no_run`, not a refusal);
  - those definition, scope and code-generation forms are supported only in
    their literal local syntax: after alias resolution, no call to
    `Module.create`, to `Kernel.def`, `defp`, `defmacro`, `defmacrop`,
    `defmodule`, `defprotocol`, `defimpl`, `defdelegate`, `use` or `@`, or to
    any `Kernel.SpecialForms` function (so `alias Module, as: Builder` then
    `Builder.create(...)`, `Elixir.Module.create(...)`,
    `Kernel.defmodule ...` and `Kernel.SpecialForms.alias(...)` are
    refused; Codex task-harness r2 review R1b);
  - aliases (`alias A.B`, `alias A.B, as: C`, `alias A.{B, C}`) are
    top-level statements of the module only, all before any statement
    other than `use`, `require`, `import`, `alias` or a literal
    `@moduledoc`/`@shortdoc`, so none reinterprets an earlier call; each
    name is bound once (no rebinding), never to `Elixir` or to the root of
    a module the rules name (`IO`, `File`, `Logger`, `System`, `Mix`,
    `Kernel`, `Function`, `Module`, `Application`, `Supervisor`, `Oban`,
    `Ecto`, `SdrAgent`), and each target expands through the earlier
    aliases in order.

  Outside that grammar the checker refuses: it returns exactly
  `[:unsupported_scope]` and analyses nothing else (so a helper-local
  alias, a nested module or a rebinding can neither hide a call nor supply
  the task's `run/1`, `use` or `@moduledoc`). Inside it, `use Mix.Task`,
  `@moduledoc` and `run/1` are found among the module's own top-level
  statements only, and every call is resolved against those aliases.

  | Violation | Rule |
  |---|---|
  | `:no_module` | the task module is defined |
  | `:unsupported_scope` | the source is inside the supported grammar above (returned alone) |
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
  | `:indirect_dispatch` | no `import`, `defdelegate`, `apply`, `Kernel.apply`, `:erlang.apply`, `Function.capture`, remote capture `&M.f/n`, or call on a variable module or an unexpandable alias (`__MODULE__.f()`): such dispatch is flagged, never analysed |

  **Honest scope.** This is a lexical, source-order guard over explicit
  remote calls. It is not control flow or runtime dominance: it cannot show
  that `attach/0` succeeded before a read, that the session entry precedes a
  read on every path, that the environment value is the correlation it
  passes, or that nothing is printed on a refusal. It does not follow calls
  into other modules, and it checks only the rules in the table. Those
  need runtime task tests once the sink and startup holds lift.
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
  @injection [:before_compile, :after_compile, :after_verify, :on_definition, :on_load]
  @nested [:defmodule, :defprotocol, :defimpl, :defmacro, :defmacrop]
  @kernel_forms [
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :defmodule,
    :defprotocol,
    :defimpl,
    :defdelegate,
    :use,
    :@
  ]

  # The roots of every Elixir module the rules name: an alias may not bind
  # one of these names (it would reinterpret a ruled call).
  @protected for module <-
                   [@safe_log, @session, IO, Logger, File, System, Mix, Module] ++
                     Enum.map(@readers ++ @required ++ @starts ++ @dispatch, &elem(&1, 0)),
                 match?("Elixir." <> _, Atom.to_string(module)),
                 uniq: true,
                 do: Module.concat([hd(Module.split(module))])

  @doc "The sorted, unique violations of `source` (see the moduledoc)."
  @spec violations(String.t()) :: [atom()]
  def violations(source) when is_binary(source) do
    with {:ok, body} <- task_body(Code.string_to_quoted!(source)),
         statements = statements(body),
         :ok <- supported(body, statements),
         {:ok, aliases} <- top_aliases(statements),
         calls = calls(body, aliases),
         :ok <- no_remote_forms(calls) do
      body |> module_violations(statements, aliases, calls) |> Enum.uniq() |> Enum.sort()
    else
      :none -> [:no_module]
      :unsupported -> [:unsupported_scope]
    end
  end

  defp module_violations(body, statements, aliases, calls) do
    run = run_body(statements)
    run_calls = if run, do: calls(run, aliases), else: []

    [
      unless(Enum.any?(statements, &use_mix_task?/1), do: :not_mix_task),
      unless(Enum.any?(statements, &moduledoc?/1), do: :no_moduledoc),
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

  ## The module, its supported grammar, its aliases and its calls

  # The task module's body, only when the file's top level is that module
  # alone or one `if <gate> do <module> end`, and it is defined once.
  defp task_body(ast) do
    case {count(ast, &task_module?/1), statements(ast)} do
      {0, _statements} ->
        :none

      {1, [{:defmodule, _, [_name, [do: body]]} = module]} ->
        body_of(module, body)

      {1, [{:if, _, [_gate, [do: {:defmodule, _, [_name, [do: body]]} = module]]}]} ->
        body_of(module, body)

      _other ->
        :unsupported
    end
  end

  defp body_of(module, body), do: if(task_module?(module), do: {:ok, body}, else: :unsupported)

  defp task_module?({:defmodule, _, [{:__aliases__, _, @task} | _]}), do: true
  defp task_module?(_node), do: false

  defp statements({:__block__, _, statements}), do: statements
  defp statements(nil), do: []
  defp statements(statement), do: [statement]

  defp count(ast, fun) do
    {_ast, n} =
      Macro.prewalk(ast, 0, fn node, n -> {node, if(fun.(node), do: n + 1, else: n)} end)

    n
  end

  # No scope the checker cannot attribute: nested modules, macros, code
  # injection, local aliases, or a run/1 that is not one top-level clause.
  defp supported(body, statements) do
    top_aliases = Enum.count(statements, &alias?/1)

    if count(body, &unsupported?/1) == 0 and count(body, &alias?/1) == top_aliases and
         count(body, &run_def?/1) <= 1 and
         count(body, &run_def?/1) == Enum.count(statements, &run_def?/1),
       do: :ok,
       else: :unsupported
  end

  defp unsupported?({form, _, args}) when form in @nested and is_list(args), do: true
  defp unsupported?({:use, _, [{:__aliases__, _, [:Mix, :Task]}]}), do: false
  defp unsupported?({:use, _, args}) when is_list(args), do: true
  defp unsupported?({:require, _, [_module, _options | _]}), do: true

  defp unsupported?({:@, _, [{name, _, args}]}) when name in @injection and is_list(args),
    do: true

  defp unsupported?(_node), do: false

  # After alias resolution (Codex R1b): a remote definition, scope or
  # code-generation form is refused, whatever name reached it.
  defp no_remote_forms(calls),
    do: if(Enum.any?(calls, &remote_form?/1), do: :unsupported, else: :ok)

  defp remote_form?({Module, :create, _args, _line}), do: true
  defp remote_form?({Kernel, fun, _args, _line}), do: fun in @kernel_forms
  defp remote_form?({Kernel.SpecialForms, _fun, _args, _line}), do: true
  defp remote_form?(_call), do: false

  defp alias?({:alias, _, args}) when is_list(args), do: true
  defp alias?(_node), do: false

  defp run_def?({:def, _, [{:when, _, [{:run, _, [_arg]}, _guard]} | _]}), do: true
  defp run_def?({:def, _, [{:run, _, [_arg]} | _]}), do: true
  defp run_def?(_node), do: false

  # The module's aliases, in order: all in the leading prefix, each name
  # bound once and never to a protected root, each target expanded through
  # the aliases before it.
  defp top_aliases(statements) do
    case Enum.reduce_while(statements, {%{}, :prefix}, &top_statement/2) do
      {aliases, _phase} -> {:ok, aliases}
      :unsupported -> :unsupported
    end
  end

  defp top_statement(statement, {aliases, phase}) do
    cond do
      not alias?(statement) -> {:cont, {aliases, if(prefix?(statement), do: phase, else: :body)}}
      phase == :body -> {:halt, :unsupported}
      true -> statement |> bindings(aliases) |> bind(aliases)
    end
  end

  defp prefix?({form, _, args}) when form in [:use, :require, :import] and is_list(args), do: true

  defp prefix?({:@, _, [{doc, _, [text]}]}) when doc in [:moduledoc, :shortdoc],
    do: is_binary(text)

  defp prefix?(_statement), do: false

  defp bindings({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, aliases) do
    with {:ok, full} <- expand(base, aliases) do
      Enum.reduce_while(children, {:ok, []}, &child_binding(&1, &2, full))
    end
  end

  defp bindings(
         {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [short]}]]},
         aliases
       )
       when is_atom(short) do
    with {:ok, full} <- expand(parts, aliases), do: {:ok, [{short, full}]}
  end

  defp bindings({:alias, _, [{:__aliases__, _, parts}]}, aliases) do
    with {:ok, full} <- expand(parts, aliases), do: {:ok, [{List.last(parts), full}]}
  end

  defp bindings(_unsupported_alias, _aliases), do: :unsupported

  # One child of `alias A.{B, C.D}`: binds its last part to A.<child>.
  defp child_binding({:__aliases__, _, parts}, {:ok, acc}, full) do
    case expand(parts, %{}) do
      {:ok, _child} -> {:cont, {:ok, [{List.last(parts), Module.concat([full | parts])} | acc]}}
      :unsupported -> {:halt, :unsupported}
    end
  end

  defp child_binding(_other, _acc, _full), do: {:halt, :unsupported}

  defp bind({:ok, new}, aliases) do
    new
    |> Enum.reverse()
    |> Enum.reduce_while(aliases, fn {short, full}, acc ->
      if short == :"Elixir" or Module.concat([short]) in @protected or Map.has_key?(acc, short),
        do: {:halt, :unsupported},
        else: {:cont, Map.put(acc, short, full)}
    end)
    |> case do
      :unsupported -> {:halt, :unsupported}
      bound -> {:cont, {bound, :prefix}}
    end
  end

  defp bind(:unsupported, _aliases), do: {:halt, :unsupported}

  # `A.B.C` with `A` an earlier alias expands through it; any non-atom part
  # (`__MODULE__.X`, `unquote(...)`) is not expandable.
  defp expand([first | rest] = parts, aliases) do
    if Enum.all?(parts, &is_atom/1),
      do: {:ok, Module.concat([Map.get(aliases, first, first) | rest])},
      else: :unsupported
  end

  defp expand(_parts, _aliases), do: :unsupported

  defp resolve({:__aliases__, _, parts}, aliases) do
    case expand(parts, aliases) do
      {:ok, module} -> module
      :unsupported -> :dynamic
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

  # The body of the module's one top-level `def run/1` clause, or nil.
  defp run_body(statements) do
    Enum.find_value(statements, fn
      {:def, _, [{:run, _, [_args]}, [do: run]]} -> run
      {:def, _, [{:when, _, [{:run, _, [_args]}, _guard]}, [do: run]]} -> run
      _other -> nil
    end)
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
        {form, _, args} = node, _acc when form in [:import, :defdelegate] and is_list(args) ->
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
