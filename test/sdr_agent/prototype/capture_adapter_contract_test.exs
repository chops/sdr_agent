defmodule SdrAgent.Prototype.CaptureAdapterContractTest do
  @moduledoc """
  T18: the capture adapter's bounded result contract,
  `SdrAgent.Outreach.Errors.CaptureRefused.adapter_result/1` (S4 proposal r3
  section 3.2; Codex 1fabb2d3 R2). There is one test per row, so each row
  reaches its own assertion:

  - a valid receipt is success: `{:ok, receipt}`;
  - exactly one business refusal, singleton in an `Ash.Error.Invalid`, is
    a permanent outcome: `{:outcome, {:permanent, code}}`;
  - every other value of the four Ash error classes is re-raised
    unchanged: `{:raise, error}`. That covers an empty Invalid; Forbidden,
    Framework and Unknown; the call-shape code `prototype_capture_nested`,
    which stays non-business; an unknown code; multiple refusals; a mixed
    container; and a refusal nested in an Unknown;
  - any other term is unsupported, a fixed value-free `ArgumentError`. That
    covers rollback containers (`Ash.Changeset`, `Ash.Query`), a raw
    `Postgrex.Error`, atoms, binaries, maps, a bare refusal outside a class
    container, `:ok`, `nil`, and `{:ok, non-receipt}`.

  The function is declared deny-only at this head (bounded prerequisite
  construction). So the success, business and class rows are reached REDs,
  and the unsupported rows pass. Synthetic values only; no database.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Outreach.Errors.CaptureRefused

  @business [
    :prototype_binding_mismatch,
    :prototype_approval_not_delegated,
    :prototype_outside_window,
    :prototype_recipient_suppressed,
    :prototype_assurance_unavailable
  ]
  @class_rows [
    :invalid_empty,
    :forbidden,
    :framework,
    :unknown,
    :nested_code,
    :unknown_code,
    :multiple,
    :mixed,
    :nested_container
  ]
  @unsupported_rows [
    :changeset,
    :query,
    :postgrex,
    :atom,
    :binary,
    :map,
    :bare_refusal,
    :ok_atom,
    :nil_value,
    :ok_non_receipt
  ]
  @unsupported {:raise, %ArgumentError{message: "prototype capture: unsupported record result"}}

  defp refused(code), do: CaptureRefused.exception(code: code)

  # A remote call through a captured function, so the compiler's type
  # inference of the deny-only declaration never turns a reached RED into a
  # compile-time type warning.
  defp adapter_result(result), do: Function.capture(CaptureRefused, :adapter_result, 1).(result)

  defp container(:invalid_empty), do: Ash.Error.Invalid.exception(errors: [])
  defp container(:forbidden), do: Ash.Error.Forbidden.exception([])
  defp container(:framework), do: Ash.Error.Framework.exception([])
  defp container(:unknown), do: Ash.Error.Unknown.exception([])

  defp container(:nested_code),
    do: Ash.Error.Invalid.exception(errors: [refused(:prototype_capture_nested)])

  defp container(:unknown_code),
    do: Ash.Error.Invalid.exception(errors: [refused(:prototype_synthetic_unknown_code)])

  defp container(:multiple),
    do:
      Ash.Error.Invalid.exception(
        errors: [refused(:prototype_outside_window), refused(:prototype_recipient_suppressed)]
      )

  defp container(:mixed),
    do:
      Ash.Error.Invalid.exception(
        errors: [
          refused(:prototype_outside_window),
          Ash.Error.Changes.InvalidChanges.exception(message: "synthetic")
        ]
      )

  defp container(:nested_container),
    do:
      Ash.Error.Unknown.exception(
        errors: [Ash.Error.Invalid.exception(errors: [refused(:prototype_outside_window)])]
      )

  defp term(:changeset), do: {:error, Ash.Changeset.new(DeliveryReceipt)}
  defp term(:query), do: {:error, Ash.Query.new(DeliveryReceipt)}
  defp term(:postgrex), do: {:error, %Postgrex.Error{message: "synthetic"}}
  defp term(:atom), do: {:error, :synthetic}
  defp term(:binary), do: {:error, "synthetic"}
  defp term(:map), do: {:error, %{}}
  defp term(:bare_refusal), do: {:error, refused(:prototype_outside_window)}
  defp term(:ok_atom), do: :ok
  defp term(:nil_value), do: nil
  defp term(:ok_non_receipt), do: {:ok, %{}}

  test "T18: a valid captured receipt is success" do
    receipt = %DeliveryReceipt{kind: :captured}
    assert adapter_result({:ok, receipt}) == {:ok, receipt}
  end

  for code <- @business do
    test "T18: the singleton business refusal #{code} is a permanent outcome" do
      error = Ash.Error.Invalid.exception(errors: [refused(unquote(code))])

      assert adapter_result({:error, error}) ==
               {:outcome, {:permanent, unquote(code)}}
    end
  end

  for row <- @class_rows do
    test "T18: the Ash class container #{row} is re-raised unchanged, never a business outcome" do
      error = container(unquote(row))
      assert adapter_result({:error, error}) == {:raise, error}
    end
  end

  for row <- @unsupported_rows do
    test "T18: the unsupported result #{row} is the fixed value-free ArgumentError" do
      assert adapter_result(term(unquote(row))) == @unsupported
    end
  end
end
