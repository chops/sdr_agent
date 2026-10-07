defmodule SdrAgent.Audit.CanonicalTest do
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.Canonical

  test "declares the canonicalization version" do
    assert Canonical.version() == "sdr-canonical-json/1"
  end

  test "sorts keys by byte order and writes no whitespace" do
    assert Canonical.encode!(%{"A" => "x", b: 1, a: [true, false, nil]}) ==
             ~s({"A":"x","a":[true,false,null],"b":1})
  end

  test "atom and string keys and values encode identically" do
    assert Canonical.encode!(%{status: :queued}) == Canonical.encode!(%{"status" => "queued"})
  end

  test "escapes only quote, backslash and control bytes" do
    assert Canonical.encode!("a\"b\\c\n\u0001/é") == ~s("a\\"b\\\\c\\u000a\\u0001/é")
  end

  test "encodes datetimes as UTC with six fraction digits" do
    dt = DateTime.from_naive!(~N[2026-10-06 12:00:00.5], "Etc/UTC")
    assert Canonical.encode!(dt) == ~s("2026-10-06T12:00:00.500000Z")
    assert Canonical.encode!(~D[2026-10-06]) == ~s("2026-10-06")
  end

  test "encodes numbers deterministically" do
    assert Canonical.encode!([1, -20, 0.5, 0.1, 1.0e-7]) == "[1,-20,0.5,0.1,1.0e-7]"
  end

  test "rejects binaries that are not UTF-8" do
    assert {:error, {:not_utf8, _}} = Canonical.encode(<<0xFF, 0x00>>)
    assert_raise ArgumentError, fn -> Canonical.encode!(%{hash: <<0xFF>>}) end
  end

  test "is stable across map construction order" do
    left = Map.new([{"z", 1}, {"m", %{"y" => 2, "b" => 3}}])
    right = Map.new([{"m", %{"b" => 3, "y" => 2}}, {"z", 1}])
    assert Canonical.encode!(left) == Canonical.encode!(right)
  end
end
