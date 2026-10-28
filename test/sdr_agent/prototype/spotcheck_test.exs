defmodule SdrAgent.Prototype.SpotcheckTest do
  @moduledoc """
  IF-6 spot-check manifest `sdr-agent.prototype-spotcheck` v1 and retained
  artifacts (interfaces r6; plan r7 section 6, "Manifest" and "Artifacts"):
  a result is identified by `(row_id, item)` and bound to exactly that
  claim's or fact's source and final URL; the whole manifest is refused on
  any identity, duplicate or relation violation; a missing result makes a
  selected row not importable. Synthetic fixtures only; pure.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.DossierParser
  alias SdrAgent.Prototype.SpotcheckManifest

  @marker "ZZQMARKERZZ"

  setup do
    dossier = F.dossier([F.company(1), F.company(2)])
    bin = F.encode(dossier)
    sha = F.sha256(bin)
    %{dossier: dossier, sha: sha, manifest: F.manifest({dossier, sha})}
  end

  defp parse(manifest, %{dossier: dossier, sha: sha}),
    do: SpotcheckManifest.parse(F.encode(manifest), dossier, sha)

  defp refused!(result, path, rule) do
    assert result == {:error, {path, rule}},
           "expected the refusal {#{inspect(path)}, #{inspect(rule)}}, got #{inspect(result)}"

    refute inspect(result) =~ @marker, "the refusal echoed a value"
  end

  defp results(manifest, fun), do: Map.update!(manifest, "results", fun)

  defp raw(bin, ctx), do: SpotcheckManifest.parse(bin, ctx.dossier, ctx.sha)

  defp index(manifest, row_id, item),
    do: Enum.find_index(manifest["results"], &(&1["row_id"] == row_id and &1["item"] == item))

  describe "a valid manifest" do
    test "parses, keyed by (row_id, item), and keeps its own sha256", ctx do
      bin = F.encode(ctx.manifest)
      assert {:ok, parsed} = SpotcheckManifest.parse(bin, ctx.dossier, ctx.sha)
      assert parsed.sha256 == F.sha256(bin)

      assert %{"result" => "verified", "relation" => "person_address_linked"} =
               parsed.results[{"row-1", "claim:email"}]

      assert map_size(parsed.results) == length(ctx.manifest["results"])
    end

    test "read/3 reads by full sha256 and refuses another digest", ctx do
      dir = F.scratch_dir!()
      bin = F.encode(ctx.manifest)
      path = F.write!(dir, "spotcheck.json", bin)

      assert match?(
               {:ok, %{results: %{}}},
               SpotcheckManifest.read(path, F.sha256(bin), {ctx.dossier, ctx.sha})
             )

      refused!(
        SpotcheckManifest.read(path, F.sha256("x"), {ctx.dossier, ctx.sha}),
        "(file)",
        :digest_mismatch
      )
    end
  end

  # S1 BoundedJson's reviewed contract through the manifest routes (Codex
  # R1): exact paths and rules, never a value.
  describe "the shared decoder and file bounds" do
    test "a repeated key at the root or inside a result", ctx do
      bin = F.encode(ctx.manifest)

      top =
        String.replace(bin, ~s("schema_version":1), ~s("schema_version":1,"schema_version":1),
          global: false
        )

      assert top != bin
      refused!(raw(top, ctx), "(root)", :duplicate_key)

      nested =
        String.replace(
          bin,
          ~s("result":"verified"),
          ~s("result":"verified","result":"#{@marker}"),
          global: false
        )

      assert nested != bin
      refused!(raw(nested, ctx), "results[0]", :duplicate_key)
    end

    test "invalid UTF-8", ctx do
      bin =
        String.replace(F.encode(ctx.manifest), "research-test", <<"research-", 0xFF, 0xFE>>,
          global: false
        )

      refused!(raw(bin, ctx), "(root)", :invalid_utf8)
    end

    test "depth 3 (a result's fields) parses; a container below it is refused", ctx do
      assert match?({:ok, _}, raw(F.encode(ctx.manifest), ctx))

      deeper =
        results(ctx.manifest, fn [first | rest] -> [%{first | "relation" => [nil]} | rest] end)

      refused!(parse(deeper, ctx), "results[0].relation", :too_deep)
    end

    test "more than 64 KiB: refused by parse/3 and by read/3", ctx do
      bin = F.encode(ctx.manifest)
      big = bin <> String.duplicate(" ", 65_536 - byte_size(bin) + 1)
      refused!(raw(big, ctx), "(root)", :too_large)

      dir = F.scratch_dir!()
      path = F.write!(dir, "spotcheck.json", big)

      refused!(
        SpotcheckManifest.read(path, F.sha256(big), {ctx.dossier, ctx.sha}),
        "(file)",
        :too_large
      )
    end
  end

  describe "the whole manifest is refused" do
    test "on a wrong schema, version or dossier digest", ctx do
      refused!(parse(Map.put(ctx.manifest, "schema", @marker), ctx), "schema", :schema)

      refused!(
        parse(Map.put(ctx.manifest, "schema_version", 2), ctx),
        "schema_version",
        :schema_version
      )

      refused!(
        parse(Map.put(ctx.manifest, "dossier_sha256", F.sha256(@marker)), ctx),
        "dossier_sha256",
        :dossier_mismatch
      )
    end

    test "on a checker outside its pattern", ctx do
      refused!(
        parse(Map.put(ctx.manifest, "checker", "tool;" <> @marker), ctx),
        "checker",
        :format
      )
    end

    test "on a checked_at without an offset", ctx do
      i = index(ctx.manifest, "row-1", "claim:name")
      manifest = F.put(ctx.manifest, ["results", i, "checked_at"], "2026-10-27T10:00:00")
      refused!(parse(manifest, ctx), "results[#{i}].checked_at", :format)
    end

    test "on an unknown row or item", ctx do
      refused!(
        parse(F.put(ctx.manifest, ["results", 0, "row_id"], "row-9"), ctx),
        "results[0].row_id",
        :unknown_row
      )

      for item <- ["claim:phone", "fact:f9", "fact:f4", "row"] do
        refused!(
          parse(F.put(ctx.manifest, ["results", 0, "item"], item), ctx),
          "results[0].item",
          :unknown_item
        )
      end
    end

    test "on a result naming another source or URL than its claim's or fact's", ctx do
      i = index(ctx.manifest, "row-1", "claim:email")

      refused!(
        parse(F.put(ctx.manifest, ["results", i, "source_id"], "s2"), ctx),
        "results[#{i}].source_id",
        :source_mismatch
      )

      refused!(
        parse(
          F.put(ctx.manifest, ["results", i, "final_url"], "https://www.acme1.test/about"),
          ctx
        ),
        "results[#{i}].final_url",
        :url_mismatch
      )
    end

    test "on a duplicate (row_id, item), with an equal or a conflicting status", ctx do
      i = index(ctx.manifest, "row-2", "claim:role")
      dup = Enum.at(ctx.manifest["results"], i)
      n = length(ctx.manifest["results"])

      refused!(parse(results(ctx.manifest, &(&1 ++ [dup])), ctx), "results[#{n}]", :duplicate)

      refused!(
        parse(results(ctx.manifest, &(&1 ++ [Map.put(dup, "result", "conflict")])), ctx),
        "results[#{n}]",
        :duplicate
      )
    end

    test "on a relation on the wrong item", ctx do
      cases = [
        {"row-1", "claim:role", "person_address_linked"},
        {"row-1", "claim:name", "person_role_current"},
        {"row-1", "claim:email", "company_size_stated"},
        {"row-1", "fact:f2", "company_size_stated"},
        {"row-1", "fact:f1", "company_location_stated"},
        {"row-1", "fact:f3", "company_size_stated"},
        {"row-1", "claim:name", "person_address_linked"}
      ]

      for {row, item, relation} <- cases do
        i = index(ctx.manifest, row, item)

        refused!(
          parse(F.put(ctx.manifest, ["results", i, "relation"], relation), ctx),
          "results[#{i}].relation",
          :relation
        )
      end
    end

    test "on an empty result list or more than 200 results", ctx do
      refused!(parse(Map.put(ctx.manifest, "results", []), ctx), "results", :count)
    end
  end

  describe "a missing result makes the selected row not importable" do
    test "a missing claim or fact result refuses the selection before writes", ctx do
      dir = F.scratch_dir!()

      for {item, reason} <- [
            {"claim:email", :link_unconfirmed},
            {"claim:role", :role_unconfirmed},
            {"claim:name", :insufficient_source},
            {"fact:f1", :insufficient_source},
            {"fact:f3", :insufficient_source}
          ] do
        manifest =
          results(ctx.manifest, fn rs ->
            Enum.reject(rs, &(&1["row_id"] == "row-1" and &1["item"] == item))
          end)

        parsed = F.parsed_manifest(manifest)

        result = DossierParser.select(ctx.dossier, parsed, ["row-1"], dir)

        assert result == {:error, {"companies[0]", reason}},
               "a missing #{item} result did not refuse the selection: #{inspect(result)}"

        assert DossierParser.eligibility(ctx.dossier, parsed, "row-1", dir) ==
                 {:error, {"companies[0]", reason}}
      end
    end

    test "a not_found or unreachable result counts as unconfirmed; a conflict result as source_conflict",
         ctx do
      dir = F.scratch_dir!()
      i = index(ctx.manifest, "row-1", "claim:email")

      for {status, reason} <- [
            {"not_found", :link_unconfirmed},
            {"unreachable", :link_unconfirmed},
            {"conflict", :source_conflict}
          ] do
        parsed = F.parsed_manifest(F.put(ctx.manifest, ["results", i, "result"], status))

        assert DossierParser.select(ctx.dossier, parsed, ["row-1"], dir) ==
                 {:error, {"companies[0]", reason}}
      end
    end
  end

  describe "artifacts" do
    setup ctx do
      dir = F.scratch_dir!()
      bytes = "Team page copy. Jordan Testperson: jordan@acme1.test. Thanks."
      ref = F.artifact!(dir, "s1-team.txt", bytes)
      Map.merge(ctx, %{dir: dir, ref: ref, bytes: bytes})
    end

    test "a valid artifact is read by its sha256", ctx do
      assert SpotcheckManifest.artifact(ctx.dir, ctx.ref) == {:ok, ctx.bytes}
    end

    test "missing, wrong hash, symlink, not 0600, over 1 MiB, not UTF-8, or a wide directory → refused",
         ctx do
      refused!(
        SpotcheckManifest.artifact(ctx.dir, %{ctx.ref | "file" => "absent.txt"}),
        "artifact",
        :artifact_invalid
      )

      refused!(
        SpotcheckManifest.artifact(ctx.dir, %{ctx.ref | "sha256" => F.sha256(@marker)}),
        "artifact",
        :artifact_invalid
      )

      File.ln_s!(Path.join(ctx.dir, "s1-team.txt"), Path.join(ctx.dir, "link.txt"))

      refused!(
        SpotcheckManifest.artifact(ctx.dir, %{ctx.ref | "file" => "link.txt"}),
        "artifact",
        :artifact_invalid
      )

      wide = F.artifact!(ctx.dir, "wide.txt", ctx.bytes <> " ", 0o644)
      refused!(SpotcheckManifest.artifact(ctx.dir, wide), "artifact", :artifact_invalid)

      big = F.artifact!(ctx.dir, "big.txt", String.duplicate("a", 1_048_577))
      refused!(SpotcheckManifest.artifact(ctx.dir, big), "artifact", :artifact_invalid)

      binary = F.artifact!(ctx.dir, "bin.txt", <<0xFF, 0xFE, 0x00>>)
      refused!(SpotcheckManifest.artifact(ctx.dir, binary), "artifact", :artifact_invalid)

      wide_dir = F.scratch_dir!(0o755)
      ref = F.artifact!(wide_dir, "s1-team.txt", ctx.bytes)
      refused!(SpotcheckManifest.artifact(wide_dir, ref), "artifact", :artifact_invalid)
    end

    test "the basename grammar is enforced by artifact/2 itself (ruling R4)", ctx do
      # A sibling artifact one level up, so a traversal would find real bytes.
      outer = F.scratch_dir!()
      inner = Path.join(outer, "inner")
      File.mkdir!(inner)
      File.chmod!(inner, 0o700)
      up = F.artifact!(outer, "up.txt", ctx.bytes)
      nested_dir = Path.join(ctx.dir, "sub")
      File.mkdir!(nested_dir)
      File.chmod!(nested_dir, 0o700)
      F.write!(nested_dir, "s1-team.txt", ctx.bytes)

      for file <- [
            "../up.txt",
            Path.join(outer, "up.txt"),
            "sub/s1-team.txt",
            "sub\\s1-team.txt",
            ".s1-team.txt",
            "S1-TEAM.txt",
            "",
            String.duplicate("a", 65)
          ] do
        refused!(
          SpotcheckManifest.artifact(inner, %{"file" => file, "sha256" => up["sha256"]}),
          "artifact",
          :artifact_invalid
        )

        refused!(
          SpotcheckManifest.artifact(ctx.dir, %{ctx.ref | "file" => file}),
          "artifact",
          :artifact_invalid
        )
      end
    end

    test "a symlinked artifacts root is refused (ruling R4)", ctx do
      link = Path.join(F.scratch_dir!(), "root-link")
      File.ln_s!(ctx.dir, link)
      refused!(SpotcheckManifest.artifact(link, ctx.ref), "artifact", :artifact_invalid)
    end

    test "a malformed reference is refused, not raised", ctx do
      for ref <- [
            %{},
            %{"file" => "s1-team.txt"},
            %{"file" => 1, "sha256" => ctx.ref["sha256"]},
            nil
          ] do
        refused!(SpotcheckManifest.artifact(ctx.dir, ref), "artifact", :artifact_invalid)
      end
    end

    test "a file of exactly 1 MiB is read; the bound is inclusive", ctx do
      bytes = String.duplicate("a", 1_048_576)
      ref = F.artifact!(ctx.dir, "exact.txt", bytes)
      assert SpotcheckManifest.artifact(ctx.dir, ref) == {:ok, bytes}
    end

    test "a selected row whose claim names an invalid artifact is refused", ctx do
      row =
        F.put(F.company(1), ["contact", "evidence", "email", "artifact"], %{
          ctx.ref
          | "sha256" => F.sha256("other")
        })

      dossier = F.dossier([row])
      sha = F.sha256(F.encode(dossier))
      parsed = F.parsed_manifest(F.manifest({dossier, sha}))

      assert DossierParser.select(dossier, parsed, ["row-1"], ctx.dir) ==
               {:error, {"companies[0].contact.evidence.email.artifact", :artifact_invalid}}
    end
  end

  describe "artifact reads under substitution (Codex GREEN-1 R1; synchronized test seams)" do
    # The hooks run inside artifact/2 at its named boundaries (test-seam build
    # only); each test acts at an exact point, with no timing.
    setup ctx do
      dir = F.scratch_dir!()
      bytes = "Team page copy. Jordan Testperson: jordan@acme1.test. Thanks."
      ref = F.artifact!(dir, "s1-team.txt", bytes)
      sentinel = "SENTINEL-NEVER-READ " <> @marker
      outside = F.scratch_dir!()
      target = F.write!(outside, "s1-team.txt", sentinel)
      test_pid = self()

      record = fn bytes ->
        send(test_pid, {:read, byte_size(bytes), String.contains?(bytes, "SENTINEL-NEVER-READ")})
      end

      on_exit(fn ->
        for n <- [:after_precheck, :after_open, :after_read],
            do: Process.delete({SpotcheckManifest, n})
      end)

      Map.merge(ctx, %{
        dir: dir,
        ref: ref,
        bytes: bytes,
        outside: outside,
        target: target,
        record: record
      })
    end

    defp hook(name, fun), do: Process.put({SpotcheckManifest, name}, fun)

    test "the file replaced by a symlink after the precheck: refused, the target never read",
         ctx do
      hook(:after_read, ctx.record)

      hook(:after_precheck, fn path ->
        File.rename!(path, Path.join(F.scratch_dir!(), "moved.txt"))
        File.ln_s!(ctx.target, path)
      end)

      refused!(SpotcheckManifest.artifact(ctx.dir, ctx.ref), "artifact", :artifact_invalid)
      refute_received {:read, _size, true}, "the substituted target's bytes were read"
    end

    test "the root widened to 0755 after the precheck: refused before any content is read", ctx do
      hook(:after_read, ctx.record)
      hook(:after_precheck, fn _path -> File.chmod!(ctx.dir, 0o755) end)

      refused!(SpotcheckManifest.artifact(ctx.dir, ctx.ref), "artifact", :artifact_invalid)
      refute_received {:read, _size, _sentinel}, "content was read under a widened root"
    end

    test "the root replaced by a symlink after the precheck: refused, the target never read",
         ctx do
      hook(:after_read, ctx.record)

      hook(:after_precheck, fn _path ->
        File.rename!(ctx.dir, Path.join(F.scratch_dir!(), "moved-root"))
        File.ln_s!(ctx.outside, ctx.dir)
      end)

      refused!(SpotcheckManifest.artifact(ctx.dir, ctx.ref), "artifact", :artifact_invalid)
      refute_received {:read, _size, true}, "bytes under the substituted root were read"
    end

    test "the file grown past the bound after the precheck: refused with a bounded read", ctx do
      hook(:after_read, ctx.record)

      hook(:after_precheck, fn path ->
        File.write!(path, String.duplicate("g", 2_097_152), [:append])
      end)

      refused!(SpotcheckManifest.artifact(ctx.dir, ctx.ref), "artifact", :artifact_invalid)

      receive do
        {:read, size, _} ->
          assert size <= 1_048_577, "read #{size} bytes, past the bound and its sentinel byte"
      after
        0 -> :ok
      end
    end

    test "the file grown past the bound after it is opened: the read stops at the bound plus one byte",
         ctx do
      hook(:after_read, ctx.record)

      hook(:after_open, fn _handle ->
        File.write!(Path.join(ctx.dir, "s1-team.txt"), String.duplicate("g", 2_097_152), [:append])
      end)

      refused!(SpotcheckManifest.artifact(ctx.dir, ctx.ref), "artifact", :artifact_invalid)
      assert_received {:read, size, false}, "the opened handle was never read"
      assert size <= 1_048_577, "read #{size} bytes, past the bound and its sentinel byte"
    end

    test "the one handle is closed on success and on refusal", ctx do
      test_pid = self()
      hook(:after_open, fn handle -> send(test_pid, {:opened, handle}) end)

      assert SpotcheckManifest.artifact(ctx.dir, ctx.ref) == {:ok, ctx.bytes}
      assert_received {:opened, handle}, "artifact/2 read through no reported handle"

      assert :file.read(handle, 1) == {:error, :einval},
             "the handle was left open after a success"

      bad = %{ctx.ref | "sha256" => F.sha256("other")}
      refused!(SpotcheckManifest.artifact(ctx.dir, bad), "artifact", :artifact_invalid)
      assert_received {:opened, handle}

      assert :file.read(handle, 1) == {:error, :einval},
             "the handle was left open after a refusal"
    end
  end
end
