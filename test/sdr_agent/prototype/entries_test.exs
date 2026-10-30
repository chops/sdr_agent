defmodule SdrAgent.Prototype.EntriesTest do
  @moduledoc """
  The compiled D-237 entries and their `sdr-canonical-json/1` digests
  (amendment items 1 and 4; interfaces r6 IF-2 "Compiled entries"; the S1
  pending item 4, Codex 2c9450b7 rulings 3c and 3d):

  - `SdrAgent.Prototype.Authority.funding_entry_sha256/0` is the golden
    vector `d8e675ce…`, and the same entry with `total_attempts: 99` hashes
    to the inequality control `2aef0ace…`;
  - `policy_entry_sha256/0` is the canonical digest of the exact
    `d237-prototype/1` entry;
  - a control pins the vectors to the literal owner-approved D-269 entry
    independently of the Authority.

  The raw entries are read without prototype runtime: they are compiled
  constants of the dev/test authority; the facade's `policy_entry/0` and
  `funding_entry/0` still refuse outside prototype runtime.
  """
  use SdrAgent.PrototypeCase, async: true

  alias SdrAgent.Audit.Canonical

  @authority SdrAgent.Prototype.Authority
  @golden "d8e675ce642857511ed201fab998484d9cfd40e040f891f141a469d3294d825b"
  @control_99 "2aef0ace8640977bea45d5b6a09d38c7c201fd409ff6e6567731f04776cdedfc"

  @funding_entry %{
    total_attempts: 100,
    starts_at: ~U[2026-10-30 15:05:40.000000Z],
    expires_at: ~U[2026-11-07 07:00:00.000000Z],
    profile_ids: [:claude_cli_opus],
    funded_scope: [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}],
    allocations: [%{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 100}],
    decision_refs: ["D-238", "D-239", "D-243", "D-269"]
  }

  @policy_entry %{
    database: "sdr_agent_prototype",
    dataset_class: :real_prototype,
    identity: %{provider: :claude_cli, ledger_generation: 2, profile_ids: [:claude_cli_opus]},
    usage_origins: [:assignment],
    purposes: [:qualification, :evidence_extraction, :outreach_proposal],
    witness_mode: :absent,
    funding_id: "d237-funding/1",
    max_contacts: 3,
    label: "UNVERIFIED (PROTOTYPE)",
    acceptance_ref: "D-249",
    text_sha256: "99a2869ea7501eeeb4615137f23f830de5ddabc2ac746ae6638fbc6fafde9ac0"
  }

  defp digest_hex(term), do: Base.encode16(Canonical.sha256(term), case: :lower)

  test "control: the literal D-269 funding entry hashes to the golden vector" do
    assert digest_hex(@funding_entry) == @golden
    assert digest_hex(%{@funding_entry | total_attempts: 99}) == @control_99
  end

  test "funding_entry_sha256/0 is the golden vector and funding_entry/0 the exact entry" do
    assert call(@authority, :funding_entry_sha256, []) == @golden
    assert call(@authority, :funding_entry, []) == @funding_entry
  end

  test "the inequality control: total_attempts 99 changes the digest" do
    entry = call(@authority, :funding_entry, [])
    assert is_map(entry), "funding_entry/0 returned #{inspect(entry)}"
    changed = digest_hex(%{entry | total_attempts: 99})
    assert changed == @control_99
    refute changed == @golden
  end

  test "policy_entry_sha256/0 is the canonical digest of the exact policy entry" do
    assert call(@authority, :policy_entry, []) == @policy_entry
    assert call(@authority, :policy_entry_sha256, []) == digest_hex(@policy_entry)
  end
end
