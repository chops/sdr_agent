defmodule SdrAgent.Prototype.AdmissionRegisterGuardTest do
  @moduledoc """
  D-237 slice S2, the producer guard on the trusted admission origin
  (mechanism note r3 section B; Codex review of d16e460):
  `SdrAgent.Prototype.Admission.register/4` is an INTERNAL producer helper,
  never a raw registration path.

  - **xref (compiled code):** in the test build, the only module that calls
    `Prototype.Admission.register/4` is `SdrAgent.Agents.Admission`, and the
    only module that calls `Agents.Admission.admit/5` is `SdrAgent.Agents`.
  - **source:** in `admit/5` the registration clause comes after the room
    check, and it is that module's only call of the producer; in
    `SdrAgent.Agents` the one `Admission.admit/5` call sits inside
    `reserve_admitted/5`'s `AdmissionContext.with_owned_registrations/1`.

  A guard over remote calls: a dynamic `apply/3` is not an import and is
  not covered (none exists; a reviewer's grep remains the check for it).
  """
  use ExUnit.Case, async: true

  @admission_source "lib/sdr_agent/agents/admission.ex"
  @agents_source "lib/sdr_agent/agents.ex"

  defp callers_of(mfa) do
    for module <- Application.spec(:sdr_agent, :modules),
        path <- [:code.which(module)],
        is_list(path),
        {:ok, {^module, [imports: imports]}} <- [:beam_lib.chunks(path, [:imports])],
        mfa in imports,
        do: module
  end

  defp quoted!(path), do: path |> File.read!() |> Code.string_to_quoted!()

  # The body of the first `kind name(args)` definition with `arity` args.
  defp definition(ast, kind, name, arity) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {^kind, _meta, [{^name, _head_meta, args}, [do: body]]} = node, nil
        when length(args) == arity ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    assert found, "#{kind} #{name}/#{arity} not found"
    found
  end

  defp calls(ast, matcher) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        if matcher.(node), do: {node, acc + 1}, else: {node, acc}
      end)

    count
  end

  defp local_call?({name, _meta, args}, name) when is_list(args), do: true
  defp local_call?(_node, _name), do: false

  defp remote_call?({{:., _, [{:__aliases__, _, alias}, fun]}, _meta, args}, alias, fun)
       when is_list(args),
       do: true

  defp remote_call?(_node, _alias, _fun), do: false

  test "only Agents.Admission calls Prototype.Admission.register/4 in compiled code" do
    assert callers_of({SdrAgent.Prototype.Admission, :register, 4}) == [SdrAgent.Agents.Admission]
  end

  test "only SdrAgent.Agents calls Agents.Admission.admit/5 in compiled code" do
    assert callers_of({SdrAgent.Agents.Admission, :admit, 5}) == [SdrAgent.Agents]
  end

  test "admit/5 registers only after the room check, and only there" do
    ast = quoted!(@admission_source)
    body = definition(ast, :def, :admit, 5)

    {_body, with_clauses} =
      Macro.prewalk(body, nil, fn
        {:with, _meta, clauses} = node, nil -> {node, clauses}
        node, acc -> {node, acc}
      end)

    assert is_list(with_clauses), "admit/5 has no with chain"

    names =
      for {:<-, _, [_pattern, {name, _, args}]} <- with_clauses, is_list(args), do: name

    room = Enum.find_index(names, &(&1 == :room))
    registration = Enum.find_index(names, &(&1 == :prototype_registration))

    assert is_integer(room) and is_integer(registration) and room < registration,
           "with clauses: #{inspect(names)}"

    # One call of the producer clause in the module (its two compile-gated
    # definitions are not calls), and one remote call of register/4.
    heads = calls(ast, &match?({:defp, _, [{:prototype_registration, _, _} | _]}, &1))
    assert heads == 2
    assert calls(ast, &local_call?(&1, :prototype_registration)) - heads == 1

    assert calls(ast, &remote_call?(&1, [:SdrAgent, :Prototype, :Admission], :register)) == 1
  end

  test "the one admit/5 call is inside reserve_admitted/5's owned-registration wrapper" do
    ast = quoted!(@agents_source)
    assert calls(ast, &remote_call?(&1, [:Admission], :admit)) == 1

    body = definition(ast, :defp, :reserve_admitted, 5)

    assert {{:., _, [{:__aliases__, _, [:AdmissionContext]}, :with_owned_registrations]}, _,
            [{:fn, _, [{:->, _, [[], inner]}]}]} = body

    assert calls(inner, &remote_call?(&1, [:Admission], :admit)) == 1
  end
end
