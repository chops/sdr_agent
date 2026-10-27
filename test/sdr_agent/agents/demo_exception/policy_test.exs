defmodule SdrAgent.Agents.DemoException.PolicyTest do
  @moduledoc """
  C2* slice S3 RED-1, AC1 and `label/0` (plan r2 §2 AC1, §4.2 S3-b, §6
  `demo_exception.ex`; accepted design r4, ADR-0005 C2* amendment item 1).

  The one closed policy entry `c2star-demo-v4/1`:

    * `SdrAgent.Agents.DemoException.entry/0` is a plain map with exactly
      the item 1 fields (`environment_id`, `starts_at`, `expires_at`,
      `identity`, `projection_version`, `method`, `usage_origins`,
      `purposes`, `lead_ids`, `authorization_id`, `label`,
      `acceptance_ref`) and their item 1 values;
    * `authorization_id` is nil (no owner caps exist, so nothing is
      eligible) and `acceptance_ref` is `"D-223"`;
    * `lead_ids` are the five `:qualify` leads of `Fixtures.leads/0`
      (`lib/sdr_agent/demo/fixtures.ex:136-179,219-223`), in fixture order;
    * `entry_sha256/0` is the lowercase hex SHA-256 of the entry's
      `sdr-canonical-json/1` encoding;
    * `label/0` is public and exactly the item 1 label.

  The entry's own id (`c2star-demo-v4/1`) is its name in item 1, not one of
  the listed fields, so it is not an `entry/0` key here.

  `async: false`: in test builds `entry/0` may honour a per-test
  authorization override through the test seam (plan r2 §10); this file
  asserts the default, with no override configured. The dev and prod
  builds' absence of that seam is the separate artifact proof (binding
  correction 3), not this file.

  RED report labels: `control: ...` passes now and after GREEN; every other
  test fails on its guard (structural: `DemoException` is absent at this
  head).
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Demo.Fixtures

  @demo_exception SdrAgent.Agents.DemoException

  @lead_ids [
    "019b8eac-1180-74d8-9f38-54127081d946",
    "019b8eac-1180-7c3d-a4ad-c369e27a97f1",
    "019b8eac-1180-761c-9fad-f113afaa661b",
    "019b8eac-1180-7ac2-81bb-c970986aa7be",
    "019b8eac-1180-742a-89d2-cc1ca61efd6a"
  ]

  @label "demo exception - v4 not independently calibrated"

  # ADR-0005 C2* item 1, verbatim.
  @entry %{
    environment_id: "agentenv-1",
    starts_at: ~U[2026-10-27 06:00:00.000000Z],
    expires_at: ~U[2026-11-01 06:00:00.000000Z],
    identity: %{
      provider: :claude_cli,
      cli_version: "2.1.294",
      profile_id: :claude_cli_opus,
      model_id: "claude-opus-5-5",
      prompt_builder: "prompt-builder/1",
      ledger_generation: 2
    },
    projection_version: "claude-message-json/4+prompt-builder/1",
    method: :propagated_id,
    usage_origins: [:assignment],
    purposes: [:qualification, :evidence_extraction, :outreach_proposal],
    lead_ids: @lead_ids,
    authorization_id: nil,
    label: @label,
    acceptance_ref: "D-223"
  }

  @instants [:starts_at, :expires_at]

  test "control: the five C2* lead ids are exactly the :qualify fixture leads, in order" do
    assert qualify_lead_ids() == @lead_ids
  end

  test "AC1: entry/0 is a plain map with exactly the item 1 fields and values" do
    implemented!(:entry, 0)
    entry = call(:entry)

    assert is_map(entry) and not is_struct(entry), "entry/0 must be a plain map"

    assert Enum.sort(Map.keys(entry)) == Enum.sort(Map.keys(@entry)),
           "entry/0 must have exactly the item 1 fields"

    assert Map.drop(entry, @instants) == Map.drop(@entry, @instants)

    for key <- @instants do
      assert same_instant?(Map.fetch!(entry, key), Map.fetch!(@entry, key)),
             "#{key} must be #{inspect(Map.fetch!(@entry, key))}"
    end
  end

  test "AC1: the shipped entry names no authorization and accepts under D-223" do
    implemented!(:entry, 0)
    entry = call(:entry)

    assert Map.has_key?(entry, :authorization_id) and is_nil(entry.authorization_id),
           "authorization_id must be nil: no owner caps exist, so nothing is eligible"

    assert Map.get(entry, :acceptance_ref) == "D-223"
  end

  test "AC1: the entry's lead ids are the :qualify leads of Fixtures.leads/0" do
    implemented!(:entry, 0)
    assert Map.get(call(:entry), :lead_ids) == qualify_lead_ids()
  end

  test "AC1: entry_sha256/0 is the sdr-canonical-json/1 digest of every entry field" do
    item_1_digest = @entry |> Canonical.encode!() |> sha256_hex()

    implemented!(:entry, 0)
    implemented!(:entry_sha256, 0)
    digest = call(:entry_sha256)
    encoded = Canonical.encode(call(:entry))

    assert match?({:ok, _bytes}, encoded),
           "entry/0 must be canonically encodable: #{inspect(encoded)}"

    {:ok, bytes} = encoded
    assert is_binary(digest) and digest =~ ~r/\A[0-9a-f]{64}\z/, "lowercase hex-64"
    assert digest == sha256_hex(bytes), "the digest of entry/0's canonical encoding"
    assert digest == item_1_digest, "the digest of exactly the item 1 entry"
  end

  test "label/0 is public and is exactly the item 1 label" do
    implemented!(:label, 0)
    implemented!(:entry, 0)

    assert call(:label) == @label
    assert Map.get(call(:entry), :label) == call(:label)
  end

  # Lead ids of the accounts designated `:qualify`, in `Fixtures.leads/0` order.
  defp qualify_lead_ids do
    qualify = for %{expected_outcome: :qualify, id: id} <- Fixtures.accounts(), do: id
    for %{account_id: account, id: id} <- Fixtures.leads(), account in qualify, do: id
  end

  defp same_instant?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_instant?(_left, _right), do: false

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp implemented!(function, arity) do
    assert Code.ensure_loaded?(@demo_exception) and
             function_exported?(@demo_exception, function, arity),
           "C2* S3: #{inspect(@demo_exception)}.#{function}/#{arity} is not implemented"
  end

  defp call(function, args \\ []), do: apply(@demo_exception, function, args)
end
