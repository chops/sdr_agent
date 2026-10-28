defmodule SdrAgent.Prototype.BasisTest do
  @moduledoc """
  RED-b2c (Codex 3122b0d4 Q5), D-237 slice S2: the `d237-basis/1` size
  guard at its pure entry, `SdrAgent.Prototype.Basis.encode/1`. It encodes
  with `sdr-canonical-json/1` (`SdrAgent.Audit.Canonical`) and bounds the
  canonical UTF-8 BYTES at 8192, never the character count:
  `{:ok, bytes, sha256_hex}` with the SHA of exactly those bytes, or the
  value-free `{:error, :basis_invalid}`.

  The guard is exercised directly with synthetic maps (the grammar of real
  bases keeps them far smaller; this is the guard's own boundary, not a real
  basis). The export is asserted first. At RED-b2c the module is a deny-only
  declaration (Codex 79819840 R3: `encode/1` refuses everything), so the
  within-bound cases genuinely fail and the two over-bound cases pass only
  because everything is refused: no credit for them until the within-bound
  cases pass. No database, no real data.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.Canonical

  @basis SdrAgent.Prototype.Basis
  @limit 8192

  defp encode!(term) do
    assert Code.ensure_loaded?(@basis) and function_exported?(@basis, :encode, 1),
           "structural: #{inspect(@basis)}.encode/1 is not exported"

    Function.capture(@basis, :encode, 1).(term)
  end

  # A one-key map whose canonical encoding is exactly `size` bytes, padded
  # with `unit` (ASCII or a multi-byte character).
  defp sized(size, unit) do
    overhead = byte_size(Canonical.encode!(%{"pad" => ""}))
    count = div(size - overhead, byte_size(unit))
    term = %{"pad" => String.duplicate(unit, count)}
    assert byte_size(Canonical.encode!(term)) == size, "fixture: #{size} bytes with #{unit}"
    term
  end

  test "exactly 8192 canonical bytes encode, with the SHA of those bytes" do
    term = sized(@limit, "x")
    bytes = Canonical.encode!(term)
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert encode!(term) == {:ok, bytes, sha}
  end

  test "8193 canonical bytes are basis_invalid, value-free" do
    term = sized(@limit + 1, "x")
    assert encode!(term) == {:error, :basis_invalid}
  end

  test "the bound is UTF-8 bytes: fewer than 8192 characters over 8192 bytes are basis_invalid" do
    # "é" is two bytes: 8194 bytes in about 4097 characters.
    term = sized(@limit + 2, "é")
    assert String.length(term["pad"]) < @limit
    assert encode!(term) == {:error, :basis_invalid}
  end

  test "multi-byte characters at exactly 8192 bytes encode" do
    term = sized(@limit, "é")
    assert {:ok, bytes, _sha} = encode!(term)
    assert byte_size(bytes) == @limit
  end
end
