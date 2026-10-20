defmodule SdrAgent.Test.WitnessRootTest do
  @moduledoc """
  #208: `SdrAgent.Test.WitnessRoot.mkdir!` allocates a fresh root even when
  roots left by earlier test VMs share the persistent gitignored
  `tmp/witness-roots`. It never adopts an existing directory: it tries a
  bounded number of collision-resistant candidates with an atomic `mkdir`,
  skips one that already exists, and refuses when every candidate is taken.
  The candidate suffixes can be given (`suffixes:`, at most 5, each a single
  filename component), so the collision path is tested deterministically; by
  default 5 random 32-hex suffixes are tried. Any error other than `:eexist`
  propagates at once. Prefixes are kept verbatim (some callers pass spaces or
  control characters on purpose, to test store-path refusal). Ownership, mode
  0700 and the physical-ancestry rule are unchanged.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Test.WitnessRoot

  @base Path.expand("tmp/witness-roots")

  defp require_mkdir_2! do
    assert Code.ensure_loaded?(WitnessRoot)

    assert function_exported?(WitnessRoot, :mkdir!, 2),
           "#208: WitnessRoot.mkdir!/2 (prefix, suffixes:) must exist"
  end

  defp tag, do: "t208-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

  # A leftover root this test owns: the leaf is created atomically (an
  # existing leaf is never adopted) and its cleanup registered before the
  # marker is written.
  defp leftover!(name) do
    File.mkdir_p!(@base)
    path = Path.join(@base, name)
    File.mkdir!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    File.write!(Path.join(path, "leftover"), "kept")
    path
  end

  defp mine(prefix) do
    case File.ls(@base) do
      {:ok, names} -> Enum.filter(names, &String.starts_with?(&1, prefix))
      {:error, :enoent} -> []
    end
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

    roots =
      for _ <- 1..3 do
        root = WitnessRoot.mkdir!(prefix, [])
        on_exit(fn -> File.rm_rf!(root) end)
        root
      end

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

  test "an injected suffix stays one filename component" do
    require_mkdir_2!()
    prefix = tag()

    for bad <- ["", "a/b", "..", ".", "a\0b"] do
      assert_raise ArgumentError, fn -> WitnessRoot.mkdir!(prefix, suffixes: [bad]) end
    end

    assert mine(prefix) == []
  end

  test "the candidate count is bounded: at most 5 are tried, more are refused" do
    require_mkdir_2!()
    prefix = tag()

    assert_raise ArgumentError, fn ->
      WitnessRoot.mkdir!(prefix, suffixes: ~w(a b c d e f))
    end

    assert mine(prefix) == []
  end

  test "an error other than :eexist propagates at once, without trying the next candidate" do
    require_mkdir_2!()
    prefix = tag()
    too_long = String.duplicate("x", 300)

    error =
      assert_raise File.Error, fn ->
        WitnessRoot.mkdir!(prefix, suffixes: [too_long, "next"])
      end

    assert error.reason == :enametoolong
    refute File.exists?(Path.join(@base, "#{prefix}-next"))
  end
end
