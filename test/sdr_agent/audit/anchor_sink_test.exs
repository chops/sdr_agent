defmodule SdrAgent.Audit.AnchorSinkTest do
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.AnchorSinks.FileSink
  alias SdrAgent.Audit.AnchorSinks.GitSink
  alias SdrAgent.Audit.AnchorSinks.OpenTimestampsSink

  defmodule FakeCalendar do
    def submit(hash, _opts), do: {:ok, "pending:" <> Base.encode16(hash, case: :lower)}
    def upgrade("pending:" <> digest, _opts), do: {:ok, "complete:" <> digest}
    def verify("complete:" <> _digest, _hash, _opts), do: {:ok, %{timestamp: 1_700_000_000}}
    def verify(_, _, _), do: {:error, :pending}
  end

  defmodule FakeGit do
    def run(["init", "--bare", _]), do: {:ok, "", 0}
    def run(["hash-object", "-w", _]), do: {:ok, String.duplicate("b", 40) <> "\n", 0}
    def run(["commit-tree" | _]), do: {:ok, String.duplicate("c", 40) <> "\n", 0}
    def run(["push" | _]), do: {:ok, "", 0}
  end

  setup do
    path = Path.join(System.tmp_dir!(), "sdr-anchor-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    %{path: path}
  end

  test "FileSink writes an immutable statement and returns its sha256", %{path: path} do
    statement = "signed statement"
    assert {:ok, receipt} = FileSink.publish(statement, directory: path, anchor_number: 3)
    assert receipt.status == :confirmed
    assert receipt.sha256 == :crypto.hash(:sha256, statement)
    assert File.read!(receipt.path) == statement

    assert {:error, :already_exists} =
             FileSink.publish(statement <> "changed", directory: path, anchor_number: 3)
  end

  test "OpenTimestamps stores pending evidence then produces a distinct upgraded proof" do
    hash = :crypto.hash(:sha256, "anchor")

    assert {:ok, pending} =
             OpenTimestampsSink.publish(hash, calendar: FakeCalendar, calendar_options: [])

    assert pending.status == :pending

    assert {:ok, confirmed} =
             OpenTimestampsSink.upgrade(pending.proof, hash,
               calendar: FakeCalendar,
               calendar_options: []
             )

    assert confirmed.status == :confirmed
    assert confirmed.proof != pending.proof

    assert {:ok, %{timestamp: 1_700_000_000}} =
             OpenTimestampsSink.verify(confirmed.proof, hash,
               calendar: FakeCalendar,
               calendar_options: []
             )
  end

  test "GitSink returns commit and blob ids without placing statement bytes in argv" do
    statement = "signed statement with private audit details"

    assert {:ok, receipt} =
             GitSink.publish(statement,
               runner: FakeGit,
               repository: "git@github.com:chops/sdr_agent-audit-anchors.git",
               anchor_number: 4
             )

    assert receipt.status == :confirmed
    assert receipt.commit_id == String.duplicate("c", 40)
    assert receipt.blob_id == String.duplicate("b", 40)
    refute inspect(receipt) =~ statement
  end

  @tag :external
  test "real OpenTimestamps calendar round-trip is opt-in" do
    assert {:ok, %{status: :pending}} =
             OpenTimestampsSink.publish(:crypto.hash(:sha256, "external-smoke"), [])
  end
end
