defmodule SdrAgent.ReadDeadlineClassifyTest do
  @moduledoc """
  `SdrAgent.ReadDeadline.classify/1` against the cancellation shapes the data
  layer produces. With `ash` 3.37, `ash_postgres` 2.15 and `ash_sql` 0.8, a
  statement cancelled by the read's SET LOCAL statement_timeout reaches the
  reader as an `Ash.Error.Unknown` whose `UnknownError` carries the formatted
  Postgrex error string (`Splode.to_error/2`), not the `Postgrex.Error` struct.
  Only that exact formatted head is a timeout; every other shape, including
  near-misses in the same wrapper, stays `:producer_error`.
  """
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.ReadDeadline

  @head "** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to statement timeout"

  defp unknown(error), do: Unknown.exception(errors: [UnknownError.exception(error: error)])

  describe "a statement timeout is :timeout" do
    test "the Postgrex struct with query_canceled (unchanged)" do
      assert ReadDeadline.classify(%Postgrex.Error{postgres: %{code: :query_canceled}}) ==
               :timeout
    end

    test "the formatted statement-timeout head inside Ash.Error.Unknown" do
      error = unknown(@head <> "\n\n    query: SELECT count(*) FROM drafts")

      assert ReadDeadline.classify(error) == :timeout,
             "the upstream wrapper of a statement timeout must classify as :timeout"
    end

    test "the same wrapper carried in a query's errors list" do
      query = %Ash.Query{errors: [UnknownError.exception(error: @head)]}

      assert ReadDeadline.classify(query) == :timeout,
             "a query carrying the wrapped statement timeout must classify as :timeout"
    end
  end

  describe "everything else stays :producer_error" do
    test "a user-requested cancellation in the same wrapper" do
      error =
        unknown(
          "** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to user request"
        )

      assert ReadDeadline.classify(error) == :producer_error
    end

    test "the timeout phrase anywhere but at the head" do
      assert ReadDeadline.classify(unknown("** (RuntimeError) wrapped: " <> @head)) ==
               :producer_error
    end

    test "unrelated text that mentions 57014 and a timeout" do
      error =
        unknown(
          "** (Postgrex.Error) ERROR 40P01 (deadlock_detected) deadlock detected; timeout 57014"
        )

      assert ReadDeadline.classify(error) == :producer_error
    end

    test "a non-string error field" do
      assert ReadDeadline.classify(unknown(:timeout)) == :producer_error
    end

    test "Forbidden keeps its precedence" do
      assert ReadDeadline.classify(Forbidden.exception([])) == :forbidden
    end
  end
end
