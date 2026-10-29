defmodule SdrAgent.D237TaskAdoption do
  @moduledoc """
  The pure source check of D-237 task adoption (S1b plan r4, I2 r2): whether
  one prototype task module's source follows the boundary grammar. It
  parses the source with `Code.string_to_quoted/2` and never compiles,
  evaluates or loads it.

  The grammar, for task `kind` (one of `:setup`, `:provision`, `:import`,
  `:op`, `:serve`):

  - the file's only top-level form is an `if` on
    `Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)`
    whose `do` block is the one `defmodule` (otherwise `:not_gated`);
  - exactly one `run/1` clause (`def run(argv)`, no guard), whose body is
    exactly two expressions: `attached = SafeLog.attach(file: nil)` then
    `TaskBoundary.run(kind, attached, fn -> … end)`, with `kind` the
    literal atom for the file and the third argument a zero-arity `fn`
    literal. `SafeLog` and `TaskBoundary` may be written as the full
    `SdrAgent.Prototype.*` names or through an alias of exactly them
    (otherwise `:run_shape`; `:no_run` when there is no `run/1`);
  - the attach call is exactly `attach(file: nil)` (otherwise `:attach_form`);
  - no `@requirements` attribute (`:requirements`);
  - no call anywhere in the module to `IO.*`, `Logger.*`, `Mix.shell/0`,
    `Mix.raise/1,2`, `System.halt/0,1`, `System.stop/0,1`,
    `:erlang.halt/0,1,2`, `:init.stop/0,1`, `exit/1` or `Process.exit/2`
    (`:forbidden_call`);
  - unparsable source is `:not_parsed`.

  `violations/2` returns the sorted, unique list; `[]` means the source
  follows the grammar. An ungated lone `defmodule` (or a non-gate `if`
  around one) is `:not_gated` and its module is still checked; any other
  top-level form is `:not_gated` alone.

  Alias resolution (pinned at GREEN). A module reference in `run/1` is the
  `__aliases__` parts as written, with its first part replaced when an
  alias binds it. Only the module body's own `alias` forms, and `require`
  forms with `as:`, that come BEFORE the `run/1` clause bind, in source
  order, a later one replacing an earlier one; an alias's own target is
  expanded the same way, and `alias A.{B, C}` binds each element. A
  reference counts as `SafeLog` or `TaskBoundary` only when it resolves to
  exactly `SdrAgent.Prototype.SafeLog` or `SdrAgent.Prototype.TaskBoundary`.
  Fail-closed limits: an alias form whose target or `as:` is not a literal
  alias makes every reference in `run/1` unresolved; an `Elixir.`-prefixed,
  `__MODULE__`-relative or atom reference never resolves (`:run_shape`).
  For `:forbidden_call`, a call's module is checked as written (with an
  `Elixir.` prefix dropped) AND through every literal alias or
  `require ..., as:` anywhere in the module that binds its first part;
  `Kernel.exit/1` counts as `exit/1`.

  It is a lexical check of the reviewed source, not a runtime proof. Outside
  it, and so review items: dynamic dispatch (`apply/3`, `:erlang.apply`,
  captures held in variables or `&Mod.fun/n` captures of the arity-limited
  calls), `import` of a forbidden module followed by a local call,
  `defdelegate`, macros and `use` callbacks that inject code, a forbidden
  module named through a non-literal alias, `attach` calls outside the
  first `run/1` statement, a `run/1` clause nested inside another
  module-body form, and module-body effects beyond `use`, `alias`,
  attributes and definitions. The invalid-syntax and run-shape controls
  are kept. Task-specific grammars (for example S3's `ImportTaskSource`)
  are stricter and must pass as well.
  """

  @gate [:sdr_agent, :prototype_authority_compiled, false]
  @safe_log [:SdrAgent, :Prototype, :SafeLog]
  @task_boundary [:SdrAgent, :Prototype, :TaskBoundary]

  # `{module, function or :any, arities or :any}`; a module is its alias
  # parts (Elixir) or its atom (Erlang).
  @forbidden [
    {[:IO], :any, :any},
    {[:Logger], :any, :any},
    {[:Mix], :shell, [0]},
    {[:Mix], :raise, [1, 2]},
    {[:System], :halt, [0, 1]},
    {[:System], :stop, [0, 1]},
    {:erlang, :halt, [0, 1, 2]},
    {:init, :stop, [0, 1]},
    {[:Kernel], :exit, [1]},
    {[:Process], :exit, [2]}
  ]

  # A forbidden Elixir module written as an atom names the same alias parts.
  @forbidden_atoms %{
    IO => [:IO],
    Logger => [:Logger],
    Mix => [:Mix],
    System => [:System],
    Kernel => [:Kernel],
    Process => [:Process]
  }

  @type violation ::
          :not_parsed
          | :not_gated
          | :no_run
          | :run_shape
          | :attach_form
          | :requirements
          | :forbidden_call

  @doc "The sorted, unique grammar violations of `source` for task `kind`."
  @spec violations(String.t(), atom()) :: [violation()]
  def violations(source, kind) when is_binary(source) and is_atom(kind) do
    case Code.string_to_quoted(source) do
      {:ok, quoted} -> quoted |> top_level(kind) |> Enum.uniq() |> Enum.sort()
      {:error, _diagnostic} -> [:not_parsed]
    end
  end

  defp top_level({:if, _, [condition, [do: {:defmodule, _, _} = module]]}, kind) do
    if gate?(condition),
      do: module_violations(module, kind),
      else: [:not_gated | module_violations(module, kind)]
  end

  defp top_level({:defmodule, _, _} = module, kind),
    do: [:not_gated | module_violations(module, kind)]

  defp top_level(_quoted, _kind), do: [:not_gated]

  defp gate?({{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _, args}),
    do: args == @gate

  defp gate?(_condition), do: false

  defp module_violations({:defmodule, _, [_name, [do: body]]}, kind) do
    List.flatten([run_violations(forms(body), kind), requirements(body), forbidden(body)])
  end

  defp module_violations(_module, _kind), do: [:no_run]

  defp forms({:__block__, _, forms}), do: forms
  defp forms(form), do: [form]

  # run/1: exactly one clause; the aliases are those before it.
  defp run_violations(forms, kind) do
    {before, rest} = Enum.split_while(forms, &(not run_clause?(&1)))

    case Enum.filter(rest, &run_clause?/1) do
      [] -> [:no_run]
      [clause] -> clause_violations(clause, Enum.reduce(before, scope(), &bind/2), kind)
      _clauses -> [:run_shape]
    end
  end

  defp run_clause?({:def, _, [head | _]}), do: run_head?(head)
  defp run_clause?(_form), do: false

  defp run_head?({:when, _, [head | _]}), do: run_head?(head)
  defp run_head?({:run, _, [_param]}), do: true
  defp run_head?(_head), do: false

  defp clause_violations(
         {:def, _, [{:run, _, [param]}, [do: {:__block__, _, [first, second]}]]},
         scope,
         kind
       ) do
    with true <- variable?(param),
         {:ok, attach_args} <- attach_statement(first, scope),
         true <- boundary_statement?(second, scope, kind) do
      if attach_args == [[file: nil]], do: [], else: [:attach_form]
    else
      _shape -> [:run_shape]
    end
  end

  defp clause_violations(_clause, _scope, _kind), do: [:run_shape]

  defp variable?({name, meta, context}) when is_atom(name) and is_list(meta), do: is_atom(context)

  defp variable?(_param), do: false

  defp attach_statement(
         {:=, _, [{:attached, _, context}, {{:., _, [module, :attach]}, _, args}]},
         scope
       )
       when is_atom(context) do
    if resolve(module, scope) == {:ok, @safe_log}, do: {:ok, args}, else: :error
  end

  defp attach_statement(_statement, _scope), do: :error

  defp boundary_statement?(
         {{:., _, [module, :run]}, _, [task, {:attached, _, context}, fun]},
         scope,
         kind
       )
       when is_atom(context) do
    resolve(module, scope) == {:ok, @task_boundary} and task === kind and zero_arity_fn?(fun)
  end

  defp boundary_statement?(_statement, _scope, _kind), do: false

  defp zero_arity_fn?({:fn, _, [{:->, _, [[], _body]}]}), do: true
  defp zero_arity_fn?(_fun), do: false

  # Alias scope: short name => alias parts, or `:unresolved`; `opaque`
  # when some alias form could not be read, so no short name is trusted.
  defp scope, do: %{aliases: %{}, opaque: false}

  defp bind({:alias, _, [target]}, scope), do: bind_alias(target, nil, scope)

  defp bind({:alias, _, [target, opts]}, scope) when is_list(opts),
    do: bind_alias(target, Keyword.get(opts, :as), scope)

  defp bind({:alias, _, _args}, scope), do: %{scope | opaque: true}

  defp bind({:require, _, [target, opts]}, scope) when is_list(opts) do
    case Keyword.fetch(opts, :as) do
      {:ok, as} -> bind_alias(target, as, scope)
      :error -> scope
    end
  end

  defp bind(_form, scope), do: scope

  defp bind_alias({{:., _, [base, :{}]}, _, elements}, nil, scope),
    do: Enum.reduce(elements, scope, &bind_element(&1, base, &2))

  defp bind_alias({:__aliases__, _, parts} = target, as, scope) do
    case short_name(parts, as) do
      {:ok, short} -> put_in(scope, [:aliases, short], expand(target, scope))
      :error -> %{scope | opaque: true}
    end
  end

  defp bind_alias(_target, _as, scope), do: %{scope | opaque: true}

  defp bind_element({:__aliases__, meta, parts}, base, scope),
    do: bind_alias({:__aliases__, meta, [base | parts]}, nil, scope)

  defp bind_element(_element, _base, scope), do: %{scope | opaque: true}

  defp short_name(parts, nil) do
    case List.last(parts) do
      short when is_atom(short) -> {:ok, short}
      _other -> :error
    end
  end

  defp short_name(_parts, {:__aliases__, _, [short]}) when is_atom(short), do: {:ok, short}
  defp short_name(_parts, _as), do: :error

  # The full alias parts of a written reference, or `:unresolved`. A
  # multi-alias element arrives with its base AST as the first part.
  defp expand({:__aliases__, _, [{:__aliases__, _, _} = base | tail]}, scope) do
    case expand(base, scope) do
      parts when is_list(parts) -> if atoms?(tail), do: parts ++ tail, else: :unresolved
      :unresolved -> :unresolved
    end
  end

  defp expand({:__aliases__, _, [head | tail] = parts}, scope) when is_atom(head) do
    cond do
      head == :"Elixir" or not atoms?(parts) or scope.opaque -> :unresolved
      Map.has_key?(scope.aliases, head) -> join(Map.fetch!(scope.aliases, head), tail)
      true -> parts
    end
  end

  defp expand(_reference, _scope), do: :unresolved

  defp join(parts, tail) when is_list(parts), do: parts ++ tail
  defp join(:unresolved, _tail), do: :unresolved

  defp atoms?(parts), do: Enum.all?(parts, &is_atom/1)

  defp resolve(reference, scope) do
    case expand(reference, scope) do
      parts when is_list(parts) -> {:ok, parts}
      :unresolved -> :error
    end
  end

  defp requirements(body) do
    found? = collect(body, false, &(&2 or requirements_attribute?(&1)))
    if found?, do: [:requirements], else: []
  end

  defp requirements_attribute?({:@, _, [{:requirements, _, _}]}), do: true
  defp requirements_attribute?(_node), do: false

  defp forbidden(body) do
    bindings = bindings(body)
    found? = collect(body, false, &(&2 or forbidden_call?(&1, bindings)))
    if found?, do: [:forbidden_call], else: []
  end

  # Folds `fun.(node, acc)` over every node of `body`, which is unchanged.
  defp collect(body, acc, fun) do
    {_body, acc} = Macro.prewalk(body, acc, fn node, inner -> {node, fun.(node, inner)} end)
    acc
  end

  # Every literal alias binding anywhere in the module: short name => the
  # alias parts or Erlang atoms it may name.
  defp bindings(body), do: collect(body, %{}, &add_bindings/2)

  defp add_bindings({:alias, _, [target | opts]}, acc), do: add_binding(target, as_of(opts), acc)

  defp add_bindings({:require, _, [target, opts]}, acc) when is_list(opts) do
    case Keyword.fetch(opts, :as) do
      {:ok, as} -> add_binding(target, as, acc)
      :error -> acc
    end
  end

  defp add_bindings(_node, acc), do: acc

  defp as_of([opts]) when is_list(opts), do: Keyword.get(opts, :as)
  defp as_of(_opts), do: nil

  defp add_binding({{:., _, [{:__aliases__, _, base}, :{}]}, _, elements}, nil, acc),
    do: Enum.reduce(elements, acc, &add_element(&1, base, &2))

  defp add_binding({:__aliases__, _, parts}, as, acc) do
    with true <- atoms?(parts), {:ok, short} <- short_name(parts, as) do
      Map.update(acc, short, [strip(parts)], &[strip(parts) | &1])
    else
      _unreadable -> acc
    end
  end

  defp add_binding(target, {:__aliases__, _, [short]}, acc)
       when is_atom(target) and is_atom(short),
       do: Map.update(acc, short, [module_of(target)], &[module_of(target) | &1])

  defp add_binding(_target, _as, acc), do: acc

  defp add_element({:__aliases__, meta, parts}, base, acc),
    do: add_binding({:__aliases__, meta, base ++ parts}, nil, acc)

  defp add_element(_element, _base, acc), do: acc

  defp forbidden_call?({{:., _, [target, fun]}, _, args}, bindings)
       when is_atom(fun) and is_list(args) do
    target
    |> candidates(bindings)
    |> Enum.any?(&forbidden?(&1, fun, length(args)))
  end

  defp forbidden_call?({:exit, _, [_reason]}, _bindings), do: true
  defp forbidden_call?(_node, _bindings), do: false

  defp candidates({:__aliases__, _, parts}, bindings) do
    if atoms?(parts), do: expansions(strip(parts), bindings, []), else: []
  end

  defp candidates(target, _bindings) when is_atom(target), do: [module_of(target)]
  defp candidates(_target, _bindings), do: []

  # The written parts and, transitively, every binding of their first part
  # (a cycle stops at a first part already followed).
  defp expansions([], _bindings, _seen), do: []

  defp expansions([head | tail] = parts, bindings, seen) do
    if head in seen do
      [parts]
    else
      bound =
        for module <- Map.get(bindings, head, []),
            expanded <- expansions_of(module, tail, bindings, [head | seen]),
            do: expanded

      [parts | bound]
    end
  end

  defp expansions_of(parts, tail, bindings, seen) when is_list(parts),
    do: expansions(parts ++ tail, bindings, seen)

  defp expansions_of(module, [], _bindings, _seen), do: [module]
  defp expansions_of(_module, _tail, _bindings, _seen), do: []

  defp strip([:"Elixir" | parts]), do: parts
  defp strip(parts), do: parts

  defp module_of(atom), do: Map.get(@forbidden_atoms, atom, atom)

  defp forbidden?(module, fun, arity) do
    Enum.any?(@forbidden, fn {forbidden_module, forbidden_fun, arities} ->
      module == forbidden_module and forbidden_fun in [:any, fun] and
        (arities == :any or arity in arities)
    end)
  end
end
