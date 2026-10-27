defmodule SdrAgent.Audit.RecordHashContinuityTest do
  @moduledoc """
  C2* slice S3 RED-2, the pure record-hash continuity tests (plan r2 §5,
  §8 T-H1, T-H2, T-H7; ADR-0009 C2* record-hash continuity amendment,
  accepted as D-226).

  `SdrAgent.Agents.ModelResultRelease` declares one record-hash group,
  `c2star-demo-exception`, of exactly the four exception columns. Its row map
  is every attribute, except that the four members are left out together
  when all four are nil, and are all included (nil as JSON null) when any is
  non-nil. Every other attribute, and every other resource's row map, is
  unchanged.

    * T-H1 (control): an in-memory ordinary release hashes to
      `Canonical.sha256/1` of the literal twelve-key map whose keys are the
      predecessor snapshot's attribute sources
      (`priv/resource_snapshots/repo/model_result_releases/20261012214849.json`).
      It passes at this pre-S3 head (the formula is observed here) and must
      stay green after the migration.
    * T-H2: each single non-nil member brings all four keys and changes the
      hash; all four nil gives exactly the twelve keys; a demo row (all four
      non-nil) commits all sixteen; nil non-members stay committed as null.
      The single-member vectors are the partial-value cases that kill the
      "any member nil" mutant (binding correction 2). The other-resources
      check is a control.
    * T-H7: closed registry: only ModelResultRelease declares
      `__sdr_record_hash_groups__/0`, with one group of exactly the four
      members, each nullable, and equal to the attributes absent from the
      predecessor snapshot; `RecordHash.groups/1` agrees for every resource.

  Pure: no database. RED report labels: `control` passes now and after
  GREEN; T-H2 and T-H7 fail on their guards (structural: the four attributes,
  the hook and `RecordHash.groups/1` are absent at this head).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.RecordHash

  @snapshot "priv/resource_snapshots/repo/model_result_releases/20261012214849.json"
  @group "c2star-demo-exception"
  @members [
    :exception_policy_id,
    :exception_expires_at,
    :exception_basis,
    :exception_basis_sha256
  ]
  @twelve [
    :id,
    :disposition,
    :reason,
    :projection_version,
    :method,
    :evidence_sha256,
    :decided_at,
    :trace_id,
    :span_id,
    :tenant_id,
    :model_invocation_id,
    :wire_witness_link_id
  ]
  @non_members [:wire_witness_link_id, :projection_version, :method, :evidence_sha256]

  @tenant_id "019b8eac-0aaa-7bbb-8ccc-0000000000f1"
  @invocation_id "019b8eac-0aaa-7bbb-8ccc-0000000000f2"
  @link_id "019b8eac-0aaa-7bbb-8ccc-0000000000f3"
  @decided_at ~U[2026-10-28 12:00:00.000000Z]

  ## Fixtures

  # A withheld release without a link: every non-member optional attribute nil.
  defp withheld do
    %ModelResultRelease{
      id: "019b8eac-0aaa-7bbb-8ccc-0000000000f4",
      disposition: :withheld,
      reason: :witness_missing,
      projection_version: nil,
      method: nil,
      evidence_sha256: nil,
      decided_at: @decided_at,
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "0123456789abcdef",
      tenant_id: @tenant_id,
      model_invocation_id: @invocation_id,
      wire_witness_link_id: nil
    }
  end

  defp released do
    %ModelResultRelease{
      withheld()
      | id: "019b8eac-0aaa-7bbb-8ccc-0000000000f5",
        disposition: :released,
        reason: :reconciled,
        projection_version: "claude-message-json/3+prompt-builder/1",
        method: :propagated_id,
        wire_witness_link_id: @link_id
    }
  end

  # The literal pre-S3 row map: exactly twelve keys, values as stored.
  defp literal(release), do: Map.new(@twelve, &{&1, Map.fetch!(release, &1)})

  defp member_values do
    %{
      exception_policy_id: "c2star-demo-v4/1",
      exception_expires_at: ~U[2026-11-01 06:00:00.000000Z],
      exception_basis: %{"schema" => "c2star-basis/1", "policy" => %{"id" => "c2star-demo-v4/1"}},
      exception_basis_sha256: :crypto.hash(:sha256, "basis") |> Base.encode16(case: :lower)
    }
  end

  # `Map.put`, not struct update: the members are not struct fields at the
  # RED head, and the guard below reports that before any assertion.
  defp with_members(release, members),
    do: Enum.reduce(members, release, fn {key, value}, acc -> Map.put(acc, key, value) end)

  defp snapshot_sources do
    @snapshot
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("attributes")
    |> Enum.map(&String.to_existing_atom(&1["source"]))
  end

  defp resources do
    :sdr_agent
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  end

  defp attribute_names(resource),
    do: resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()

  ## Guards

  defp members_declared! do
    missing = Enum.reject(@members, &Ash.Resource.Info.attribute(ModelResultRelease, &1))

    assert missing == [],
           "C2* S3: ModelResultRelease attributes #{inspect(missing)} are not implemented"
  end

  defp implemented!(module, function, arity) do
    assert Code.ensure_loaded?(module) and function_exported?(module, function, arity),
           "C2* S3: #{inspect(module)}.#{function}/#{arity} is not implemented"
  end

  # Called dynamically: absent at the RED head.
  defp call(module, function, args), do: apply(module, function, args)

  ## T-H1

  test "T-H1 control: an ordinary release hashes as the pre-S3 twelve-key row map" do
    assert Enum.sort(@twelve) == Enum.sort(snapshot_sources()),
           "the literal keys are the predecessor snapshot's attribute sources"

    for release <- [withheld(), released()] do
      literal = literal(release)
      assert map_size(literal) == 12
      assert RecordHash.canonical_map(release) == literal, inspect(release.disposition)
      assert RecordHash.sha256(release) == Canonical.sha256(literal)
      assert RecordHash.hex(release) == Base.encode16(Canonical.sha256(literal), case: :lower)
    end
  end

  ## T-H2

  describe "T-H2 projection of the c2star-demo-exception group" do
    test "each single non-nil member brings all four keys and changes the hash" do
      vectors = for {member, value} <- member_values(), do: {member, [{member, value}]}

      members_declared!()
      base_hash = RecordHash.sha256(withheld())

      for {member, members} <- vectors do
        release = with_members(withheld(), members)
        map = RecordHash.canonical_map(release)

        assert sorted_keys(map) == Enum.sort(@twelve ++ @members),
               "#{member} alone: all sixteen keys"

        assert Map.fetch!(map, member) == Map.fetch!(member_values(), member)

        for other <- @members -- [member],
            do: assert(Map.fetch!(map, other) == nil, "#{member} alone: #{other} is null")

        for key <- @non_members,
            do: assert(Map.fetch!(map, key) == nil, "#{member} alone: #{key} stays null")

        assert RecordHash.sha256(release) != base_hash, "#{member} alone changes the hash"
      end
    end

    test "all four members nil gives exactly the twelve pre-S3 keys, non-member nils included" do
      members_declared!()

      for release <- [withheld(), released()] do
        all_nil = with_members(release, Map.new(@members, &{&1, nil}))
        map = RecordHash.canonical_map(all_nil)
        assert sorted_keys(map) == Enum.sort(@twelve)
        assert map == literal(release)
        assert RecordHash.sha256(all_nil) == Canonical.sha256(literal(release))
      end

      for key <- @non_members, do: assert(Map.has_key?(RecordHash.canonical_map(withheld()), key))
    end

    test "a demo row (all four non-nil) commits all sixteen keys" do
      members_declared!()
      demo = with_members(released(), member_values())
      map = RecordHash.canonical_map(demo)

      assert sorted_keys(map) == Enum.sort(@twelve ++ @members)
      assert Map.take(map, @members) == member_values()
      assert RecordHash.sha256(demo) != Canonical.sha256(literal(demo))
    end

    test "control: every other domain resource's row map is exactly its attributes" do
      for resource <- resources(), resource != ModelResultRelease do
        assert sorted_keys(RecordHash.canonical_map(struct(resource))) ==
                 Enum.sort(attribute_names(resource)),
               inspect(resource)
      end
    end
  end

  ## T-H7

  test "T-H7: closed registry: one group, on ModelResultRelease only, of exactly the four new nullable attributes" do
    others = Enum.reject(resources(), &(&1 == ModelResultRelease))

    declaring =
      for resource <- others,
          Code.ensure_loaded?(resource),
          function_exported?(resource, :__sdr_record_hash_groups__, 0),
          do: resource

    assert declaring == [], "no other resource declares a group: #{inspect(declaring)}"

    implemented!(ModelResultRelease, :__sdr_record_hash_groups__, 0)
    implemented!(RecordHash, :groups, 1)

    assert call(ModelResultRelease, :__sdr_record_hash_groups__, []) == [{@group, @members}]
    assert call(RecordHash, :groups, [ModelResultRelease]) == [{@group, @members}]

    for resource <- others,
        do: assert(call(RecordHash, :groups, [resource]) == [], inspect(resource))

    for member <- @members do
      attribute = Ash.Resource.Info.attribute(ModelResultRelease, member)
      assert attribute && attribute.allow_nil?, "#{member} is a nullable attribute"
    end

    added =
      MapSet.difference(
        MapSet.new(attribute_names(ModelResultRelease)),
        MapSet.new(snapshot_sources())
      )

    assert added == MapSet.new(@members),
           "the members are exactly the attributes added since the snapshot"
  end
end
