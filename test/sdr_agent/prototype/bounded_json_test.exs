defmodule SdrAgent.Prototype.BoundedJsonTest do
  @moduledoc """
  The general parser rules of the D-237 private inputs (interfaces r6 IF-6
  "General parser rules", must-fix R3): bytes by digest, valid UTF-8,
  JSON syntax versus decoded content, the recursive duplicate-key and depth
  walk before any map conversion, the per-file minimum depth bounds, exact
  key sets, the dossier text rule without normalization, and value-free
  path errors. Synthetic inputs only.

  Codex 39a6fd61 additions:

  - error paths never name an arbitrary JSON key: a duplicate-key or depth
    error under a key outside the caller's `known_keys:` is reported at the
    parent of the first such key (the unknown-key rule), and Jason's error
    text is never returned; escaped-equivalent keys are duplicates;
  - `read_file/3` reads through ONE handle whose opened object must be the
    checked regular file (device and inode) before any byte is read, at
    most `max_bytes` plus one sentinel byte, closed on every path, hashing
    that one snapshot; the races are synchronized through the test-build
    hooks `{SdrAgent.Prototype.BoundedJson, name}` in the calling process's
    dictionary (`:after_precheck`, `:after_open`, `:after_identity`,
    `:after_read`), never by timing;
  - file fixtures live in exclusive, unpredictable, owned scratch roots
    (`SdrAgent.PrototypeFixtures.scratch_dir!/1`).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.BoundedJson
  alias SdrAgent.PrototypeFixtures

  @canary "CANARY-d237-json-5b1c"

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # A JSON value nested `depth` containers deep: objects keyed "k", the
  # innermost holding a scalar.
  defp nested(1), do: ~s({"k":1})
  defp nested(depth), do: ~s({"k":#{nested(depth - 1)}})

  defp value_free!(result) do
    refute inspect(result) =~ @canary, "an error echoed a value: #{inspect(result)}"
    result
  end

  describe "decode/2" do
    test "decodes to plain maps and lists, ignoring syntax whitespace" do
      bin = ~s( {\n\t"a" : [1, {"b": "x"}],\r\n "c": null } )

      assert BoundedJson.decode(bin, max_bytes: 1_024, max_depth: 3) ==
               {:ok, %{"a" => [1, %{"b" => "x"}], "c" => nil}}
    end

    test "decoded escapes (the pinned guide's newlines) are content, not syntax" do
      assert BoundedJson.decode(~s({"text":"line one\\nline two\\tend"}),
               max_bytes: 1_024,
               max_depth: 1
             ) ==
               {:ok, %{"text" => "line one\nline two\tend"}}
    end

    test "a repeated key is refused at any depth, with its path and no value" do
      root = ~s({"a":1,"a":"#{@canary}"})
      nested = ~s({"companies":[{"x":1},{"contact":{"name":"#{@canary}","name":"y"}}]})

      assert value_free!(BoundedJson.decode(root, max_bytes: 1_024, max_depth: 7)) ==
               {:error, {"(root)", :duplicate_key}}

      assert value_free!(
               BoundedJson.decode(nested,
                 max_bytes: 1_024,
                 max_depth: 7,
                 known_keys: ["companies", "contact"]
               )
             ) ==
               {:error, {"companies[1].contact", :duplicate_key}}
    end

    test "under a key outside known_keys, the error stops at that key's parent, unnamed" do
      opts = [max_bytes: 1_024, max_depth: 7, known_keys: ["companies", "contact", "k"]]

      duplicate_below = ~s({"companies":[{"#{@canary}":{"a":1,"a":2}}]})

      assert value_free!(BoundedJson.decode(duplicate_below, opts)) ==
               {:error, {"companies[0]", :duplicate_key}}

      duplicated = ~s({"companies":[{"#{@canary}":1,"#{@canary}":2}]})

      assert value_free!(BoundedJson.decode(duplicated, opts)) ==
               {:error, {"companies[0]", :duplicate_key}}

      too_deep_below = ~s({"#{@canary}":{"k":{"k":1}}})

      assert value_free!(BoundedJson.decode(too_deep_below, Keyword.put(opts, :max_depth, 2))) ==
               {:error, {"(root)", :too_deep}}

      indexed_below = ~s([{"#{@canary}":[[1]]}])

      assert value_free!(BoundedJson.decode(indexed_below, Keyword.put(opts, :max_depth, 3))) ==
               {:error, {"[0]", :too_deep}}
    end

    test "without known_keys every key is unknown: errors carry indices only" do
      nested = ~s({"companies":[{"contact":{"a":1,"a":2}}]})

      assert BoundedJson.decode(nested, max_bytes: 1_024, max_depth: 7) ==
               {:error, {"(root)", :duplicate_key}}

      assert BoundedJson.decode(~s([{"a":[[1]]}]), max_bytes: 1_024, max_depth: 3) ==
               {:error, {"[0]", :too_deep}}
    end

    test "escaped-equivalent keys are duplicates (compared after JSON unescaping)" do
      assert BoundedJson.decode(~S({"a":1,"a":2}), max_bytes: 1_024, max_depth: 1) ==
               {:error, {"(root)", :duplicate_key}}

      assert BoundedJson.decode(~S({"é":1,"é":2}), max_bytes: 1_024, max_depth: 1) ==
               {:error, {"(root)", :duplicate_key}}

      nested = ~S({"companies":[{"contact":{"name":1,"name":2}}]})

      assert BoundedJson.decode(nested,
               max_bytes: 1_024,
               max_depth: 7,
               known_keys: ["companies", "contact"]
             ) ==
               {:error, {"companies[0].contact", :duplicate_key}}
    end

    test "invalid JSON never returns Jason's error text (a canary key, an unterminated string)" do
      for bin <- [~s({"#{@canary}" 1}), ~s({"a":"#{@canary}), ~s({"#{@canary})] do
        assert value_free!(BoundedJson.decode(bin, max_bytes: 1_024, max_depth: 1)) ==
                 {:error, {"(root)", :invalid_json}}
      end
    end

    test "the root container is depth 1; each nested container adds 1; scalars do not" do
      assert match?(
               {:ok, _},
               BoundedJson.decode(~s([1, "two", null]), max_bytes: 64, max_depth: 1)
             )

      assert BoundedJson.decode(~s([[1]]), max_bytes: 64, max_depth: 1) ==
               {:error, {"[0]", :too_deep}}
    end

    test "each file's bound accepts its deepest valid path and refuses one level deeper" do
      for {file, bound} <- [
            dossier: 7,
            spotcheck_manifest: 3,
            provenance: 5,
            campaign: 4,
            offering_profile: 3,
            writing_guide: 1,
            budget_worksheet: 4
          ] do
        at_bound = BoundedJson.decode(nested(bound), max_bytes: 4_096, max_depth: bound)

        assert match?({:ok, _}, at_bound),
               "#{file}: depth #{bound} expected {:ok, _}, got #{inspect(at_bound)}"

        deeper = BoundedJson.decode(nested(bound + 1), max_bytes: 4_096, max_depth: bound)

        assert match?({:error, {_path, :too_deep}}, deeper),
               "#{file}: depth #{bound + 1} expected a :too_deep refusal, got #{inspect(deeper)}"
      end
    end

    test "oversize, invalid UTF-8 and invalid JSON are refused without echoing bytes" do
      assert BoundedJson.decode(String.duplicate(" ", 65) <> "{}", max_bytes: 64, max_depth: 1) ==
               {:error, {"(root)", :too_large}}

      assert value_free!(
               BoundedJson.decode(<<"{\"a\":\"", @canary, 0xFF, "\"}">>,
                 max_bytes: 1_024,
                 max_depth: 1
               )
             ) ==
               {:error, {"(root)", :invalid_utf8}}

      assert value_free!(
               BoundedJson.decode(~s({"a": #{@canary}}), max_bytes: 1_024, max_depth: 1)
             ) ==
               {:error, {"(root)", :invalid_json}}
    end
  end

  describe "read_file/3" do
    setup do
      %{dir: PrototypeFixtures.scratch_dir!()}
    end

    test "reads a regular file once when its full sha256 matches", %{dir: dir} do
      path = Path.join(dir, "input.json")
      File.write!(path, ~s({"a":1}))
      assert BoundedJson.read_file(path, sha(~s({"a":1})), 1_024) == {:ok, ~s({"a":1})}
    end

    test "refuses a digest mismatch, a symlink, a missing file and an oversize file", %{dir: dir} do
      path = Path.join(dir, "input.json")
      File.write!(path, ~s({"a":1}))
      link = Path.join(dir, "link.json")
      File.ln_s!(path, link)

      assert BoundedJson.read_file(path, sha("other"), 1_024) ==
               {:error, {"(file)", :digest_mismatch}}

      assert BoundedJson.read_file(link, sha(~s({"a":1})), 1_024) ==
               {:error, {"(file)", :not_regular}}

      assert BoundedJson.read_file(Path.join(dir, "absent.json"), sha(""), 1_024) ==
               {:error, {"(file)", :unreadable}}

      assert BoundedJson.read_file(path, sha(~s({"a":1})), 3) == {:error, {"(file)", :too_large}}
    end

    test "the byte limit is exact: max_bytes accepted, one byte more refused", %{dir: dir} do
      bytes = ~s({"a":1})
      path = Path.join(dir, "input.json")
      File.write!(path, bytes)

      assert BoundedJson.read_file(path, sha(bytes), byte_size(bytes)) == {:ok, bytes}

      assert BoundedJson.read_file(path, sha(bytes), byte_size(bytes) - 1) ==
               {:error, {"(file)", :too_large}}
    end
  end

  describe "read_file/3 under substitution and growth (synchronized test-build hooks)" do
    # Each hook runs inside read_file/3 at its named boundary (test builds
    # only), so every race happens at an exact point, with no timing:
    # :after_precheck (path) after the lstat checks and before the open;
    # :after_open (handle) right after the one open; :after_identity
    # (handle) after the opened object is checked against the precheck;
    # :after_read (bytes) with exactly the bytes read, before any check of
    # them. The hooks live in this test process's dictionary and die with it.
    @max 1_024

    setup do
      dir = PrototypeFixtures.scratch_dir!()
      bytes = ~s({"a":1})
      path = Path.join(dir, "input.json")
      File.write!(path, bytes)

      outside = PrototypeFixtures.scratch_dir!()
      target = Path.join(outside, "target.json")
      File.write!(target, ~s({"a":"SENTINEL-NEVER-READ #{@canary}"}))

      test_pid = self()

      hook(:after_read, fn read ->
        send(test_pid, {:read, byte_size(read), String.contains?(read, "SENTINEL-NEVER-READ")})
      end)

      %{dir: dir, path: path, bytes: bytes, target: target, test_pid: test_pid}
    end

    defp hook(name, fun), do: Process.put({BoundedJson, name}, fun)

    defp move_aside!(path),
      do: File.rename!(path, Path.join(PrototypeFixtures.scratch_dir!(), "moved.json"))

    test "the file swapped for a symlink after the precheck: refused, the target never read",
         ctx do
      hook(:after_precheck, fn path ->
        move_aside!(path)
        File.ln_s!(ctx.target, path)
      end)

      assert value_free!(BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max)) ==
               {:error, {"(file)", :changed}}

      refute_received {:read, _size, true}, "the symlink target's bytes were read"
    end

    test "the file replaced by another regular file after the precheck: refused before any read",
         ctx do
      hook(:after_precheck, fn path ->
        move_aside!(path)
        File.write!(path, String.duplicate(" ", 65_536) <> "{}")
      end)

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) ==
               {:error, {"(file)", :changed}}

      refute_received {:read, _size, _sentinel}, "the replacement's bytes were read"
    end

    test "the file grown past the bound after the precheck: refused, any read bounded", ctx do
      hook(:after_precheck, fn path ->
        File.write!(path, String.duplicate(" ", 65_536), [:append])
      end)

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) ==
               {:error, {"(file)", :too_large}}

      receive do
        {:read, size, _sentinel} ->
          assert size <= @max + 1, "read #{size} bytes, past the bound and its sentinel byte"
      after
        0 -> :ok
      end
    end

    test "the file grown past the bound after the identity check: the read stops at the bound plus one byte",
         ctx do
      hook(:after_identity, fn _handle ->
        File.write!(ctx.path, String.duplicate(" ", 65_536), [:append])
      end)

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) ==
               {:error, {"(file)", :too_large}}

      assert_received {:read, size, false}, "the checked handle was never read"
      assert size <= @max + 1, "read #{size} bytes, past the bound and its sentinel byte"
    end

    test "the digest is of the one read snapshot: replacing the path after the read changes nothing",
         ctx do
      hook(:after_read, fn read ->
        send(ctx.test_pid, {:read, byte_size(read), false})
        move_aside!(ctx.path)
        File.write!(ctx.path, ~s({"b":2}))
      end)

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) == {:ok, ctx.bytes}
      assert_received {:read, 7, false}
    end

    test "the one handle is closed on success and on every refusal after the open", ctx do
      hook(:after_open, fn handle -> send(ctx.test_pid, {:opened, handle}) end)

      assert_closed = fn label ->
        assert_received {:opened, handle}, "#{label}: read_file/3 reported no opened handle"

        assert :file.read(handle, 1) == {:error, :einval},
               "#{label}: the handle was left open"
      end

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) == {:ok, ctx.bytes}
      assert_closed.("success")

      assert BoundedJson.read_file(ctx.path, sha("other"), @max) ==
               {:error, {"(file)", :digest_mismatch}}

      assert_closed.("digest mismatch")

      hook(:after_identity, fn _handle ->
        File.write!(ctx.path, String.duplicate(" ", 65_536), [:append])
      end)

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) ==
               {:error, {"(file)", :too_large}}

      assert_closed.("growth after the identity check")

      Process.delete({BoundedJson, :after_identity})
      File.write!(ctx.path, ctx.bytes)

      hook(:after_precheck, fn path ->
        move_aside!(path)
        File.ln_s!(ctx.target, path)
      end)

      assert BoundedJson.read_file(ctx.path, sha(ctx.bytes), @max) ==
               {:error, {"(file)", :changed}}

      assert_closed.("symlink swap")
    end
  end

  describe "exact_keys/3 and format_path/1" do
    test "an unknown key is reported at the parent path without its name; a missing key too" do
      map = %{"name" => "x", @canary => 1}

      assert value_free!(BoundedJson.exact_keys(map, ["name"], ["companies", 3, "contact"])) ==
               {:error, {"companies[3].contact", :unknown_key}}

      assert BoundedJson.exact_keys(%{}, ["name"], ["companies", 3, "contact"]) ==
               {:error, {"companies[3].contact", :missing_key}}

      assert BoundedJson.exact_keys(%{"name" => "x"}, ["name"], []) == :ok
    end

    test "paths are segments with indices" do
      assert BoundedJson.format_path(["companies", 3, "contact", "evidence", "email"]) ==
               "companies[3].contact.evidence.email"

      assert BoundedJson.format_path([]) == "(root)"
      assert BoundedJson.format_path([0, "a"]) == "[0].a"
    end
  end

  describe "check_text/2 (the dossier text rule)" do
    test "accepts text within bounds; LF and TAB only when multiline" do
      assert BoundedJson.check_text("Acme Analytics", min: 1, max: 120) == :ok
      assert BoundedJson.check_text("line\nnext\tcol", min: 1, max: 600, multiline: true) == :ok

      assert BoundedJson.check_text("line\nnext", min: 1, max: 600) ==
               {:error, :control_character}
    end

    test "refuses C0, DEL, C1 and bidi controls, without normalizing first" do
      controls = [0x01, 0x0D, 0x7F, 0x85, 0x202E, 0x2066, 0x2069]

      for bad <- Enum.map(controls, &("a" <> <<&1::utf8>> <> "b")) do
        result = BoundedJson.check_text(bad, min: 1, max: 600, multiline: true)

        assert result == {:error, :control_character},
               "#{inspect(bad)}: expected {:error, :control_character}, got #{inspect(result)}"
      end
    end

    test "lengths are counted in characters; non-strings and invalid UTF-8 are refused" do
      assert BoundedJson.check_text(String.duplicate("é", 120), min: 1, max: 120) == :ok

      assert BoundedJson.check_text(String.duplicate("é", 121), min: 1, max: 120) ==
               {:error, :too_long}

      assert BoundedJson.check_text("", min: 1, max: 120) == {:error, :too_short}
      assert BoundedJson.check_text(<<0xFF>>, min: 1, max: 120) == {:error, :invalid_utf8}
      assert BoundedJson.check_text(12, min: 1, max: 120) == {:error, :not_a_string}
    end
  end
end
