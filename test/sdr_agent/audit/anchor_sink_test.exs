defmodule SdrAgent.Audit.AnchorSinkTest do
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.AnchorSinks.FileSink
  alias SdrAgent.Audit.AnchorSinks.GitSink
  alias SdrAgent.Audit.AnchorSinks.OpenTimestampsSink

  defmodule FakeCalendar do
    def submit(hash, _opts), do: {:ok, "pending:" <> Base.encode16(hash, case: :lower)}

    def upgrade("pending:" <> digest, _hash, _opts),
      do: {:ok, %{proof: "complete:" <> digest, bitcoin_attested: true}}

    def verify("complete:" <> _digest, _hash, _opts), do: {:ok, %{timestamp: 1_700_000_000}}
    def verify(_, _, _), do: {:error, :pending}
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

  test "production OTS verification binds the digest of a real detached proof fixture" do
    proof =
      "test/fixtures/ots/hello-world.txt.ots.base64"
      |> File.read!()
      |> String.replace(~r/\s/, "")
      |> Base.decode64!()

    <<_header::binary-size(33), hash::binary-size(32), _rest::binary>> = proof
    <<_::binary-size(65), calendar_response::binary>> = proof

    request = fn "https://a.pool.opentimestamps.org/digest", opts ->
      assert opts[:body] == hash
      {:ok, %{status: 200, body: calendar_response}}
    end

    assert {:ok, ^proof} = OpenTimestampsSink.Calendar.submit(hash, request: request)

    command = fn "ots", ["verify", "-d", digest, path], opts ->
      assert digest == Base.encode16(hash, case: :lower)
      assert File.read!(path) == proof
      assert {"TZ", "UTC"} in opts[:env]
      {"Success! Bitcoin block 358391 attests existence as of 2015-05-28 UTC", 0}
    end

    assert {:ok, %{verified: true, timestamp: ~U[2015-05-29 00:00:00Z]}} =
             OpenTimestampsSink.Calendar.verify(proof, hash, command: command)

    assert {:error, :ots_digest_mismatch} =
             OpenTimestampsSink.Calendar.verify(
               proof,
               :crypto.hash(:sha256, "different anchor"),
               command: command
             )

    assert {:error, :bitcoin_attestation_missing} =
             OpenTimestampsSink.Calendar.verify(
               proof,
               hash,
               command: fn _, _, _ -> {"not a Bitcoin attestation", 0} end
             )
  end

  @tag :external
  test "real ots binary rejects a mismatched digest fixture" do
    proof =
      "test/fixtures/ots/hello-world.txt.ots.base64"
      |> File.read!()
      |> String.replace(~r/\s/, "")
      |> Base.decode64!()

    path =
      Path.join(System.tmp_dir!(), "sdr-wrong-digest-#{System.unique_integer([:positive])}.ots")

    File.write!(path, proof)
    on_exit(fn -> File.rm(path) end)

    {output, status} =
      System.cmd("ots", ["verify", "-d", String.duplicate("0", 64), path], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "Digest provided does not match"
  end

  test "GitSink returns commit and blob ids without placing statement bytes in argv", %{
    path: path
  } do
    statement = "signed statement with private audit details"
    repository = Path.join(path, "argv.git")
    {_, 0} = System.cmd("git", ["init", "--bare", repository], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["--git-dir", repository, "symbolic-ref", "HEAD", "refs/heads/main"])

    caller = self()

    command = fn "git", args, opts ->
      send(caller, {:git_argv, args})
      refute Enum.any?(args, &String.contains?(&1, statement))
      assert {"GIT_DIR", nil} in opts[:env]
      System.cmd("git", args, opts)
    end

    assert {:ok, receipt} =
             GitSink.publish(statement,
               command: command,
               repository: repository,
               allowed_repository: repository,
               anchor_number: 4
             )

    assert receipt.status == :confirmed
    assert receipt.commit_id =~ ~r/\A[0-9a-f]{40}\z/
    assert receipt.blob_id =~ ~r/\A[0-9a-f]{40}\z/
    assert_received {:git_argv, ["clone", "--", ^repository, _]}
    assert_received {:git_argv, ["push", "origin", "HEAD:main"]}
    refute inspect(receipt) =~ statement
  end

  test "GitSink production command path commits and pushes to an explicitly allowed repository",
       %{
         path: path
       } do
    repository = Path.join(path, "anchors.git")
    {_output, 0} = System.cmd("git", ["init", "--bare", repository], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["--git-dir", repository, "symbolic-ref", "HEAD", "refs/heads/main"])

    assert {:ok, receipt} =
             GitSink.publish("signed production statement",
               repository: repository,
               allowed_repository: repository,
               anchor_number: 1
             )

    assert receipt.repository == repository
    assert receipt.commit_id =~ ~r/\A[0-9a-f]{40}\z/
    assert receipt.blob_id =~ ~r/\A[0-9a-f]{40}\z/
    {_output, 0} = System.cmd("git", ["--git-dir", repository, "rev-parse", "main"])

    assert {:ok, repeated} =
             GitSink.publish("signed production statement",
               repository: repository,
               allowed_repository: repository,
               anchor_number: 1
             )

    assert repeated.commit_id == receipt.commit_id
    assert repeated.blob_id == receipt.blob_id

    assert {:error, :conflicting_anchor} =
             GitSink.publish("changed statement",
               repository: repository,
               allowed_repository: repository,
               anchor_number: 1
             )
  end

  test "GitSink rejects repositories outside the configured anchor repository" do
    assert {:error, :repository_not_allowed} =
             GitSink.publish("statement",
               repository: "git@example.invalid/other",
               anchor_number: 1
             )
  end

  @tag :external
  test "real OpenTimestamps calendar round-trip is opt-in" do
    assert {:ok, %{status: :pending}} =
             OpenTimestampsSink.publish(:crypto.hash(:sha256, "external-smoke"), [])
  end
end
