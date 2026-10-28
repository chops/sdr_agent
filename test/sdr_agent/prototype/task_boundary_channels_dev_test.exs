defmodule SdrAgent.Prototype.TaskBoundaryChannelsDevTest do
  @moduledoc """
  Checker deltas d1-d3 of the D-237 task boundary channel proof (S1b plan
  r4, I2 r2), on synthetic observations only. The C checker GREEN (10af09d,
  Codex PASS de346997) is otherwise unchanged. Every absent expectation
  key keeps today's meaning: `format: :test`, `tagged: []`, `orphans: 0`,
  `logger` an exact integer.

  - d1, `format: :dev` (`config/dev.exs`: `"[$level] $metadata$message\\n"`;
    SafeLog keeps no configured metadata key). Exactly two console shapes
    are recognised: `[<level>] prototype: log content withheld` (counted)
    and `[<level>] prototype: <code>` (an exact multiset in `tagged`),
    with `<level>` in SafeLog's eight levels and `<code>` in
    `SafeLog.codes/0`. Tagged lines are recognised only under `:dev`.
  - d2, `orphans: :not_observed`: no proof of orphan absence, never equal
    to 0. Observed and expected must agree exactly.
  - d3, `logger: {min, max}`: a finite range, `0 <= min <= max <= 64`,
    integers only; every counted line still passes the grammar and the
    sentinel check. Tagged lines are never ranged.
  - An expectation outside these forms is `[:expectation_invalid]` only.

  Which cases may use `:not_observed` or a range is fixed by the case
  tables (the P2-min probe list and the named natural-abort B rows), not
  by the checker. The probe expectations in `D237BoundaryCases` are not
  changed here.

  Each test is marked in its name as RED (fails at the base for the
  intended missing behaviour) or GUARD (holds before and after).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.D237BoundaryCases, as: Cases
  alias SdrAgent.D237BoundaryChannels, as: Channels
  alias SdrAgent.Prototype.SafeLog

  @s "S1B-I2-D-0123456789abcdef"
  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]
  @withheld "prototype: log content withheld"
  @test_logger "13:32:18.204 [error] prototype: log content withheld"

  defp exp(overrides) do
    Map.merge(
      %{status: 0, stdout: [], logger: 0, stderr: :empty, files: [], format: :dev},
      Map.new(overrides)
    )
  end

  defp obs(overrides) do
    Map.merge(
      %{status: 0, stdout: "", stderr: "", files: [], orphans: 0, launcher: ""},
      Map.new(overrides)
    )
  end

  defp v(expected, observed), do: Channels.violations(expected, observed, @s)
  defp lines(list), do: Enum.map_join(list, &(&1 <> "\n"))
  defp codes, do: Function.capture(SafeLog, :codes, 0).()

  describe "d1: the dev console format" do
    test "RED: each level's withheld line is counted under :dev" do
      for level <- @levels do
        out = lines(["[#{level}] #{@withheld}"])
        assert v(exp(logger: 1), obs(stdout: out)) == []
      end
    end

    test "RED: each code at each level is an exact tagged entry under :dev" do
      for level <- @levels, code <- codes() do
        out = lines(["[#{level}] prototype: #{code}"])
        assert v(exp(tagged: [{level, code}]), obs(stdout: out)) == []
      end
    end

    test "RED: a missing or an extra tagged line is reported" do
      assert v(exp(tagged: [{:info, :import_row}]), obs(stdout: "")) == [:missing_line]

      assert v(exp(tagged: []), obs(stdout: lines(["[info] prototype: import_row"]))) ==
               [:extra_line]

      assert v(
               exp(tagged: [{:info, :import_row}]),
               obs(stdout: lines(["[warning] prototype: import_row"]))
             ) == [:extra_line, :missing_line]
    end

    test "RED: a test-format line is unknown under :dev" do
      assert v(exp(logger: 0), obs(stdout: lines([@test_logger]))) == [:unknown_line]
    end

    test "GUARD: a dev-format line is unknown under :test" do
      out = lines(["[error] #{@withheld}"])
      assert v(exp(format: :test, logger: 0), obs(stdout: out)) == [:unknown_line]
    end

    test "GUARD: lookalike lines are unknown, never counted or tagged" do
      for line <- [
            "xx[error] #{@withheld}",
            "[error]  #{@withheld}",
            "[error]#{@withheld}",
            "[errorx] #{@withheld}",
            "[Error] #{@withheld}",
            "[fatal] #{@withheld}",
            "[error] request_id=x #{@withheld}",
            "[error] #{@withheld} ",
            "[info] prototype: not_a_code",
            "[info] prototype: import_row extra",
            "[info] prototype: import_row ",
            "[info] prototype:import_row",
            "prototype: log content withheld"
          ] do
        assert v(exp(logger: 0), obs(stdout: lines([line]))) == [:unknown_line]
      end
    end

    test "GUARD: a sentinel inside a lookalike is reported with it" do
      out = lines(["[error] #{@withheld} #{@s}"])
      assert v(exp(logger: 0), obs(stdout: out)) == [:sentinel_stdout, :unknown_line]
    end

    test "RED: a withheld line followed by a continuation line holding the sentinel" do
      out = lines(["[error] #{@withheld}", @s])
      assert v(exp(logger: 1), obs(stdout: out)) == [:sentinel_stdout, :unknown_line]
    end

    test "GUARD: an ANSI-coloured line is an invalid byte, never counted" do
      out = lines(["\e[31m[error] #{@withheld}\e[0m"])
      assert v(exp(logger: 0), obs(stdout: out)) == [:invalid_byte]
    end

    test "GUARD: a raw sentinel line is reported" do
      assert v(exp(logger: 0), obs(stdout: lines([@s]))) == [:sentinel_stdout, :unknown_line]
    end

    test "RED: a format other than :test or :dev is an invalid expectation" do
      for format <- [:prod, nil, "dev"] do
        assert v(exp(format: format), obs([])) == [:expectation_invalid]
      end
    end

    test "RED: a malformed tagged expectation is invalid" do
      for tagged <- [
            [{:fatal, :import_row}],
            [{:info, :not_a_code}],
            [{:info}],
            [:import_row],
            {:info, :import_row},
            [{:info, :import_row} | :improper]
          ] do
        assert v(exp(tagged: tagged), obs([])) == [:expectation_invalid]
      end
    end
  end

  describe "d2: unobserved orphans" do
    test "RED: an expected :not_observed matches only an observed :not_observed" do
      assert v(exp(orphans: :not_observed), obs(orphans: :not_observed)) == []
      assert v(exp(orphans: :not_observed), obs(orphans: 0)) == [:orphans]
    end

    test "GUARD: :not_observed is never equal to 0, and observed orphans still fail" do
      assert v(exp([]), obs(orphans: :not_observed)) == [:orphans]
      assert v(exp(orphans: 0), obs(orphans: :not_observed)) == [:orphans]
      assert v(exp(orphans: :not_observed), obs(orphans: 3)) == [:orphans]
      assert v(exp(orphans: 0), obs(orphans: 2)) == [:orphans]
      assert v(exp(orphans: 0), obs(orphans: 0)) == []
    end

    test "RED: any other orphan expectation is invalid" do
      for orphans <- [1, -1, :unknown, nil, "0"] do
        assert v(exp(orphans: orphans), obs([])) == [:expectation_invalid]
      end
    end

    test "GUARD: no probe expectation in D237BoundaryCases names orphans" do
      for class <- [:bounded, :raw], name <- Cases.cases() do
        refute Map.has_key?(Cases.expected(class, name), :orphans)
      end
    end
  end

  describe "d3: finite logger ranges" do
    test "RED: a count inside the range passes, under either format" do
      for n <- 1..3 do
        test_out = lines(List.duplicate(@test_logger, n))
        assert v(exp(format: :test, logger: {1, 3}), obs(stdout: test_out)) == []

        dev_out = lines(List.duplicate("[error] #{@withheld}", n))
        assert v(exp(logger: {1, 3}), obs(stdout: dev_out)) == []
      end
    end

    test "GUARD: a count outside the range is reported" do
      for n <- [0, 4] do
        out = lines(List.duplicate(@test_logger, n))
        assert v(exp(format: :test, logger: {1, 3}), obs(stdout: out)) == [:logger_count]
      end
    end

    test "RED: a ranged count still checks every line" do
      out = lines([@test_logger, @s])

      assert v(exp(format: :test, logger: {0, 2}), obs(stdout: out)) ==
               [:sentinel_stdout, :unknown_line]
    end

    test "RED: a malformed or unbounded range is invalid" do
      for logger <- [{3, 1}, {-1, 2}, {0, 65}, {1.0, 2}, {:a, 2}, {1}, {1, 2, 3}, [1, 2], -1] do
        assert v(exp(format: :test, logger: logger), obs([])) == [:expectation_invalid]
      end
    end

    test "GUARD: every probe expectation keeps an exact integer count" do
      for class <- [:bounded, :raw], name <- Cases.cases() do
        assert is_integer(Cases.expected(class, name).logger)
      end
    end
  end
end
