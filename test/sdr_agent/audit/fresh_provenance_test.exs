defmodule SdrAgent.Audit.FreshProvenanceTest do
  @moduledoc """
  #178: `SdrAgent.AuditCase.fresh_provenance!/0` changes the VM's
  provenance identity for one test and restores the exact previous state:
  the test-only nonce's value or absence, and the
  `SdrAgent.Audit.Provenance` cache's value or absence.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit.Provenance

  @cache {Provenance, :current}
  @nonce :__test_provenance_nonce__

  # Every test leaves the global state as it found it.
  setup do
    nonce = Application.fetch_env(:sdr_agent, @nonce)
    cache = :persistent_term.get(@cache, provenance_absent())
    on_exit(fn -> restore_provenance(nonce, cache) end)
    :ok
  end

  test "gives a new provenance identity for the test" do
    before = Provenance.current()
    fresh = fresh_provenance!()
    assert fresh.snapshot_sha256 != before.snapshot_sha256
    assert Provenance.current() == fresh
    assert {:ok, "nonce-" <> _} = Application.fetch_env(:sdr_agent, @nonce)
  end

  test "restores an absent nonce and a present cache" do
    Application.delete_env(:sdr_agent, @nonce)
    cached = Provenance.current()

    restore_provenance(:error, cached)

    assert Application.fetch_env(:sdr_agent, @nonce) == :error
    assert :persistent_term.get(@cache, provenance_absent()) == cached
  end

  test "restores a pre-existing nonce value and an absent cache" do
    Application.put_env(:sdr_agent, @nonce, "changed")
    _ = Provenance.current()

    restore_provenance({:ok, "pre-existing"}, provenance_absent())

    assert Application.fetch_env(:sdr_agent, @nonce) == {:ok, "pre-existing"}
    assert :persistent_term.get(@cache, provenance_absent()) == provenance_absent()
  end

  # The helper's own registered cleanup, run by ExUnit: an observer
  # registered *before* the helper runs after it (on_exit is LIFO), and the
  # module's setup restoration, registered first, still runs last.
  test "its registered cleanup restores an absent nonce and a present cache" do
    Application.delete_env(:sdr_agent, @nonce)
    cached = Provenance.current()

    on_exit(fn ->
      assert Application.fetch_env(:sdr_agent, @nonce) == :error
      assert :persistent_term.get(@cache, provenance_absent()) == cached
    end)

    fresh = fresh_provenance!()
    assert fresh != cached
    assert {:ok, _nonce} = Application.fetch_env(:sdr_agent, @nonce)
  end

  test "its registered cleanup restores a pre-existing nonce and an absent cache" do
    Application.put_env(:sdr_agent, @nonce, "pre-existing")
    :persistent_term.erase(@cache)

    on_exit(fn ->
      assert Application.fetch_env(:sdr_agent, @nonce) == {:ok, "pre-existing"}
      assert :persistent_term.get(@cache, provenance_absent()) == provenance_absent()
    end)

    _fresh = fresh_provenance!()
    refute Application.fetch_env(:sdr_agent, @nonce) == {:ok, "pre-existing"}
    assert %{} = :persistent_term.get(@cache, provenance_absent())
  end
end
