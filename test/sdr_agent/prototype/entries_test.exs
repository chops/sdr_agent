defmodule SdrAgent.Prototype.EntriesTest do
  @moduledoc """
  The compiled D-237 entries and their `sdr-canonical-json/1` digests
  (amendment items 1 and 4; interfaces r6 IF-2 "Compiled entries"; the S1
  pending item 4, Codex 2c9450b7 rulings 3c and 3d):

  - `SdrAgent.Prototype.Authority.funding_entry_sha256/0` is the golden
    vector `d5630873…`, and the same entry with `total_attempts: 49` hashes
    to the inequality control `d1a4c0eb…`;
  - `policy_entry_sha256/0` is the canonical digest of the exact
    `d237-prototype/1` entry;
  - a control pins the vectors to the literal entry of interfaces r6
    independently of the Authority.

  The raw entries are read without prototype runtime: they are compiled
  constants of the dev/test authority; the facade's `policy_entry/0` and
  `funding_entry/0` still refuse outside prototype runtime.
  """
  use SdrAgent.PrototypeCase, async: true

  alias SdrAgent.Audit.Canonical

  @authority SdrAgent.Prototype.Authority
  @golden "d56308736c6c5ef7a4521b9b442ec85298ab06f82d8ea447de35637e45d6349a"
  @control_49 "d1a4c0ebbabf0d9d88869a342f1129b583cd44f35e9c2e993ea967cf81853675"

  @funding_entry %{
    total_attempts: 50,
    starts_at: ~U[2026-10-28 02:38:32.000000Z],
    expires_at: ~U[2026-11-07 07:00:00.000000Z],
    profile_ids: [:claude_cli_opus],
    funded_scope: [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}],
    allocations: [%{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 50}],
    decision_refs: ["D-238", "D-239", "D-243"]
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

  test "control: the literal interfaces r6 funding entry hashes to the golden vector" do
    assert digest_hex(@funding_entry) == @golden
    assert digest_hex(%{@funding_entry | total_attempts: 49}) == @control_49
  end

  test "funding_entry_sha256/0 is the golden vector and funding_entry/0 the exact entry" do
    assert call(@authority, :funding_entry_sha256, []) == @golden
    assert call(@authority, :funding_entry, []) == @funding_entry
  end

  test "the inequality control: total_attempts 49 changes the digest" do
    entry = call(@authority, :funding_entry, [])
    assert is_map(entry), "funding_entry/0 returned #{inspect(entry)}"
    changed = digest_hex(%{entry | total_attempts: 49})
    assert changed == @control_49
    refute changed == @golden
  end

  test "policy_entry_sha256/0 is the canonical digest of the exact policy entry" do
    assert call(@authority, :policy_entry, []) == @policy_entry
    assert call(@authority, :policy_entry_sha256, []) == digest_hex(@policy_entry)
  end
end
