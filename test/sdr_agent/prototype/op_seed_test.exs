defmodule SdrAgent.Prototype.OpSeedTest do
  @moduledoc """
  `mix sdr.prototype.op seed` (D-268 op seed retry; delta 8b34f015, Codex
  entity PASS 3cfaad3d and plan GO 737d8247): the closed argv grammar and
  the stage-specific output mapping, as pure functions, plus the body's
  source shape. Every mapped outcome is one SafeLog line (`seed_result` or
  `seed_refused`); everything else is a tagged outer abort, never a
  coerced reason. Synthetic values only.

  Limit: these pure mapping and source checks do not prove a real Seed
  execution, its database transaction or the guard's runtime timing; that
  needs a focused real contract check after M4 integration.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.BootCheck

  @task Mix.Tasks.Sdr.Prototype.Op
  @source "lib/mix/tasks/sdr.prototype.op.ex"
  @hex String.duplicate("a1", 32)
  @digests Enum.map_join(["a1", "b2", "c3", "d4"], ",", &String.duplicate(&1, 32))

  # Session codes printed as themselves (as provision, ruling f1bffa89).
  @session_codes [
    :binding_mismatch,
    :not_prototype_runtime,
    :session_unset,
    :invalid_agent,
    :invalid_correlation,
    :delegation_not_found
  ]

  # Seed.run/2's known refusal atoms.
  @seed_codes [
    :seed_invalid,
    :seed_differs,
    :seed_failed,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden
  ]

  defp parse(args), do: call(@task, :parse, [args])
  defp outcome(stage, result), do: call(@task, :seed_outcome, [stage, result])
  defp refused(reason), do: {:say, :seed_refused, [reason: reason]}

  defp seeded(result, revisions) do
    {:ok,
     %{
       result: result,
       revisions: revisions,
       icp_id: Ecto.UUID.generate(),
       sequence_id: Ecto.UUID.generate(),
       campaign_id: Ecto.UUID.generate(),
       provenance_sha256: @hex
     }}
  end

  describe "parse/1 seed" do
    test "an absolute seed directory and four digests parse in P,G,C,V order" do
      assert parse([
               "seed",
               "--agent",
               "codex_cli",
               "--seed-dir",
               "/x/seed",
               "--seed-sha256",
               @digests
             ]) ==
               {:ok,
                %{
                  command: :seed,
                  agent: :codex_cli,
                  seed_dir: "/x/seed",
                  seed_sha256: String.split(@digests, ",")
                }}
    end

    test "a relative path, three digests or an upper-case digest is invalid_arguments" do
      cases = [
        relative: ["seed", "--agent", "codex_cli", "--seed-dir", "x", "--seed-sha256", @digests],
        three: [
          "seed",
          "--agent",
          "codex_cli",
          "--seed-dir",
          "/x",
          "--seed-sha256",
          Enum.join(List.duplicate(@hex, 3), ",")
        ],
        upper: [
          "seed",
          "--agent",
          "codex_cli",
          "--seed-dir",
          "/x",
          "--seed-sha256",
          String.upcase(@digests)
        ]
      ]

      for {name, args} <- cases do
        assert parse(args) == {:error, :invalid_arguments}, "#{name}"
      end
    end
  end

  describe "seed_outcome/2" do
    test "an argument refusal is the seed_refused line" do
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
      for code <- [:no_such_code, :seed_failed, :grant_exists] do
        assert outcome(:session, {:error, code}) == {:abort, {:session, code}}, "#{code}"
      end
    end

    test "a returned seed directory error is seed_invalid; any other read value aborts" do
      for error <- [
            {:error, {"campaign.json", :digest_mismatch}},
            {:error, {"provenance.json", :too_large}}
          ] do
        assert outcome(:read, error) == refused(:seed_invalid), inspect(error)
      end

      for value <- [{:error, :boom}, {:error, {:file, :reason}}, :error] do
        assert match?({:abort, {:read, _}}, outcome(:read, value)), inspect(value)
      end
    end

    test "Seed's created branch is result ok and replay is replay, with the returned count" do
      assert outcome(:seed, seeded(:created, 2)) ==
               {:say, :seed_result, [revisions: 2, result: :ok]}

      assert outcome(:seed, seeded(:replay, 2)) ==
               {:say, :seed_result, [revisions: 2, result: :replay]}
    end

    test "a malformed success is an outer abort, never a seed_result line" do
      malformed = [
        seeded(:refused, 2),
        seeded(:ok, 2),
        seeded(:created, -1),
        seeded(:created, nil),
        seeded(:replay, "2"),
        {:ok, %{result: :created}},
        {:ok, %{revisions: 2}},
        {:ok, :created}
      ]

      for value <- malformed do
        assert outcome(:seed, value) == {:abort, {:seed, :unexpected}}, inspect(value)
      end
    end

    test "each known Seed refusal atom is one seed_refused line; anything else aborts" do
      for code <- @seed_codes do
        assert outcome(:seed, {:error, code}) == refused(code), "#{code}"
      end

      # An unknown atom keeps its code in the abort, never a refusal line.
      for code <- [:not_implemented, :none] do
        assert outcome(:seed, {:error, code}) == {:abort, {:seed, code}}, "#{code}"
      end

      for error <- [%RuntimeError{message: "x"}, {:nested, :seed_failed}] do
        assert outcome(:seed, {:error, error}) == {:abort, {:seed, :unexpected}},
               "#{inspect(error)} was not an outer abort"
      end
    end
  end

  test "source: seed enters Session without enqueuing, then guard, SeedDir.read and Seed.run in order" do
    {:ok, ast} = @source |> File.read!() |> Code.string_to_quoted()

    code =
      Macro.prewalk(ast, fn
        {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :shortdoc] -> nil
        node -> node
      end)

    {_ast, calls} =
      Macro.prewalk(code, [], fn
        {{:., meta, [{:__aliases__, _, mod}, fun]}, _, args} = node, acc ->
          {node, [{List.last(mod), fun, args, meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    # Source order: the accumulator is prepended, so sort by line.
    calls = Enum.sort_by(calls, &elem(&1, 3))

    enters =
      for {:Session, :enter, [opts], line} <- calls, do: {Keyword.get(opts, :enqueue?), line}

    assert [{false, enter_line}] = for({false, _} = e <- enters, do: e), inspect(enters)

    assert [{_, _, [:op], guard_line}] =
             for(
               {:ContainmentGuard, :guard, _, line} = c <- calls,
               line > enter_line,
               do: c
             )
             |> Enum.take(1)

    assert [{_, _, [_dir, pins], read_line}] = for({:SeedDir, :read, _, _} = c <- calls, do: c)
    assert [{_, _, _, run_line}] = for({:Seed, :run, _, _} = c <- calls, do: c)
    assert enter_line < guard_line and guard_line < read_line and read_line < run_line

    pin_keys =
      case pins do
        {:%{}, _, pairs} -> pairs |> Keyword.keys() |> Enum.sort()
        other -> other
      end

    assert pin_keys == [:campaign, :offering_profile, :provenance, :writing_guide]
    refute Macro.to_string(code) =~ "owner_user_id"
  end
end
