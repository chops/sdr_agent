defmodule SdrAgent.Prototype.GtmSeedTest do
  @moduledoc """
  IF-7 GTM seed directory (interfaces r6; Codex seed-r4 flags 1-2; plan r7
  section 6 "GTM seed"): `SdrAgent.Prototype.SeedDir.read/2` over synthetic
  seed-directory fixtures of the exact four-file shape. The real seed r4
  bytes are never read here. The domain writes (`:seed_prototype`, the
  content rules, revision number 1, the provenance note) are in the seed
  write tests. Pure: no database.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.SeedDir

  @marker "ZZQMARKERZZ"

  defp contents, do: F.seed_contents()

  defp read({dir, hashes}), do: SeedDir.read(dir, hashes)

  defp with_file(name, fun), do: Map.update!(contents(), name, fun)

  defp refused!(result, path, rule) do
    assert result == {:error, {path, rule}},
           "expected the refusal {#{inspect(path)}, #{inspect(rule)}}, got #{inspect(result)}"

    refute inspect(result) =~ @marker, "the refusal echoed a value"
  end

  defp provenance_entry_index(name \\ "provenance.json", ref, seed) do
    {dir, _hashes} = seed
    entries = Path.join(dir, name) |> File.read!() |> Jason.decode!() |> Map.fetch!("entries")
    Enum.find_index(entries, &(&1["ref"] == ref))
  end

  test "the sender constant is the 17 bytes of IF-7" do
    assert SeedDir.sender_name() == "the GTMscape team"
    assert byte_size(SeedDir.sender_name()) == 17
  end

  describe "a valid seed directory" do
    test "reads the four documents and their digests" do
      {_dir, hashes} = seed = F.write_seed_dir!()
      assert {:ok, read} = read(seed)
      assert read.sha256 == hashes
      assert read.campaign["sender_name"] == "the GTMscape team"
      assert length(read.offering_profile["items"]) == 5
      assert is_binary(read.provenance_bytes)
      assert F.sha256(read.provenance_bytes) == hashes.provenance
    end

    test "public: false is accepted for the guide, the step, a limit, the audience and the ICP" do
      {dir, _} = seed = F.write_seed_dir!()
      assert match?({:ok, _}, read(seed))

      entries =
        Path.join(dir, "provenance.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("entries")

      private = for %{"public" => false, "ref" => ref} <- entries, do: ref

      assert Enum.sort(private) ==
               Enum.sort(~w(profile.audience guide campaign.icp campaign.step item:limit-one))
    end

    test "decoded newlines and tabs in the guide are kept for the content rules" do
      assert {:ok, read} = read(F.write_seed_dir!())
      assert read.writing_guide["text"] =~ "\n\tNever invent facts."
    end
  end

  describe "the directory and its files" do
    test "a directory that is not 0700 or a file that is not 0600 is refused" do
      refused!(read(F.write_seed_dir!(contents(), dir_mode: 0o755)), "seed_dir", :dir_mode)
      refused!(read(F.write_seed_dir!(contents(), file_mode: 0o644)), "campaign.json", :file_mode)
    end

    test "a missing or an extra file is refused" do
      {dir, hashes} = F.write_seed_dir!()
      File.rename!(Path.join(dir, "campaign.json"), Path.join(F.scratch_dir!(), "campaign.json"))
      refused!(SeedDir.read(dir, hashes), "campaign.json", :missing_file)

      {dir, hashes} = F.write_seed_dir!(contents(), extra: %{"notes.txt" => @marker})
      refused!(SeedDir.read(dir, hashes), "seed_dir", :unknown_entry)
    end

    test "a symlinked seed file is refused" do
      {dir, hashes} = F.write_seed_dir!()
      other = F.scratch_dir!()
      File.rename!(Path.join(dir, "writing_guide.json"), Path.join(other, "writing_guide.json"))
      File.ln_s!(Path.join(other, "writing_guide.json"), Path.join(dir, "writing_guide.json"))
      refused!(SeedDir.read(dir, hashes), "writing_guide.json", :not_regular)
    end

    test "any of the four digests other than its argument is refused" do
      {dir, hashes} = F.write_seed_dir!()

      for key <- [:offering_profile, :writing_guide, :campaign, :provenance] do
        file = "#{key}.json"

        refused!(
          SeedDir.read(dir, Map.put(hashes, key, F.sha256(@marker))),
          file,
          :digest_mismatch
        )
      end
    end

    test "a non-JSON file, a repeated JSON key or more than 64 KiB is refused" do
      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "campaign.json", "not json " <> @marker))),
        "campaign.json",
        :invalid_json
      )

      guide = ~s({"text":"Sign as the GTMscape team.","text":"#{@marker}"})

      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "writing_guide.json", guide))),
        "writing_guide.json",
        :duplicate_key
      )

      big = ~s({"text":"Sign as the GTMscape team.#{String.duplicate("a", 65_536)}"})

      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "writing_guide.json", big))),
        "writing_guide.json",
        :too_large
      )
    end

    test "invalid UTF-8 is refused at the file" do
      guide = ~s({"text":"Sign as the GTMscape team. ) <> <<0xFF, 0xFE>> <> ~s("})

      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "writing_guide.json", guide))),
        "writing_guide.json",
        :invalid_utf8
      )
    end

    test "nesting beyond each file's depth bound is refused" do
      deeper_campaign =
        with_file(
          "campaign.json",
          &F.put(&1, ["icp", "criteria", "industries"], [["B2B software"]])
        )

      refused!(
        read(F.write_seed_dir!(deeper_campaign)),
        "campaign.json:icp.criteria.industries[0]",
        :too_deep
      )

      deeper_profile =
        with_file(
          "offering_profile.json",
          &F.put(&1, ["items", 0, "text"], ["Routes synthetic loads."])
        )

      refused!(
        read(F.write_seed_dir!(deeper_profile)),
        "offering_profile.json:items[0].text",
        :too_deep
      )
    end
  end

  describe "exact key sets" do
    # Codex R2 (70679e0c): an invalid root shape is refused at the bare file
    # name (BoundedJson's root), never at "<file>:".
    test "a null, array or scalar root is refused at the file" do
      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "campaign.json", "null"))),
        "campaign.json",
        :null
      )

      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "writing_guide.json", "[]"))),
        "writing_guide.json",
        :type
      )

      profile =
        Map.merge(contents(), %{"offering_profile.json" => "1", "provenance.json" => "{}"})

      refused!(read(F.write_seed_dir!(profile)), "offering_profile.json", :type)

      refused!(
        read(F.write_seed_dir!(Map.put(contents(), "provenance.json", "null"))),
        "provenance.json",
        :null
      )
    end

    test "an unknown or missing key is refused without naming it" do
      refused!(
        read(F.write_seed_dir!(with_file("offering_profile.json", &Map.put(&1, @marker, "x")))),
        "offering_profile.json",
        :unknown_key
      )

      refused!(
        read(
          F.write_seed_dir!(
            with_file(
              "campaign.json",
              &F.update(&1, ["icp", "criteria"], fn c -> Map.delete(c, "personas") end)
            )
          )
        ),
        "campaign.json:icp.criteria",
        :missing_key
      )

      refused!(
        read(F.write_seed_dir!(with_file("writing_guide.json", &Map.put(&1, "sender", "x")))),
        "writing_guide.json",
        :unknown_key
      )
    end

    test "a provenance key inside the offering profile is refused" do
      refused!(
        read(
          F.write_seed_dir!(
            with_file(
              "offering_profile.json",
              &F.update(&1, ["items", 0], fn item -> Map.put(item, "public", true) end)
            )
          )
        ),
        "offering_profile.json:items[0]",
        :unknown_key
      )
    end

    test "an item kind outside the closed set or a repeated item id is refused" do
      refused!(
        read(
          F.write_seed_dir!(
            with_file("offering_profile.json", &F.put(&1, ["items", 0, "kind"], "pitch"))
          )
        ),
        "offering_profile.json:items[0].kind",
        :enum
      )

      refused!(
        read(
          F.write_seed_dir!(
            with_file("offering_profile.json", &F.put(&1, ["items", 1, "id"], "feature-one"))
          )
        ),
        "offering_profile.json:items[1].id",
        :duplicate
      )
    end

    test "the sequence is exactly one step object" do
      refused!(
        read(
          F.write_seed_dir!(
            with_file(
              "campaign.json",
              &F.update(&1, ["sequence"], fn s -> Map.put(s, "step", [s["step"], s["step"]]) end)
            )
          )
        ),
        "campaign.json:sequence.step",
        :type
      )

      refused!(
        read(
          F.write_seed_dir!(
            with_file(
              "campaign.json",
              &F.update(&1, ["sequence"], fn s -> Map.put(s, "steps", []) end)
            )
          )
        ),
        "campaign.json:sequence",
        :unknown_key
      )
    end
  end

  describe "the ICP criteria (content-bound strings)" do
    test "list and string bounds" do
      for {key, n} <- [{"industries", 6}, {"geographies", 6}, {"personas", 9}, {"triggers", 9}] do
        too_many =
          with_file("campaign.json", &F.put(&1, ["icp", "criteria", key], List.duplicate("x", n)))

        refused!(read(F.write_seed_dir!(too_many)), "campaign.json:icp.criteria.#{key}", :count)

        empty = with_file("campaign.json", &F.put(&1, ["icp", "criteria", key], []))
        refused!(read(F.write_seed_dir!(empty)), "campaign.json:icp.criteria.#{key}", :count)
      end

      long =
        with_file(
          "campaign.json",
          &F.put(&1, ["icp", "criteria", "triggers"], [String.duplicate("t", 401)])
        )

      refused!(read(F.write_seed_dir!(long)), "campaign.json:icp.criteria.triggers[0]", :length)

      at_bound =
        with_file(
          "campaign.json",
          &F.put(&1, ["icp", "criteria", "triggers"], [String.duplicate("t", 400)])
        )

      assert match?({:ok, _}, read(F.write_seed_dir!(at_bound)))
    end

    test "integer counts are at least 0" do
      negative =
        with_file("campaign.json", &F.put(&1, ["icp", "criteria", "employee_count_min"], -1))

      refused!(
        read(F.write_seed_dir!(negative)),
        "campaign.json:icp.criteria.employee_count_min",
        :range
      )

      fractional =
        with_file("campaign.json", &F.put(&1, ["icp", "criteria", "employee_count_max"], 50.5))

      refused!(
        read(F.write_seed_dir!(fractional)),
        "campaign.json:icp.criteria.employee_count_max",
        :type
      )
    end
  end

  describe "the sender (one 17-byte constant)" do
    test "a campaign sender_name other than the constant, in any casing, is refused" do
      for variant <- [
            "The GTMscape team",
            "the gtmscape team",
            "the GTMscape Team",
            "the GTMscape team ",
            @marker
          ] do
        refused!(
          read(
            F.write_seed_dir!(with_file("campaign.json", &Map.put(&1, "sender_name", variant)))
          ),
          "campaign.json:sender_name",
          :sender
        )
      end
    end

    test "a guide without the exact sender bytes is refused" do
      for text <- [
            "Sign as The GTMscape Team.",
            "Sign as the gtmscape team.",
            "Sign as GTMscape."
          ] do
        refused!(
          read(F.write_seed_dir!(Map.put(contents(), "writing_guide.json", %{"text" => text}))),
          "writing_guide.json:text",
          :sender
        )
      end
    end
  end

  describe "provenance" do
    test "a files digest other than its file's is refused" do
      seed = F.write_seed_dir!()
      {dir, hashes} = seed

      prov =
        Path.join(dir, "provenance.json")
        |> File.read!()
        |> Jason.decode!()
        |> F.put(["files", "campaign"], F.sha256(@marker))

      bin = F.encode(prov)
      F.write!(dir, "provenance.json", bin)

      refused!(
        SeedDir.read(dir, %{hashes | provenance: F.sha256(bin)}),
        "provenance.json:files.campaign",
        :files_digest
      )
    end

    test "a missing, duplicated or unknown ref is refused" do
      edit = fn fun ->
        {dir, hashes} = F.write_seed_dir!()
        prov = Path.join(dir, "provenance.json") |> File.read!() |> Jason.decode!() |> fun.()
        bin = F.encode(prov)
        F.write!(dir, "provenance.json", bin)
        SeedDir.read(dir, %{hashes | provenance: F.sha256(bin)})
      end

      refused!(
        edit.(
          &F.update(&1, ["entries"], fn es -> Enum.reject(es, fn e -> e["ref"] == "guide" end) end)
        ),
        "provenance.json:entries",
        :ref_missing
      )

      n =
        length(
          F.provenance(%{
            "offering_profile.json" => "",
            "writing_guide.json" => "",
            "campaign.json" => ""
          })["entries"]
        )

      refused!(
        edit.(&F.update(&1, ["entries"], fn es -> es ++ [hd(es)] end)),
        "provenance.json:entries[#{n}].ref",
        :ref_duplicate
      )

      refused!(
        edit.(&F.put(&1, ["entries", 0, "ref"], "item:absent")),
        "provenance.json:entries[0].ref",
        :ref_unknown
      )

      refused!(
        edit.(&F.put(&1, ["entries", 0, "ref"], "sender")),
        "provenance.json:entries[0].ref",
        :ref_unknown
      )
    end

    test "a claim-class ref must be public with public_url sources only" do
      # A fresh seed directory per case, with one provenance entry edited.
      edit = fn ref, fun ->
        {dir, hashes} = seed = F.write_seed_dir!()
        i = provenance_entry_index(ref, seed)

        prov =
          Path.join(dir, "provenance.json")
          |> File.read!()
          |> Jason.decode!()
          |> F.update(["entries", i], fun)

        bin = F.encode(prov)
        F.write!(dir, "provenance.json", bin)
        {i, SeedDir.read(dir, %{hashes | provenance: F.sha256(bin)})}
      end

      for ref <- [
            "profile.name",
            "profile.summary",
            "item:feature-one",
            "item:use-case-one",
            "item:outcome-one",
            "item:proof-one"
          ] do
        {i, result} = edit.(ref, &Map.put(&1, "public", false))
        refused!(result, "provenance.json:entries[#{i}].public", :claim_not_public)
      end

      repo = %{
        "kind" => "repo_path",
        "ref" => "#{String.duplicate("cd", 20)}:docs/x.md",
        "retrieved_on" => "2026-10-20"
      }

      {i, result} =
        edit.(
          "item:feature-one",
          &Map.update!(&1, "sources", fn sources -> sources ++ [repo] end)
        )

      refused!(result, "provenance.json:entries[#{i}].sources[1].kind", :public_source)
    end

    test "public: true needs at least one source, every one public_url" do
      seed = F.write_seed_dir!()
      {dir, hashes} = seed
      i = provenance_entry_index("item:limit-one", seed)

      public_limit =
        Path.join(dir, "provenance.json")
        |> File.read!()
        |> Jason.decode!()
        |> F.put(["entries", i, "public"], true)

      bin = F.encode(public_limit)
      F.write!(dir, "provenance.json", bin)

      refused!(
        SeedDir.read(dir, %{hashes | provenance: F.sha256(bin)}),
        "provenance.json:entries[#{i}].sources[0].kind",
        :public_source
      )

      no_sources = F.put(public_limit, ["entries", i, "sources"], [])
      bin = F.encode(no_sources)
      F.write!(dir, "provenance.json", bin)

      refused!(
        SeedDir.read(dir, %{hashes | provenance: F.sha256(bin)}),
        "provenance.json:entries[#{i}].sources",
        :count
      )
    end
  end

  test "no code evaluation on the seed or dossier path (source check)" do
    for file <- ~w(seed_dir.ex dossier_parser.ex spotcheck_manifest.ex) do
      source = File.read!(Path.join("lib/sdr_agent/prototype", file))

      refute source =~
               ~r/Code\.eval|Code\.compile|:erlang\.binary_to_term|String\.to_atom|:os\.cmd/,
             "#{file} evaluates input"
    end
  end

  describe "seed reads under substitution (Codex R4; synchronized test seams)" do
    # The hooks run inside SeedDir.read/2 at its named boundaries (test-seam
    # build only); each test acts at an exact point, with no timing.
    setup do
      {dir, hashes} = F.write_seed_dir!()
      test_pid = self()

      hook(:after_read, fn {name, bytes} -> send(test_pid, {:read, name, byte_size(bytes)}) end)

      %{dir: dir, hashes: hashes}
    end

    test "the root replaced by a symlink after the precheck: refused, nothing under it read",
         ctx do
      hook(:after_precheck, fn dir ->
        outside = F.scratch_dir!()
        for name <- SeedDir.files(), do: F.write!(outside, name, File.read!(Path.join(dir, name)))
        File.rename!(dir, Path.join(F.scratch_dir!(), "moved-root"))
        File.ln_s!(outside, dir)
      end)

      refused!(SeedDir.read(ctx.dir, ctx.hashes), "seed_dir", :changed)
      refute_received {:read, _name, _size}, "a file was read under the substituted root"
    end

    test "the root widened to 0755 after the precheck: refused before any content is read", ctx do
      hook(:after_precheck, fn dir -> File.chmod!(dir, 0o755) end)

      refused!(SeedDir.read(ctx.dir, ctx.hashes), "seed_dir", :dir_mode)
      refute_received {:read, _name, _size}, "content was read under a widened root"
    end

    test "a file widened to 0644 after the precheck: refused before its content is read", ctx do
      hook(:after_precheck, fn dir -> File.chmod!(Path.join(dir, "writing_guide.json"), 0o644) end)

      refused!(SeedDir.read(ctx.dir, ctx.hashes), "writing_guide.json", :file_mode)
      refute_received {:read, "writing_guide.json", _size}, "the widened file was read"
    end

    test "control: a file replaced by a symlink after the precheck is refused, the target never read",
         ctx do
      hook(:after_precheck, fn dir ->
        path = Path.join(dir, "writing_guide.json")
        outside = F.scratch_dir!()
        target = F.write!(outside, "writing_guide.json", File.read!(path))
        File.rename!(path, Path.join(outside, "moved.json"))
        File.ln_s!(target, path)
      end)

      refused!(SeedDir.read(ctx.dir, ctx.hashes), "writing_guide.json", :not_regular)
      refute_received {:read, "writing_guide.json", _size}, "the symlink target was read"
    end

    test "control: a file grown past 64 KiB after the precheck is refused unread", ctx do
      hook(:after_precheck, fn dir ->
        File.write!(Path.join(dir, "writing_guide.json"), String.duplicate(" ", 65_536), [:append])
      end)

      refused!(SeedDir.read(ctx.dir, ctx.hashes), "writing_guide.json", :too_large)
      refute_received {:read, "writing_guide.json", _size}, "the grown file was read"
    end

    test "a file grown past 64 KiB after it is opened: the read stops at the bound plus one byte",
         ctx do
      hook(:after_open, fn {name, _handle} ->
        if name == "writing_guide.json",
          do: File.write!(Path.join(ctx.dir, name), String.duplicate(" ", 131_072), [:append])
      end)

      refused!(SeedDir.read(ctx.dir, ctx.hashes), "writing_guide.json", :too_large)
      assert_received {:read, "writing_guide.json", size}, "the opened handle was never read"
      assert size <= 65_537, "read #{size} bytes, past the bound and its sentinel byte"
    end

    test "each file is read through one handle, closed on success and on refusal", ctx do
      test_pid = self()
      hook(:after_open, fn {name, handle} -> send(test_pid, {:opened, name, handle}) end)

      assert match?({:ok, _}, SeedDir.read(ctx.dir, ctx.hashes))

      for name <- Enum.sort(SeedDir.files()) do
        assert_received {:opened, ^name, handle}, "#{name} was read through no reported handle"
        assert :file.read(handle, 1) == {:error, :einval}, "#{name}'s handle was left open"
      end

      bad = Map.put(ctx.hashes, :writing_guide, F.sha256("other"))
      refused!(SeedDir.read(ctx.dir, bad), "writing_guide.json", :digest_mismatch)
      assert_received {:opened, "writing_guide.json", handle}

      assert :file.read(handle, 1) == {:error, :einval},
             "the handle was left open after a refusal"
    end
  end

  defp hook(name, fun), do: Process.put({SeedDir, name}, fun)
end
