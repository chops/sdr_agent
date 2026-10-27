defmodule SdrAgent.Workflow.ProjectFactsReceiptRevisionTest do
  @moduledoc """
  ADR-0019 condition C4 (accepted as D-229): the reviewed drift canary for
  the project-local revision of the factory receipt's
  `.workflow/project-facts.md` unit (plan
  `claude-c2star-s1-environment-plan-r2.md` section 8 item 7).

    * **A1** — the owned units carrying `local_revision` are exactly
      {`template-project-facts`}, whose `lifecycle`, `operation` and
      `operation_version` are `seed_once`, `render` and 1.
    * **A2** — `local_revision` equals the complete C2 literal as a JSON
      value; `revised_sha256 == unit sha256 == sha256(facts bytes)`; the
      `adr` path exists. Every changed leaf value, and a missing and an
      extra key at each level, is rejected.
    * **A3** — the original receipt is read from git object
      `eccbe8fa…:.workflow/receipt.json`, its sha256 verified before it is
      decoded (no fetch fallback). The current receipt, with the revised
      unit's `sha256` set to its own `local_revision.original_generation.sha256`
      and `local_revision` deleted, equals it as a JSON value. Missing
      provenance fails; no test literal stands in for it.
    * **A4** — each case on its own fresh copy of the tracked tree
      (`git ls-files -z`, symlinks and modes preserved) under the test's
      `tmp_dir`, never writing through a link or into a tracked file. (i)
      Before each case the copy's receipt and facts must hash to the reviewed
      pins (the whole revised receipt file, which only ADR-0019 C6 may
      replace, and `80fc3e55…`). (ii) The copy's own `bin/verify-workflow`
      runs with a timeout: unchanged, exit 0 and `workflow receipt: ok`; a
      byte appended to the facts, or the original factory facts (git object
      `eccbe8fa…:.workflow/project-facts.md`, sha256 `cc0ab2de…` verified
      first), exit 1 with exactly the drift message; only `local_revision`
      removed, exit 0 (the metadata is documentary, by design), and A1, A2
      and A3 each reject that receipt.

  It never skips: a missing input (git, a git object, the validator,
  `elixir`) fails. It needs git, the copied tree and the validator only: no
  network, service or database. No other unit's metadata is asserted beyond
  A3's equality.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @unit ".workflow/project-facts.md"
  @receipt ".workflow/receipt.json"
  @artifact "template-project-facts"
  @scaffold "eccbe8fa9b35156206b0387fcc5449c10ad034f4"
  @original_receipt_sha256 "26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475"
  @original_facts_sha256 "cc0ab2de09dd3f41e320bb4a92e927b1a022bd88a3fa00638f747039598b2d17"
  @revised_facts_sha256 "80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c"
  # A4 (i): the reviewed whole revised receipt file, the ADR-0019 one-unit
  # delta applied to the original receipt. Only ADR-0019 C6 may replace it.
  @revised_receipt_sha256 "ca002d060d92e554de707d5f9b06e422a9de055b9963115e4dc5bc482f433ebf"
  @drift "drifted from installed receipt: owned unit differs: .workflow/project-facts.md\n"
  @ok "workflow receipt: ok\n"
  @validator_timeout_ms 120_000

  # ADR-0019 C2, in full.
  @local_revision %{
    "adr" => "docs/adr/0019-project-facts-receipt-local-revision.md",
    "decision" => "D-224",
    "enforced_by_validator" => false,
    "original_generation" => %{
      "created_at" => "2026-10-06T21:26:41.360710Z",
      "factory_version" => "0.1.0",
      "operation" => "render",
      "operation_version" => 1,
      "receipt_sha256" => "26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475",
      "scaffold_commit" => "eccbe8fa9b35156206b0387fcc5449c10ad034f4",
      "sha256" => "cc0ab2de09dd3f41e320bb4a92e927b1a022bd88a3fa00638f747039598b2d17",
      "upstream_revision" => "22277a8e41667b489686c6baf34d10187cbae2db"
    },
    "provenance" =>
      "delegated-acceptance local baseline (D-219); the factory did not generate these bytes and the original validation does not cover them",
    "reason" =>
      "ADR-0004 agent-environment amendment item 1 (D-224): record the agentenv-1 Phoenix port 4130 and its database",
    "revised_sha256" => "80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c",
    "revision" => 1,
    "schema" => "sdr-agent/receipt-local-revision/2"
  }

  ## A1

  test "A1: exactly template-project-facts carries local_revision, seed_once render 1" do
    assert a1(current_receipt!()) == :ok
  end

  test "A1 rejects another revised unit, a missing revision and a changed unit identity" do
    receipt = current_receipt!()
    assert a1(receipt) == :ok, "control"

    [other | _] = Enum.reject(receipt["owned_units"], &(&1["unit"] == @unit))

    for {label, mutated} <- [
          {"second revised unit",
           put_unit(receipt, other["unit"], &Map.put(&1, "local_revision", @local_revision))},
          {"no revision", update_facts_unit(receipt, &Map.delete(&1, "local_revision"))},
          {"lifecycle",
           update_facts_unit(receipt, &Map.put(&1, "lifecycle", "external_generator"))},
          {"operation", update_facts_unit(receipt, &Map.put(&1, "operation", "copy"))},
          {"operation_version", update_facts_unit(receipt, &Map.put(&1, "operation_version", 2))},
          {"artifact_id",
           update_facts_unit(receipt, &Map.put(&1, "artifact_id", "template-other"))}
        ] do
      assert {:error, _reason} = a1(mutated), "A1 accepted the mutation: #{label}"
    end
  end

  ## A2

  test "A2: local_revision is the C2 literal and the digests agree" do
    assert a2(current_receipt!(), File.read!(Path.join(@root, @unit)), @root) == :ok
  end

  test "A2 rejects every changed leaf value and a missing and an extra key at each level" do
    receipt = current_receipt!()
    facts = File.read!(Path.join(@root, @unit))
    assert a2(receipt, facts, @root) == :ok, "control"

    mutations = leaf_mutations(@local_revision, []) ++ key_mutations(@local_revision)
    assert length(mutations) == 16 + 4, "every C2 leaf (16) and four key mutations"

    for {label, revision} <- mutations do
      mutated = update_facts_unit(receipt, &Map.put(&1, "local_revision", revision))
      assert {:error, _reason} = a2(mutated, facts, @root), "A2 accepted the mutation: #{label}"
    end

    assert {:error, _reason} = a2(receipt, facts <> "x", @root), "A2 accepted other facts bytes"

    unit_digest = update_facts_unit(receipt, &Map.put(&1, "sha256", String.duplicate("0", 64)))
    assert {:error, _reason} = a2(unit_digest, facts, @root), "A2 accepted another unit digest"
  end

  ## A3

  test "A3: normalized from its own provenance, the receipt equals the original" do
    assert a3(current_receipt!(), original_receipt!()) == :ok
  end

  test "A3 rejects missing provenance, other provenance and any other change" do
    receipt = current_receipt!()
    original = original_receipt!()
    assert a3(receipt, original) == :ok, "control"

    [other | _] = Enum.reject(receipt["owned_units"], &(&1["unit"] == @unit))

    without_generation_sha = fn unit ->
      update_in(unit, ["local_revision", "original_generation"], &Map.delete(&1, "sha256"))
    end

    for {label, mutated} <- [
          {"no local_revision", update_facts_unit(receipt, &Map.delete(&1, "local_revision"))},
          {"no original_generation",
           update_facts_unit(
             receipt,
             &update_in(&1, ["local_revision"], fn revision ->
               Map.delete(revision, "original_generation")
             end)
           )},
          {"no original_generation.sha256", update_facts_unit(receipt, without_generation_sha)},
          {"other original_generation.sha256",
           update_facts_unit(
             receipt,
             &put_in(
               &1,
               ["local_revision", "original_generation", "sha256"],
               String.duplicate("a", 64)
             )
           )},
          {"another unit's digest",
           put_unit(receipt, other["unit"], &Map.put(&1, "sha256", String.duplicate("b", 64)))},
          {"another unit's extra key",
           put_unit(receipt, other["unit"], &Map.put(&1, "note", "x"))},
          {"a top-level field", Map.put(receipt, "created_at", "2026-10-27T00:00:00.000000Z")},
          {"an added unit", Map.update!(receipt, "owned_units", &(&1 ++ [other]))}
        ] do
      assert {:error, _reason} = a3(mutated, original), "A3 accepted the mutation: #{label}"
    end
  end

  ## A4

  describe "A4" do
    test "(a) unchanged: the copy's own validator passes", %{tmp_dir: tmp} do
      copy = fresh_copy!(tmp)
      assert {0, @ok, stderr} = verify!(copy, tmp)
      refute stderr =~ "drifted"
    end

    test "(b) one byte appended to the facts: exit 1 with exactly the drift message",
         %{tmp_dir: tmp} do
      copy = fresh_copy!(tmp)
      facts = Path.join(copy, @unit)
      write_regular!(facts, File.read!(facts) <> "x")
      assert verify!(copy, tmp) == {1, "", @drift}
    end

    test "(c) the original factory facts: exit 1 with exactly the drift message",
         %{tmp_dir: tmp} do
      original = git_blob!("#{@scaffold}:#{@unit}")
      assert sha256(original) == @original_facts_sha256, "A4 (c): the original facts object"
      copy = fresh_copy!(tmp)
      write_regular!(Path.join(copy, @unit), original)
      assert verify!(copy, tmp) == {1, "", @drift}
    end

    test "(d) only local_revision removed: the validator passes; A1, A2 and A3 each reject it",
         %{tmp_dir: tmp} do
      copy = fresh_copy!(tmp)
      path = Path.join(copy, @receipt)
      bytes = File.read!(path)
      fragment = "\"local_revision\":" <> Jason.encode!(@local_revision) <> ","
      assert occurrences(bytes, fragment) == 1, "A4 (d): the local_revision bytes occur once"
      stripped = String.replace(bytes, fragment, "", global: false)
      write_regular!(path, stripped)

      assert {0, @ok, stderr} = verify!(copy, tmp)
      refute stderr =~ "drifted"

      decoded = Jason.decode!(stripped)
      facts = File.read!(Path.join(copy, @unit))
      assert {:error, _reason} = a1(decoded), "A1 accepted the stripped receipt"
      assert {:error, _reason} = a2(decoded, facts, copy), "A2 accepted the stripped receipt"

      assert {:error, _reason} = a3(decoded, original_receipt!()),
             "A3 accepted the stripped receipt"
    end
  end

  ## The checks (each returns :ok or {:error, reason naming the check and field})

  defp a1(receipt) do
    revised = for %{"local_revision" => _} = unit <- units(receipt), do: unit["artifact_id"]

    identity =
      case facts_units(receipt) do
        [unit] ->
          {unit["artifact_id"], unit["lifecycle"], unit["operation"], unit["operation_version"]}

        units ->
          {:units, length(units)}
      end

    cond do
      revised != [@artifact] ->
        {:error, "A1: the units carrying local_revision are #{inspect(revised)}"}

      identity != {@artifact, "seed_once", "render", 1} ->
        {:error, "A1: the #{@unit} unit's identity is #{inspect(identity)}"}

      true ->
        :ok
    end
  end

  defp a2(receipt, facts, root) do
    case facts_units(receipt) do
      [%{"local_revision" => revision} = unit] ->
        cond do
          revision != @local_revision ->
            {:error,
             "A2: local_revision differs at #{inspect(differences(@local_revision, revision, []))}"}

          unit["sha256"] != revision["revised_sha256"] ->
            {:error, "A2: the unit sha256 is not revised_sha256"}

          unit["sha256"] != sha256(facts) ->
            {:error, "A2: the unit sha256 is not sha256 of the facts bytes"}

          not File.regular?(Path.join(root, revision["adr"])) ->
            {:error, "A2: the adr path does not exist"}

          true ->
            :ok
        end

      _other ->
        {:error, "A2: no single #{@unit} unit carrying local_revision"}
    end
  end

  defp a3(receipt, original) do
    case facts_units(receipt) do
      [%{"local_revision" => %{"original_generation" => %{"sha256" => sha256}}}]
      when is_binary(sha256) ->
        normalized =
          update_facts_unit(receipt, fn unit ->
            unit |> Map.put("sha256", sha256) |> Map.delete("local_revision")
          end)

        if normalized == original,
          do: :ok,
          else:
            {:error,
             "A3: the normalized receipt differs at #{inspect(differences(original, normalized, []))}"}

      _missing ->
        {:error, "A3: missing provenance (local_revision.original_generation.sha256)"}
    end
  end

  ## Receipts

  defp current_receipt!, do: @root |> Path.join(@receipt) |> File.read!() |> Jason.decode!()

  defp original_receipt! do
    bytes = git_blob!("#{@scaffold}:#{@receipt}")
    assert sha256(bytes) == @original_receipt_sha256, "A3: the original receipt object's sha256"
    Jason.decode!(bytes)
  end

  defp units(%{"owned_units" => units}) when is_list(units), do: units
  defp units(_receipt), do: []

  defp facts_units(receipt), do: Enum.filter(units(receipt), &(&1["unit"] == @unit))

  defp update_facts_unit(receipt, fun), do: put_unit(receipt, @unit, fun)

  defp put_unit(receipt, unit, fun),
    do:
      Map.update!(
        receipt,
        "owned_units",
        &Enum.map(&1, fn entry -> update_entry(entry, unit, fun) end)
      )

  defp update_entry(%{"unit" => unit} = entry, unit, fun), do: fun.(entry)
  defp update_entry(entry, _unit, _fun), do: entry

  # Each leaf changed once (strings extended, integers incremented, booleans
  # negated), as {label, revision}.
  defp leaf_mutations(map, path) do
    Enum.flat_map(map, fn
      {key, value} when is_map(value) ->
        leaf_mutations(value, path ++ [key])

      {key, value} ->
        [{Enum.join(path ++ [key], "."), put_in(@local_revision, path ++ [key], changed(value))}]
    end)
  end

  defp changed(value) when is_binary(value), do: value <> "x"
  defp changed(value) when is_integer(value), do: value + 1
  defp changed(value) when is_boolean(value), do: not value

  # A missing and an extra key at each level (top and original_generation).
  defp key_mutations(revision) do
    [
      {"missing schema", Map.delete(revision, "schema")},
      {"extra top-level key", Map.put(revision, "pr", 1)},
      {"missing original_generation.created_at",
       update_in(revision, ["original_generation"], &Map.delete(&1, "created_at"))},
      {"extra original_generation key",
       update_in(revision, ["original_generation"], &Map.put(&1, "extra", "x"))}
    ]
  end

  # The key paths at which two JSON values differ (for failure messages).
  defp differences(same, same, _path), do: []

  defp differences(%{} = expected, %{} = actual, path) do
    keys = Enum.uniq(Map.keys(expected) ++ Map.keys(actual))

    Enum.flat_map(
      keys,
      &differences(Map.get(expected, &1, :missing), Map.get(actual, &1, :missing), path ++ [&1])
    )
  end

  defp differences(_expected, _actual, path), do: [Enum.join(path, ".")]

  ## The copied tree and its validator

  # A fresh copy of the tracked tree under `tmp`, passing A4 (i) before the
  # case runs; removed when the test ends.
  defp fresh_copy!(tmp) do
    copy = Path.join(tmp, "copy")
    on_exit(fn -> File.rm_rf(copy) end)
    {listing, 0} = System.cmd("git", ["-C", @root, "ls-files", "-z"])

    for relative <- String.split(listing, <<0>>, trim: true) do
      copy_entry!(Path.join(@root, relative), Path.join(copy, relative))
    end

    receipt = File.read!(Path.join(copy, @receipt))
    facts = File.read!(Path.join(copy, @unit))

    assert sha256(receipt) == @revised_receipt_sha256,
           "A4 (i): the copy's receipt is not the reviewed revised receipt (#{sha256(receipt)})"

    assert sha256(facts) == @revised_facts_sha256,
           "A4 (i): the copy's facts are not the reviewed revised facts (#{sha256(facts)})"

    copy
  end

  defp copy_entry!(source, target) do
    File.mkdir_p!(Path.dirname(target))
    assert {:error, :enoent} = File.lstat(target), "A4: #{target} already exists"

    case File.lstat!(source) do
      %File.Stat{type: :symlink} ->
        :ok = File.ln_s(File.read_link!(source), target)

      %File.Stat{type: :regular, mode: mode} ->
        File.cp!(source, target)
        File.chmod!(target, Bitwise.band(mode, 0o7777))

      %File.Stat{type: type} ->
        flunk("A4: the tracked entry #{source} is a #{type}")
    end
  end

  # Writes only to a regular file of the copy, never through a link.
  defp write_regular!(path, bytes) do
    assert %File.Stat{type: :regular} = File.lstat!(path)
    File.write!(path, bytes)
  end

  # The copy's own bin/verify-workflow: {exit status, stdout, stderr}.
  defp verify!(copy, tmp) do
    stderr = Path.join(tmp, "verify-workflow.stderr")
    script = Path.join(copy, "bin/verify-workflow")

    task =
      Task.async(fn -> System.cmd("sh", ["-c", "exec \"$1\" 2>\"$2\"", "sh", script, stderr]) end)

    case Task.yield(task, @validator_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, status}} ->
        {status, stdout, File.read!(stderr)}

      _timeout ->
        flunk("A4: bin/verify-workflow did not finish within #{@validator_timeout_ms} ms")
    end
  end

  defp git_blob!(object) do
    {bytes, status} = System.cmd("git", ["-C", @root, "cat-file", "blob", object])
    assert status == 0, "the git object #{object} is unavailable (no fetch fallback)"
    bytes
  end

  defp occurrences(bytes, fragment), do: length(:binary.matches(bytes, fragment))

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
