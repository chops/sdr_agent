defmodule SdrAgent.Agents.Witness.StoreTest do
  @moduledoc """
  S12c step 6 / C7: the bounded, read-only reader of the S12a proxy witness
  store. Paths derive only from a validated invocation UUID and validated
  digests beneath the configured root; no symlink is followed; record and
  blob counts and sizes are capped; raw hashes are re-verified; nothing is
  written.
  """
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @store SdrAgent.Agents.Witness.Store

  setup do
    root = Path.join(System.tmp_dir!(), "sdr-witness-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, id: Proxy.uuid7()}
  end

  test "reads a paired exchange and verifies its raw blobs", %{root: root, id: id} do
    request = Proxy.messages_request("hello")
    response = Proxy.sse_response(~s({"a":1}))
    record_id = Proxy.exchange!(root, id, request: request, response: response)
    snapshot = tree(root)

    assert {:ok, %{exchanges: [exchange], anomalies: []}} = inventory(root, id)
    assert exchange.record_id == record_id
    assert exchange.state == :terminal
    assert exchange.record["route"] == "/anthropic/v1/messages"
    assert {:ok, ^request} = blob(root, exchange.record["request_sha256"])
    assert {:ok, ^response} = blob(root, exchange.record["response_sha256"])
    assert tree(root) == snapshot, "the reader wrote to the store"
  end

  test "an unresolved start marker is an open exchange", %{root: root, id: id} do
    Proxy.exchange!(root, id, request: "{}", response: "{}")
    open_id = Proxy.exchange!(root, id, open: true)

    assert {:ok, %{exchanges: exchanges}} = inventory(root, id)
    assert %{state: :open} = Enum.find(exchanges, &(&1.record_id == open_id))
    assert Enum.count(exchanges, &(&1.state == :terminal)) == 1
  end

  test "no directory for the invocation is a missing witness", %{root: root, id: id} do
    assert {:error, :witness_missing} = inventory(root, id)
    assert {:error, :store_unconfigured} = inventory(nil, id)
  end

  test "only a lowercase UUID names the invocation directory", %{root: root} do
    for id <- ["../etc", "..", "/tmp/x", String.upcase(Proxy.uuid7()), "a/b", ""] do
      assert match?({:error, :invalid_invocation_id}, inventory(root, id)), inspect(id)
    end
  end

  test "symlinks are never followed", %{root: root, id: id} do
    outside =
      Path.join(System.tmp_dir!(), "sdr-witness-outside-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(outside) end)
    Proxy.exchange!(outside, id, request: "{}", response: "{}")

    File.mkdir_p!(Path.join(root, "witnesses"))
    File.ln_s!(Path.join([outside, "witnesses", id]), Path.join([root, "witnesses", id]))
    assert {:error, :unsafe_path} = inventory(root, id)

    other = Proxy.uuid7()
    record_id = Proxy.exchange!(root, other, request: "{}", response: "{}")
    path = Path.join([root, "witnesses", other, record_id <> ".json"])
    File.rm!(path)
    File.ln_s!(Path.join([outside, "witnesses", id, "x.json"]), path)
    assert {:error, :unsafe_path} = inventory(root, other)

    digest = Proxy.blob!(outside, "outside body")
    link = Path.join([root, "witness", "sha256", binary_part(digest, 0, 2)])
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(Path.join([outside, "witness", "sha256", binary_part(digest, 0, 2)]), link)
    assert {:error, :unsafe_path} = blob(root, digest)
  end

  test "malformed, foreign or oversized records are refused", %{root: root, id: id} do
    dir = Path.join([root, "witnesses", id])
    File.mkdir_p!(dir)
    record_id = Proxy.uuid7()
    path = Path.join(dir, record_id <> ".json")

    for {label, content} <- [
          {"not json", "not json"},
          {"other invocation", JSON.encode!(record(record_id, Proxy.uuid7()))},
          {"other record id", JSON.encode!(record(Proxy.uuid7(), id))},
          {"schema 2", JSON.encode!(Map.put(record(record_id, id), "schema_version", 2))},
          {"unknown field", JSON.encode!(Map.put(record(record_id, id), "headers", %{}))},
          {"oversized", JSON.encode!(record(record_id, id)) <> String.duplicate(" ", 70_000)}
        ] do
      File.write!(path, content)
      result = inventory(root, id)
      assert result in [{:error, :record_invalid}, {:error, :record_too_large}], label
    end
  end

  test "unexpected entries and too many records are refused", %{root: root, id: id} do
    dir = Path.join([root, "witnesses", id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "notes.txt"), "x")
    assert {:error, :record_invalid} = inventory(root, id)
    File.rm!(Path.join(dir, "notes.txt"))

    for _ <- 1..33, do: Proxy.exchange!(root, id, request: "{}", response: "{}")
    assert {:error, :too_many_entries} = inventory(root, id)
  end

  test "blobs are digest-addressed, size-capped and hash-verified", %{root: root} do
    digest = Proxy.blob!(root, "body")
    path = Path.join([root, "witness", "sha256", binary_part(digest, 0, 2), digest <> ".json"])
    File.write!(path, "tampered")
    assert {:error, :blob_corrupt} = blob(root, digest)
    assert {:error, :blob_missing} = blob(root, String.duplicate("ab", 32))
    assert {:error, :invalid_digest} = blob(root, "../../etc/passwd")
    assert {:error, :invalid_digest} = blob(root, String.upcase(digest))
    # The legacy preview namespace is never read as raw evidence.
    legacy = Path.join([root, "sha256", binary_part(digest, 0, 2)])
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, digest <> ".json"), "body")
    assert {:error, :blob_corrupt} = blob(root, digest)
  end

  defp record(record_id, invocation_id),
    do:
      Proxy.record(record_id, invocation_id,
        phase: :terminal,
        request_sha256: nil,
        response_sha256: nil
      )

  defp tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&{&1, File.lstat!(&1).size, File.lstat!(&1).mode})
    |> Enum.sort()
  end

  # A missing S12c interface fails the scenario's own assertion.
  defp inventory(root, id), do: call(:inventory, [root, id])
  defp blob(root, digest), do: call(:blob, [root, digest])

  defp call(function, args) do
    if Code.ensure_loaded?(@store) and function_exported?(@store, function, length(args)),
      do: apply(@store, function, args),
      else: {:error, {:not_implemented, function}}
  end
end
