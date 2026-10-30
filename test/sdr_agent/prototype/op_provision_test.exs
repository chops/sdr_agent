defmodule SdrAgent.Prototype.OpProvisionTest do
  @moduledoc """
  `mix sdr.prototype.provision` (D-268 M6b; interfaces r6 IF-2
  "Provisioning"; Codex output rulings a3f14552 and delta review f1bffa89):
  the closed argv grammar and the stage-specific output mapping, as pure
  functions, plus the body's source shape. Every mapped outcome is one
  SafeLog line (`provisioned` or `provision_refused`); everything else is
  a tagged outer abort, never a coerced reason. Synthetic values only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.BootCheck

  @task Mix.Tasks.Sdr.Prototype.Provision
  @source "lib/mix/tasks/sdr.prototype.provision.ex"
  @hex String.duplicate("a1", 32)

  # Session codes printed as themselves (ruling f1bffa89).
  @session_codes [
    :binding_mismatch,
    :not_prototype_runtime,
    :session_unset,
    :invalid_agent,
    :invalid_correlation,
    :delegation_not_found
  ]

  # The companion's known refusal atoms (SafeLog provision reasons without :none).
  @provision_codes [
    :worksheet_invalid,
    :budget_unbounded,
    :budget_below_ceiling,
    :grant_exists,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :provision_failed
  ]

  defp argv(overrides \\ []) do
    [agent: "codex_cli", budget_worksheet: "worksheet.json", budget_worksheet_sha256: @hex]
    |> Keyword.merge(overrides)
    |> Enum.flat_map(fn {key, value} ->
      ["--" <> String.replace(Atom.to_string(key), "_", "-"), value]
    end)
  end

  defp parse(args), do: call(@task, :parse, [args])
  defp outcome(stage, result), do: call(@task, :outcome, [stage, result])
  defp refused(reason), do: {:say, :provision_refused, [reason: reason]}

  describe "parse/1" do
    test "the three keys exactly once parse to the agent, the worksheet path and its digest" do
      assert parse(argv()) ==
               {:ok, %{agent: :codex_cli, worksheet: "worksheet.json", worksheet_sha256: @hex}}

      assert match?({:ok, %{agent: :claude_code}}, parse(argv(agent: "claude_code")))
    end

    test "a missing, duplicated, unknown or malformed argument is invalid_arguments" do
      [_flag, _value | without_agent] = argv()

      cases = [
        empty: [],
        missing: without_agent,
        duplicated: argv() ++ ["--agent", "codex_cli"],
        unknown: argv() ++ ["--seed-dir", "/x"],
        positional: argv() ++ ["extra"],
        bad_agent: argv(agent: "gpt"),
        upper_hex: argv(budget_worksheet_sha256: String.upcase(@hex)),
        short_hex: argv(budget_worksheet_sha256: "abc"),
        empty_path: argv(budget_worksheet: "")
      ]

      for {name, args} <- cases do
        assert parse(args) == {:error, :invalid_arguments}, "#{name}: #{inspect(parse(args))}"
      end
    end
  end

  describe "outcome/2" do
    test "an argument refusal is the provision_refused line" do
      assert outcome(:arguments, {:error, :invalid_arguments}) == refused(:invalid_arguments)
    end

    test "the six Session codes are printed as themselves; a returned boot code is boot_refused" do
      for code <- @session_codes do
        assert outcome(:session, {:error, code}) == refused(code), "session #{code}"
      end

      boot = BootCheck.reasons() -- @session_codes
      assert boot != [], "fixture: boot codes"

      for code <- boot do
        assert outcome(:session, {:error, code}) == refused(:boot_refused), "boot #{code}"
      end
    end

    test "an unknown Session code is an outer abort, never a refusal line" do
      for code <- [:no_such_code, :grant_exists, :worksheet_invalid] do
        assert outcome(:session, {:error, code}) == {:abort, {:session, code}}, "#{code}"
      end
    end

    test "a returned worksheet read error is worksheet_invalid" do
      for error <- [{:error, :invalid_path}, {:error, :digest_mismatch}, {:error, :too_large}] do
        assert outcome(:read, error) == refused(:worksheet_invalid), inspect(error)
      end
    end

    test "the companion's actual branch is the provisioned line with the grant id" do
      id = Ecto.UUID.generate()

      for branch <- [:created, :replay] do
        assert outcome(:provision, {:ok, %{grant: %{id: id}, result: branch}}) ==
                 {:say, :provisioned, [grant_id: id, result: branch, reason: :none]}
      end
    end

    test "Forbidden and each known refusal atom are refusal lines; anything else aborts" do
      assert outcome(:provision, {:error, Ash.Error.Forbidden.exception([])}) ==
               refused(:forbidden)

      for code <- @provision_codes do
        assert outcome(:provision, {:error, code}) == refused(code), "#{code}"
      end

      for error <- [:boom, :none, %RuntimeError{message: "x"}, {:nested, :grant_exists}] do
        assert match?({:abort, {:provision, _}}, outcome(:provision, {:error, error})),
               "#{inspect(error)} was not an outer abort"
      end
    end
  end

  test "source: the body uses the result companion, enters Session without enqueuing and reads the fixed root" do
    assert File.exists?(@source), "#{@source} does not exist"
    {:ok, ast} = @source |> File.read!() |> Code.string_to_quoted()

    code =
      Macro.prewalk(ast, fn
        {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :shortdoc] -> nil
        node -> node
      end)

    {_ast, calls} =
      Macro.prewalk(code, [], fn
        {{:., _, [{:__aliases__, _, mod}, fun]}, _, args} = node, acc ->
          {node, [{List.last(mod), fun, args} | acc]}

        node, acc ->
          {node, acc}
      end)

    assert [_one] = for({:Agents, :provision_prototype_grant_result, _} = c <- calls, do: c)
    assert [] == for({:Agents, :provision_prototype_grant, _} = c <- calls, do: c)
    assert [{:Session, :enter, [opts]}] = for({:Session, :enter, _} = c <- calls, do: c)
    refute Keyword.get(opts, :enqueue?, false)
    assert [_read] = for({:BoundedJson, :read_private, _} = c <- calls, do: c)

    assert Macro.to_string(code) =~
             ~s("/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp")
  end
end
