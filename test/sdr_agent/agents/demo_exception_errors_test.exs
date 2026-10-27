defmodule SdrAgent.Agents.DemoExceptionErrorsTest do
  @moduledoc """
  C2* slice S4 RED-1, the two typed refusals (plan r2 §5.1 errors, OQ19;
  handback r3 §2.4 "errors"; ADR-0005 C2* item 10, addenda 2 decision 6 and
  3 decision 6).

    * `SdrAgent.Agents.Errors.DemoExceptionNotInUse`: a `Splode.Error` of
      class `:invalid` with exactly the fields `field` and
      `draft_revision_id`. The use-authority reason (`:expired`,
      `:binding_drift`, ...) is not on it: that atom goes only to
      metadata-only telemetry (plan r2 §4.1).
    * `SdrAgent.Agents.Errors.DraftLineageUnavailable`: class `:invalid`,
      fields `field` and `reason` (`:unavailable | :malformed | :unresolved`).

  Both have fixed messages (independent of ids and fields) that never say
  "reconciled" or "verified" (item 12). Being Invalid, neither becomes an
  `Ash.Error.Forbidden`, so neither is audited as an authorization denial
  (`audit/guard.ex`, which audits Forbidden only); the action-level half of
  that (T-E1: no `authz.denied` for a use refusal; a real Forbidden still
  audited) needs the check sites and is RED-2.

  RED report labels: every test fails on its guard at this head
  (structural: the modules are absent).
  """
  use ExUnit.Case, async: true

  @not_in_use SdrAgent.Agents.Errors.DemoExceptionNotInUse
  @lineage SdrAgent.Agents.Errors.DraftLineageUnavailable
  @reasons [:unavailable, :malformed, :unresolved]
  @forbidden_words ~r/reconciled|verified/i

  describe "DemoExceptionNotInUse" do
    test "is an :invalid Splode error carrying only the field and the revision" do
      id = Ecto.UUID.generate()
      error = error!(@not_in_use, field: :draft_revision_id, draft_revision_id: id)

      assert is_exception(error)
      assert Map.get(error, :class) == :invalid

      assert Map.take(error, [:field, :draft_revision_id]) == %{
               field: :draft_revision_id,
               draft_revision_id: id
             }

      for key <- [:reason, :use_error, :code] do
        refute Map.has_key?(error, key), "the use-authority reason is never on the error (#{key})"
      end
    end

    test "has one fixed message that never says reconciled or verified" do
      a = error!(@not_in_use, field: :draft_revision_id, draft_revision_id: Ecto.UUID.generate())

      b =
        error!(@not_in_use, field: :current_revision_id, draft_revision_id: Ecto.UUID.generate())

      message = Exception.message(a)

      assert String.trim(message) != "", "a message"
      assert Exception.message(b) == message, "the message names no id and no field"
      refute message =~ @forbidden_words
    end

    test "is an Ash Invalid error class, never Forbidden" do
      error =
        error!(@not_in_use, field: :draft_revision_id, draft_revision_id: Ecto.UUID.generate())

      assert_invalid_class(error, @not_in_use)
    end
  end

  describe "DraftLineageUnavailable" do
    test "is an :invalid Splode error carrying the field and one of three reasons" do
      for reason <- @reasons do
        error = error!(@lineage, field: :draft_revision_id, reason: reason)

        assert is_exception(error)
        assert Map.get(error, :class) == :invalid
        assert Map.take(error, [:field, :reason]) == %{field: :draft_revision_id, reason: reason}
      end
    end

    test "has a fixed message per reason that never says reconciled or verified" do
      for reason <- @reasons do
        message = Exception.message(error!(@lineage, field: :draft_revision_id, reason: reason))

        assert String.trim(message) != "", "#{reason}: a message"
        refute message =~ @forbidden_words, "#{reason}: #{message}"

        assert Exception.message(error!(@lineage, field: :citations, reason: reason)) == message,
               "#{reason}: the message does not depend on the field"
      end
    end

    test "is an Ash Invalid error class, never Forbidden" do
      for reason <- @reasons do
        assert_invalid_class(
          error!(@lineage, field: :draft_revision_id, reason: reason),
          @lineage
        )
      end
    end
  end

  defp error!(module, fields) do
    assert Code.ensure_loaded?(module) and function_exported?(module, :exception, 1),
           "C2* S4: #{inspect(module)} is not implemented"

    invoke(module, :exception, [fields])
  end

  defp invoke(module, fun, args), do: apply(module, fun, args)

  defp assert_invalid_class(error, module) do
    class = Ash.Error.to_error_class(error)

    assert match?(%Ash.Error.Invalid{}, class), "#{inspect(module)} → #{inspect(class)}"
    refute match?(%Ash.Error.Forbidden{}, class)
    assert Enum.any?(class.errors, &match?(%{__struct__: ^module}, &1)), inspect(class.errors)
  end
end
