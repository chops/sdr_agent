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

  test "after a helper run, its registered cleanup restores both exactly" do
    Application.put_env(:sdr_agent, @nonce, "pre-existing")
    :persistent_term.erase(@cache)
    previous = {Application.fetch_env(:sdr_agent, @nonce), provenance_absent()}

    # The helper's own cleanup, applied to the state it captured.
    _fresh = fresh_provenance!()
    restore_provenance(elem(previous, 0), elem(previous, 1))

    assert Application.fetch_env(:sdr_agent, @nonce) == {:ok, "pre-existing"}
    assert :persistent_term.get(@cache, provenance_absent()) == provenance_absent()
  end
end
