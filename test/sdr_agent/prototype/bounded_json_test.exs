defmodule SdrAgent.Prototype.BoundedJsonTest do
  @moduledoc """
  The general parser rules of the D-237 private inputs (interfaces r6 IF-6
  "General parser rules", must-fix R3): bytes by digest, valid UTF-8,
  JSON syntax versus decoded content, the recursive duplicate-key and depth
  walk before any map conversion, the per-file minimum depth bounds, exact
  key sets, the dossier text rule without normalization, and value-free
  path errors. Synthetic inputs only.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.BoundedJson

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

      assert value_free!(BoundedJson.decode(nested, max_bytes: 1_024, max_depth: 7)) ==
               {:error, {"companies[1].contact", :duplicate_key}}
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
        assert match?(
                 {:ok, _},
                 BoundedJson.decode(nested(bound), max_bytes: 4_096, max_depth: bound)
               ),
               "#{file}: depth #{bound} was refused"

        assert match?(
                 {:error, {_path, :too_deep}},
                 BoundedJson.decode(nested(bound + 1), max_bytes: 4_096, max_depth: bound)
               ),
               "#{file}: depth #{bound + 1} was accepted"
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
      dir =
        Path.join(System.tmp_dir!(), "d237-bounded-json-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      %{dir: dir}
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
        assert BoundedJson.check_text(bad, min: 1, max: 600, multiline: true) ==
                 {:error, :control_character},
               "#{inspect(bad)} was accepted"
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
