defmodule SdrAgent.Prototype.ImportOutcomeTest do
  @moduledoc """
  The closed refusal reasons of `mix sdr.prototype.import`
  (`SdrAgent.Prototype.ImportOutcome.reason/2`; I4 r2, Codex 8e749d09): one
  test per row group of the stage-to-reason table, the agreed 24-reason
  `import_refused` family (S3 + S1b, S1b plan r4 Q2: `@import_reasons --
  [:none]` then six task reasons, in that order), and the total,
  value-free fallback. Synthetic paths and atoms only; nothing is read,
  run or written.

  RED stage: `reason/2` is a deny-only declaration that returns
  `:import_failed` for every input, so each table test fails at its first
  assertion (reached); the family, fallback and in-family tests are
  controls that must hold before and after GREEN.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.BootCheck
  alias SdrAgent.Prototype.ImportOutcome
  alias SdrAgent.Prototype.SafeLog

  @added [
    :invalid_arguments,
    :session_unset,
    :invalid_agent,
    :invalid_correlation,
    :delegation_not_found,
    :boot_refused
  ]
  @session_codes [
    :binding_mismatch,
    :not_prototype_runtime,
    :invalid_agent,
    :session_unset,
    :invalid_correlation,
    :delegation_not_found
  ]
  @skips [
    :no_named_person,
    :role_mailbox,
    :email_unavailable,
    :link_unconfirmed,
    :role_unconfirmed,
    :source_conflict,
    :insufficient_source,
    :not_selected
  ]
  @import_codes [
    :contact_cap_exceeded,
    :dossier_conflict,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :import_failed
  ]
  @cap_codes [:forbidden, :binding_mismatch, :not_prototype_runtime, :import_failed]
  @fallback [
    {:session, :not_a_known_code},
    {:session, "binding_mismatch"},
    {:unknown_stage, :invalid},
    {:arguments, :other},
    {:dossier, :type},
    {:dossier, {:not_a_path, :type}},
    {:dossier, {"companies[0]", "type"}},
    {:spotcheck, %{rule: :type}},
    {:prepare, [{"rows", :count}]},
    {:prepare, [{"rows", :count} | :improper]},
    {:import, %{code: :forbidden}},
    {:cap_used, {:error, :forbidden}},
    {nil, nil}
  ]

  # The agreed import_refused family, in order.
  defp family, do: (SafeLog.reasons(:import) -- [:none]) ++ @added

  test "the agreed import_refused family has 24 distinct reasons and never none" do
    assert length(family()) == 24
    assert family() == Enum.uniq(family())
    refute :none in family()
  end

  describe "the stage-to-reason table" do
    test "arguments: an invalid argument list is invalid_arguments" do
      assert ImportOutcome.reason(:arguments, :invalid) == :invalid_arguments
    end

    test "session: each named entry refusal keeps its own code" do
      for code <- @session_codes do
        assert ImportOutcome.reason(:session, code) == code
      end
    end

    test "session: every boot refusal code is boot_refused" do
      assert [_ | _] = codes = BootCheck.reasons()

      for code <- codes do
        assert ImportOutcome.reason(:session, code) == :boot_refused
      end
    end

    test "dossier and spotcheck: a digest mismatch is digest_mismatch" do
      for stage <- [:dossier, :spotcheck] do
        assert ImportOutcome.reason(stage, {"(file)", :digest_mismatch}) == :digest_mismatch
      end
    end

    test "dossier: any other rule is dossier_invalid" do
      for rule <- [:type, :null, :unreadable, :too_large, :unknown_key] do
        assert ImportOutcome.reason(:dossier, {"companies[0].name", rule}) == :dossier_invalid
      end
    end

    test "spotcheck: an artifact refusal is artifact_invalid, any other rule spotcheck_invalid" do
      assert ImportOutcome.reason(:spotcheck, {"artifact", :artifact_invalid}) ==
               :artifact_invalid

      for rule <- [:type, :null, :unknown_row, :changed] do
        assert ImportOutcome.reason(:spotcheck, {"results[0]", rule}) == :spotcheck_invalid
      end
    end

    test "prepare: a selected row's skip reason is that reason" do
      for rule <- @skips do
        assert ImportOutcome.reason(:prepare, {"companies[1]", rule}) == rule
      end
    end

    test "prepare: a selection refusal is invalid_arguments" do
      for refusal <- [{"rows", :count}, {"rows[0]", :unknown_row}, {"rows[1]", :duplicate}] do
        assert ImportOutcome.reason(:prepare, refusal) == :invalid_arguments
      end
    end

    test "prepare: an artifact refusal is artifact_invalid, any other rule dossier_invalid" do
      assert ImportOutcome.reason(:prepare, {"artifact", :artifact_invalid}) == :artifact_invalid

      for rule <- [:type, :null, :digest_mismatch] do
        assert ImportOutcome.reason(:prepare, {"companies[2].sources[0]", rule}) ==
                 :dossier_invalid
      end
    end

    test "import: the precheck's code is kept" do
      for code <- @import_codes do
        assert ImportOutcome.reason(:import, code) == code
      end
    end

    test "cap_used: its refusal code is kept" do
      for code <- @cap_codes do
        assert ImportOutcome.reason(:cap_used, code) == code
      end
    end
  end

  describe "the total, value-free fallback (controls)" do
    test "an unknown stage, term or malformed refusal is import_failed, never a raise" do
      for {stage, error} <- @fallback do
        assert ImportOutcome.reason(stage, error) == :import_failed
      end
    end

    test "every result of the table and the fallback is in the agreed family" do
      inputs =
        [{:arguments, :invalid}, {:prepare, {"rows", :count}}] ++
          Enum.map(@session_codes, &{:session, &1}) ++
          Enum.map(BootCheck.reasons(), &{:session, &1}) ++
          Enum.map(@skips, &{:prepare, {"companies[1]", &1}}) ++
          Enum.map(@import_codes, &{:import, &1}) ++
          Enum.map(@cap_codes, &{:cap_used, &1}) ++ @fallback

      for {stage, error} <- inputs do
        assert ImportOutcome.reason(stage, error) in family()
      end
    end
  end
end
