defmodule SdrAgent.Prototype.BoundedJsonPrivateTest do
  @moduledoc """
  `SdrAgent.Prototype.BoundedJson.read_private/4`, S1's private evidence
  reader (Codex a6850b13 D4): a lexical relative path under a checked
  0700 root, checked real directories, a regular 0600 leaf that must be the
  same checked object that is opened, rechecked with every directory before
  any byte is read, through one bounded handle closed on every path, with
  the digest of exactly those bytes.

  Races are synchronized through the test-build hooks
  `{SdrAgent.Prototype.BoundedJson, name}` in this process's dictionary
  (`:after_precheck`, `:after_open`, `:after_identity`, `:after_read`),
  never by timing. Substitutions use synthetic SAME-DIGEST private copies,
  so only identity, not the digest, can refuse them. Every file lives in
  exclusive owned scratch roots (`SdrAgent.PrototypeFixtures.scratch_dir!/1`).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.BoundedJson
  alias SdrAgent.PrototypeFixtures

  @canary "CANARY-d237-private-9e4d"
  @bytes ~s({"route":"prototype_binding","consumed":0})
  @max 1_024
  @nested "receipts/2026/route-a.json"

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # A dynamic call: until GREEN, Elixir 1.20 infers the RED stub's literal
  # refusal and would warn on every comparison with {:ok, _}.
  defp read_private(root, path, sha256, max),
    do: Function.capture(BoundedJson, :read_private, 4).(root, path, sha256, max)

  defp hook(name, fun), do: Process.put({BoundedJson, name}, fun)

  # Builds `path` under `root`: each directory created with `dir_mode`, the
  # leaf `bytes` at 0600. Returns the leaf's full path.
  defp tree!(root, path, bytes, dir_mode \\ 0o700) do
    parent =
      path
      |> Path.dirname()
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.reduce(root, fn segment, dir ->
        next = Path.join(dir, segment)
        File.mkdir!(next)
        File.chmod!(next, dir_mode)
        next
      end)

    leaf = Path.join(parent, Path.basename(path))
    File.write!(leaf, bytes)
    File.chmod!(leaf, 0o600)
    leaf
  end

  defp refused(rule), do: {:error, {"(file)", rule}}

  setup do
    root = PrototypeFixtures.scratch_dir!()
    test_pid = self()
    hook(:after_read, fn read -> send(test_pid, {:read, byte_size(read)}) end)
    %{root: root, test_pid: test_pid}
  end

  describe "controls: nested paths, the bound and the digest" do
    test "a nested path under the private root is read once, exactly", %{root: root} do
      tree!(root, @nested, @bytes)

      assert read_private(root, @nested, sha(@bytes), @max) == {:ok, @bytes}
      assert_received {:read, size}
      assert size == byte_size(@bytes)
    end

    test "a top-level path is read too", %{root: root} do
      tree!(root, "route-a.json", @bytes)
      assert read_private(root, "route-a.json", sha(@bytes), @max) == {:ok, @bytes}
    end

    test "intermediate directories only their owner can write are read (0755)", %{root: root} do
      tree!(root, @nested, @bytes, 0o755)
      assert read_private(root, @nested, sha(@bytes), @max) == {:ok, @bytes}
    end

    test "the bound is exact, and a digest mismatch is refused", %{root: root} do
      tree!(root, @nested, @bytes)
      size = byte_size(@bytes)

      assert read_private(root, @nested, sha(@bytes), size) == {:ok, @bytes}
      assert read_private(root, @nested, sha(@bytes), size - 1) == refused(:too_large)
      assert read_private(root, @nested, sha("other"), @max) == refused(:digest_mismatch)
    end
  end

  describe "lexical paths and the root" do
    test "a path that is not a lexical relative path is refused before any lookup",
         %{root: root} do
      tree!(root, @nested, @bytes)

      for path <- [
            "/etc/passwd",
            Path.join(root, @nested),
            "../route-a.json",
            "receipts/../receipts/2026/route-a.json",
            "receipts/./2026/route-a.json",
            "./receipts/2026/route-a.json",
            "receipts//2026/route-a.json",
            "receipts/2026/",
            "",
            "receipts\\2026\\route-a.json",
            "route a.json",
            String.duplicate("a", 201)
          ] do
        result = read_private(root, path, sha(@bytes), @max)
        assert result == refused(:invalid_path), "#{inspect(path)}: #{inspect(result)}"
      end

      refute_received {:read, _size}
    end

    test "a root that is not an absolute real 0700 directory is refused", %{root: root} do
      tree!(root, @nested, @bytes)
      wide = PrototypeFixtures.scratch_dir!(0o755)
      tree!(wide, @nested, @bytes)
      holder = PrototypeFixtures.scratch_dir!()
      linked = Path.join(holder, "root-link")
      File.ln_s!(root, linked)
      file = Path.join(holder, "a-file")
      File.write!(file, @bytes)

      for {label, candidate} <- [
            mode_0755: wide,
            symlink_to_private_root: linked,
            relative: Path.relative_to(root, "/"),
            missing: Path.join(holder, "missing"),
            regular_file: file
          ] do
        result = read_private(candidate, @nested, sha(@bytes), @max)
        assert result == refused(:root_mode), "#{label}: #{inspect(result)}"
      end

      refute_received {:read, _size}
    end
  end

  describe "static ancestors and leaves" do
    test "a symlinked ancestor is refused, even to a same-digest private copy", %{root: root} do
      other = PrototypeFixtures.scratch_dir!()
      tree!(other, @nested, @bytes)
      File.ln_s!(Path.join(other, "receipts"), Path.join(root, "receipts"))

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:not_directory)
      refute_received {:read, _size}
    end

    test "an intermediate directory group or other can write is refused", %{root: root} do
      tree!(root, @nested, @bytes)
      File.chmod!(Path.join(root, "receipts"), 0o777)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:dir_mode)
      refute_received {:read, _size}
    end

    test "a symlinked leaf is refused, even to a same-digest private copy", %{root: root} do
      other = PrototypeFixtures.scratch_dir!()
      target = tree!(other, "copy.json", @bytes)
      tree!(root, @nested, @bytes)
      leaf = Path.join(root, @nested)
      File.rename!(leaf, Path.join(other, "moved.json"))
      File.ln_s!(target, leaf)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:not_regular)
      refute_received {:read, _size}
    end

    test "a leaf that is not 0600, a directory or absent is refused", %{root: root} do
      leaf = tree!(root, @nested, @bytes)

      for mode <- [0o644, 0o640, 0o400, 0o700] do
        File.chmod!(leaf, mode)
        result = read_private(root, @nested, sha(@bytes), @max)

        assert result == refused(:file_mode),
               "mode #{Integer.to_string(mode, 8)}: #{inspect(result)}"
      end

      dir_leaf = Path.join([root, "receipts", "2026", "a-dir.json"])
      File.mkdir!(dir_leaf)

      assert read_private(root, "receipts/2026/a-dir.json", sha(@bytes), @max) ==
               refused(:not_regular)

      assert read_private(root, "receipts/2026/absent.json", sha(@bytes), @max) ==
               refused(:unreadable)

      refute_received {:read, _size}
    end
  end

  describe "synchronized races, with same-digest private copies" do
    test "the leaf's mode widened after the checks, before the open: refused before any byte",
         %{root: root} do
      leaf = tree!(root, @nested, @bytes)
      hook(:after_precheck, fn _path -> File.chmod!(leaf, 0o644) end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:file_mode)
      refute_received {:read, _size}, "the widened file's bytes were read"
    end

    test "the leaf's mode widened after the open, before its fstat: refused before any byte",
         %{root: root} do
      leaf = tree!(root, @nested, @bytes)
      hook(:after_open, fn _handle -> File.chmod!(leaf, 0o644) end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:file_mode)
      refute_received {:read, _size}, "the widened file's bytes were read"
    end

    test "the root replaced by a same-digest private copy after the checks: refused",
         %{root: root} do
      tree!(root, @nested, @bytes)

      hook(:after_precheck, fn _path ->
        File.rename!(root, Path.join(PrototypeFixtures.scratch_dir!(), "moved-root"))
        File.mkdir!(root)
        File.chmod!(root, 0o700)
        tree!(root, @nested, @bytes)
      end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:changed)
      refute_received {:read, _size}, "the substituted copy's bytes were read"
    end

    test "an ancestor replaced by a same-digest private copy after the checks: refused",
         %{root: root} do
      tree!(root, @nested, @bytes)
      receipts = Path.join(root, "receipts")

      hook(:after_precheck, fn _path ->
        File.rename!(receipts, Path.join(PrototypeFixtures.scratch_dir!(), "moved-receipts"))
        tree!(root, @nested, @bytes)
      end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:changed)
      refute_received {:read, _size}, "the substituted copy's bytes were read"
    end

    test "an ancestor swapped for a symlink to the original after the open: refused before any byte",
         %{root: root} do
      tree!(root, @nested, @bytes)
      receipts = Path.join(root, "receipts")

      # The opened leaf is the checked object; only the post-open recheck
      # of the directories can see that its ancestor is now a symlink.
      hook(:after_open, fn _handle ->
        moved = Path.join(PrototypeFixtures.scratch_dir!(), "receipts")
        File.rename!(receipts, moved)
        File.ln_s!(moved, receipts)
      end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:changed)
      refute_received {:read, _size}
    end

    test "growth after the identity check: the read stops at the bound plus one byte",
         %{root: root} do
      leaf = tree!(root, @nested, @bytes)

      hook(:after_identity, fn _handle ->
        File.write!(leaf, String.duplicate(" ", 65_536), [:append])
      end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:too_large)
      assert_received {:read, size}, "the checked handle was never read"
      assert size <= @max + 1, "read #{size} bytes, past the bound and its sentinel byte"
    end

    test "the one handle is closed on success and on every refusal after the open",
         %{root: root, test_pid: test_pid} do
      leaf = tree!(root, @nested, @bytes)
      hook(:after_open, fn handle -> send(test_pid, {:opened, handle}) end)

      assert_closed = fn label ->
        assert_received {:opened, handle}, "#{label}: no handle was opened"
        assert :file.read(handle, 1) == {:error, :einval}, "#{label}: the handle was left open"
      end

      assert read_private(root, @nested, sha(@bytes), @max) == {:ok, @bytes}
      assert_closed.("success")

      assert read_private(root, @nested, sha("other"), @max) == refused(:digest_mismatch)
      assert_closed.("digest mismatch")

      hook(:after_identity, fn _handle ->
        File.write!(leaf, String.duplicate(" ", 65_536), [:append])
      end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:too_large)
      assert_closed.("growth after the identity check")
      Process.delete({BoundedJson, :after_identity})

      File.write!(leaf, @bytes)

      hook(:after_open, fn handle ->
        send(test_pid, {:opened, handle})
        File.chmod!(leaf, 0o644)
      end)

      assert read_private(root, @nested, sha(@bytes), @max) == refused(:file_mode)
      assert_closed.("mode widened after the open")
    end
  end

  test "no refusal echoes the path or the bytes", %{root: root} do
    tree!(root, "receipts/#{@canary}.json", @bytes)
    result = read_private(root, "receipts/#{@canary}.json", sha("other"), @max)

    assert result == refused(:digest_mismatch)
    refute inspect(result) =~ @canary
  end
end
