defmodule SdrAgent.Demo.StatusTest do
  @moduledoc """
  The demo health report behind `bin/demo status`: database, migrations,
  seed state, Oban queues, pipeline counts and the audit chain — counts
  only, read as the read-only auditor CLI actor.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Demo.SigningKey
  alias SdrAgent.Demo.Status

  test "an empty database is reachable, migrated and reported as not seeded" do
    report = Status.report()

    assert report.database == :reachable
    assert report.migrations.pending == []
    assert report.migrations.applied > 0
    assert report.tenant == :not_bootstrapped
    assert report.chain == nil
    refute Status.ready?(report)
    assert "tenant: NOT SEEDED (run bin/demo seed)" in Status.format(report)
  end

  test "lists every configured Oban queue with its job counts by state" do
    report = Status.report(queues: [research: 20, delivery: 5])

    assert [%{queue: "research", limit: 20, jobs: %{}}, %{queue: "delivery", limit: 5}] =
             report.queues
  end

  test "after the seed: leads by status, empty review and capture, a valid chain" do
    {:ok, _} = Seed.run()
    {:ok, _} = SigningKey.ensure()

    report = Status.report()
    suppressed = length(Fixtures.suppressed_contact_emails())

    assert report.tenant == :seeded
    assert Status.ready?(report)
    assert report.leads == %{new: length(Fixtures.leads()) - suppressed, stopped: suppressed}
    assert report.drafts_pending_review == 0
    assert report.captured_messages == 0
    assert %{valid?: true, issues: 0, last_sequence: last} = report.chain
    assert last > 0

    lines = Status.format(report)
    assert "drafts awaiting review: 0" in lines
    assert "audit chain: valid (#{last} events)" in lines
  end

  test "a bootstrapped tenant without the fixture data is not ready" do
    bootstrap!()

    report = Status.report()

    assert report.tenant == :incomplete
    refute Status.ready?(report)
    assert "tenant: SEED INCOMPLETE (run bin/demo seed)" in Status.format(report)
  end

  test "without the audit signing key registered the demo is not ready" do
    {:ok, _} = Seed.run()

    report = Status.report()

    assert report.signing_key == :missing
    refute Status.ready?(report)
    assert "signing key: NOT REGISTERED (run bin/demo seed)" in Status.format(report)

    {:ok, _} = SigningKey.ensure()
    report = Status.report()
    assert report.signing_key == :registered
    assert Status.ready?(report)
    assert "signing key: registered" in Status.format(report)
  end

  test "a chain that does not verify is not ready" do
    {:ok, _} = Seed.run()
    tamper!("UPDATE audit_events SET payload = '{\"tampered\": true}' WHERE sequence = 2")

    report = Status.report()

    assert report.tenant == :seeded
    assert %{valid?: false} = report.chain
    refute Status.ready?(report)
  end

  test "a report without a chain verification is not ready" do
    {:ok, _} = Seed.run()
    report = %{Status.report() | chain: nil}

    refute Status.ready?(report)
  end

  test "the formatted report carries no secret: no fixture password appears" do
    {:ok, _} = Seed.run()
    text = Enum.join(Status.format(Status.report()), "\n")

    for %{password: password} <- Fixtures.users() do
      refute text =~ password
    end
  end

  test "an unreachable database is reported without domain counts" do
    report = %{
      database: {:unreachable, "connection refused"},
      migrations: :unknown,
      tenant: :unknown,
      queues: [],
      leads: %{},
      drafts_pending_review: nil,
      captured_messages: nil,
      chain: nil
    }

    refute Status.ready?(report)

    assert Status.format(report) == [
             "database: UNREACHABLE (connection refused)",
             "migrations: unknown",
             "tenant: unknown"
           ]
  end
end
