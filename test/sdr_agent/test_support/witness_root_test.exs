defmodule SdrAgent.Test.WitnessRootTest do
  @moduledoc """
  #208: `SdrAgent.Test.WitnessRoot.mkdir!` allocates a fresh root even when
  roots left by earlier test VMs share the persistent gitignored
  `tmp/witness-roots`. It never adopts an existing directory: it tries a
  bounded number of collision-resistant candidates with an atomic `mkdir`,
  skips one that already exists, and refuses when every candidate is taken.
  The candidate suffixes can be given (`suffixes:`), so the collision path is
  tested deterministically. Ownership, mode 0700 and the physical-ancestry
  rule are unchanged.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Test.WitnessRoot

  @base Path.expand("tmp/witness-roots")

  defp require_mkdir_2! do
    assert function_exported?(WitnessRoot, :mkdir!, 2),
           "#208: WitnessRoot.mkdir!/2 (prefix, suffixes:) must exist"
  end

  defp tag, do: "t208-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

  defp leftover!(name) do
    path = Path.join(@base, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "leftover"), "kept")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "a leftover root with the candidate's name is skipped, never adopted" do
    require_mkdir_2!()
    prefix = tag()
    old = leftover!("#{prefix}-a")

    root = WitnessRoot.mkdir!(prefix, suffixes: ["a", "b"])
    on_exit(fn -> File.rm_rf!(root) end)

    assert root == Path.join(@base, "#{prefix}-b")
    assert File.ls!(root) == []
    assert mode(root) == 0o700
    assert File.read!(Path.join(old, "leftover")) == "kept"
  end

  test "when every candidate is taken it refuses, creating and adopting nothing" do
    require_mkdir_2!()
    prefix = tag()
    taken = for s <- ["a", "b", "c"], do: leftover!("#{prefix}-#{s}")
    before = File.ls!(@base) |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()

    assert_raise RuntimeError, ~r/no fresh witness root/, fn ->
      WitnessRoot.mkdir!(prefix, suffixes: ["a", "b", "c"])
    end

    after_ = File.ls!(@base) |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()
    assert after_ == before

    for path <- taken, do: assert(File.read!(Path.join(path, "leftover")) == "kept")
  end

  test "default candidates are collision-resistant random suffixes, not a per-VM counter" do
    require_mkdir_2!()
    prefix = tag()
    roots = for _ <- 1..3, do: WitnessRoot.mkdir!(prefix, [])
    on_exit(fn -> Enum.each(roots, &File.rm_rf!/1) end)

    for root <- roots do
      assert Path.basename(root) =~ ~r/\A#{prefix}-[0-9a-f]{32}\z/
      assert mode(root) == 0o700
    end

    assert length(Enum.uniq(roots)) == 3
  end

  test "mkdir!/1 keeps its contract: a fresh 0700 root under tmp/witness-roots" do
    prefix = tag()
    root = WitnessRoot.mkdir!(prefix)
    on_exit(fn -> File.rm_rf!(root) end)

    assert Path.dirname(root) == @base
    assert String.starts_with?(Path.basename(root), prefix <> "-")
    assert File.ls!(root) == []
    assert mode(root) == 0o700
  end
end
