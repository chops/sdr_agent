defmodule SdrAgent.Agents.WitnessV4LineageRaceTest do
  @moduledoc """
  Witness response-block plan r5, T4 group 3 (section 6.5, technical MF3;
  ADR-0005 response-layout amendment item 6, D-182), on real connections
  (`sandbox: false`): a v4 reconciliation write and a mismatch writer
  race on one exchange whose head is a non-mismatch v3 link.

  Each test runs one serial order. The first writer links its successor
  inside an open transaction, so it holds the invocation row `FOR UPDATE`
  (`WitnessLineage`), and waits. The second writer, which read the same
  head, is started and is observed blocked behind the first writer's
  backend (`pg_blocking_pids`). The first writer then commits. The second
  writer's stale-head write is refused (it no longer names the current
  head), which the test asserts explicitly; it never assumes both writes
  commit. The second writer then retries once against the fresh head:

    * mismatch first: the v4 retry is refused (a v4 successor never
      supersedes a mismatch head), so the mismatch stays current;
    * v4 first: the mismatch retry supersedes the v4 head, so the mismatch
      becomes current.

  Either way the lineage is one chain with a single head and no fork, a
  current mismatch is never weakened, and every committed link has exactly
  one `agents.witness.linked` event.

  Fixtures: one owned synthetic tenant per test (the E1 race harness of
  `OrdinaryLaunchRaceTest`), cleaned by bounded tenant-scoped deletes,
  never a broad `TRUNCATE`; committed provenance snapshots are kept.
  Participants are supervised, bounded and always joined.

  RED: each test first asserts that `Projection.version_v4/0` exists. That
  presence guard is a structural failure only; it is not evidence that the
  race ran or that the lineage rule holds under it.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo

  @bound 20_000
  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"

  setup do
    AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    {:ok, tenant} = Audit.bootstrap(slug: "v4-lineage-race", name: "Synthetic V4 Lineage Race")
    admin = AuditCase.human(:admin, tenant)
    on_exit(fn -> with_connection(fn -> cleanup!(tenant, admin) end) end)
    supervisor = start_supervised!(Task.Supervisor)

    AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    invocation = AgentsFixtures.claude_completed!(run, agent, "v4-lineage-race")
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)

    {:ok, root} =
      Agents.link_wire_witness(
        %{
          model_invocation_id: invocation.id,
          proxy_record_ref: Ash.UUIDv7.generate(),
          link_status: :inferred,
          method: :propagated_id,
          evidence: evidence(invocation, @v3)
        },
        actor: rec
      )

    %{
      tenant: tenant,
      invocation: invocation,
      rec: rec,
      root: root,
      supervisor: supervisor
    }
  end

  test "mismatch first: the stale v4 write is refused, its retry is refused; the mismatch stays",
       ctx do
    assert v4_supported?(), "structural RED: Projection.version_v4/0 is not implemented"

    {first, second} =
      race(ctx, &write(ctx, :mismatch, &1), fn head -> write(ctx, :v4, head) end)

    assert {:ok, mismatch} = first
    assert {:stale, stale, retry} = second
    assert lineage_refused?(stale), "stale v4 write: #{inspect(stale)}"

    assert lineage_refused?(retry),
           "a v4 successor never supersedes a mismatch: #{inspect(retry)}"

    assert_single_chain(ctx, [ctx.root.id, mismatch.id])
    assert {:ok, [current]} = current_links(ctx)
    assert {current.id, current.link_status} == {mismatch.id, :mismatch}
  end

  test "v4 first: the stale mismatch write is refused, its retry supersedes the v4 head", ctx do
    assert v4_supported?(), "structural RED: Projection.version_v4/0 is not implemented"

    {first, second} =
      race(ctx, &write(ctx, :v4, &1), fn head -> write(ctx, :mismatch, head) end)

    assert {:ok, v4} = first
    assert v4.evidence["projection_version"] == @v4
    assert {:stale, stale, {:ok, mismatch}} = second
    assert lineage_refused?(stale), "stale mismatch write: #{inspect(stale)}"
    assert mismatch.supersedes_id == v4.id

    assert_single_chain(ctx, [ctx.root.id, v4.id, mismatch.id])
    assert {:ok, [current]} = current_links(ctx)
    assert {current.id, current.link_status} == {mismatch.id, :mismatch}
  end

  ## The race

  # `first` writes inside a held transaction; `second` is started against the
  # same (soon stale) head and must block behind `first`'s backend. After
  # `first` commits, `second`'s stale write is collected and, when refused,
  # retried once against the fresh current head. Returns `{first_result,
  # {:stale, stale_result, retry_result} | {:committed, result}}`.
  defp race(ctx, first_fun, second_fun) do
    head = ctx.root
    first = holder(ctx, :first, fn -> first_fun.(head) end)
    joined([first], fn -> race_second(ctx, first, head, second_fun) end)
  end

  defp race_second(ctx, first, head, second_fun) do
    second = participant(ctx, :second, fn -> stale_then_retry(ctx, head, second_fun) end)

    joined([second], fn ->
      await_blocked(second, first)
      release(first)
      first_result = await(first)
      {first_result, await(second)}
    end)
  end

  # The write against the (stale) head; when refused, one retry against the
  # fresh current head.
  defp stale_then_retry(ctx, head, second_fun) do
    case second_fun.(head) do
      {:ok, _} = committed ->
        {:committed, committed}

      stale ->
        {:ok, [fresh]} = current_links(ctx)
        {:stale, stale, second_fun.(fresh)}
    end
  end

  defp write(ctx, kind, head) do
    {status, evidence} =
      case kind do
        :mismatch -> {:mismatch, evidence(ctx.invocation, @v3)}
        :v4 -> {:reconciled, evidence(ctx.invocation, @v4)}
      end

    Agents.link_wire_witness(
      %{
        model_invocation_id: head.model_invocation_id,
        proxy_record_ref: head.proxy_record_ref,
        link_status: status,
        method: :propagated_id,
        supersedes_id: head.id,
        evidence: Map.put(evidence, "supersede_reason", "reconciliation_rerun")
      },
      actor: ctx.rec
    )
  end

  defp evidence(invocation, version) do
    base =
      invocation
      |> WitnessEvidence.identity()
      |> Map.merge(%{
        "witness_schema" => 1,
        "classification" => "primary",
        "projection_version" => version,
        "reason_codes" => ["cli_injected_context"],
        "projections_inapplicable" => ["v2"],
        "reminder_count" => 0,
        "reminder_sha256s" => [],
        "reminder_bytes" => [],
        "trailing_system_count" => 0,
        "trailing_system_sha256s" => [],
        "trailing_system_bytes" => [],
        "request_extras_sha256" => String.duplicate("c3", 32),
        "request_fields" => [],
        "trailing_output_config" => []
      })

    if version == @v4,
      do:
        Map.merge(base, %{
          "response_layout" => "reasoning_then_text",
          "response_thinking_count" => 1,
          "response_redacted_thinking_count" => 0
        }),
      else: base
  end

  defp v4_supported? do
    Code.ensure_loaded(Projection)
    function_exported?(Projection, :version_v4, 0)
  end

  defp current_links(ctx),
    do: Agents.current_wire_witness_links(ctx.invocation.id, actor: ctx.rec)

  defp lineage_refused?({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.any?(errors, &match?(%{field: :supersedes_id}, &1))

  defp lineage_refused?(_result), do: false

  # Exactly `ids`, each superseding the previous one (no fork), and exactly
  # one link event per committed link; the audit chain stays valid.
  defp assert_single_chain(ctx, ids) do
    {:ok, links} = Agents.list_wire_witness_links(ctx.invocation.id, actor: ctx.rec)
    by_id = Map.new(links, &{&1.id, &1})
    assert Enum.sort(Map.keys(by_id)) == Enum.sort(ids), inspect(Enum.map(links, & &1.id))

    for {previous, id} <- Enum.zip([nil | ids], ids),
        do: assert(by_id[id].supersedes_id == previous, inspect(by_id[id]))

    auditor = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
    {:ok, events} = Audit.list_events(actor: auditor)

    linked =
      Enum.filter(
        events,
        &(&1.event_type == "agents.witness.linked" and &1.model_invocation_id == ctx.invocation.id)
      )

    assert Enum.sort(Enum.map(linked, & &1.subject_id)) == Enum.sort(ids)
    {:ok, report} = Audit.verify_chain(actor: auditor)
    assert report.valid?, inspect(report.issues)
  end

  ## Participants (the E1 race harness)

  defp participant(ctx, tag, fun) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        with_connection(fn ->
          send(parent, {:backend, tag, backend()})
          fun.()
        end)
      end)

    assert_receive {:backend, ^tag, backend}, @bound
    {task, backend}
  end

  # Runs `write` in a transaction, reports, holds until `:go` (bounded), then
  # commits; a failed write rolls back and is returned as is.
  defp holder(ctx, tag, write) do
    parent = self()
    held = participant(ctx, tag, fn -> hold(parent, tag, write) end)
    assert_receive {:held, ^tag}, @bound
    held
  end

  defp hold(parent, tag, write) do
    Audit.transaction(fn ->
      result = write.()
      send(parent, {:held, tag})
      hold_result(result)
    end)
  end

  defp hold_result({:ok, link}) do
    receive do
      :go -> link
    after
      @bound -> Repo.rollback(:holder_timeout)
    end
  end

  defp hold_result(error), do: Repo.rollback({:write_failed, error})

  defp release({task, _backend}), do: send(task.pid, :go)

  defp await({task, _backend}) do
    case Task.yield(task, @bound) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      other -> flunk("participant did not finish: #{inspect(other)}")
    end
  end

  defp joined(participants, fun) do
    fun.()
  after
    Enum.each(participants, fn {task, _} -> Task.shutdown(task, :brutal_kill) end)
  end

  defp backend, do: hd(hd(SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows))

  defp await_blocked(waiter, blocker, attempts \\ 400)

  defp await_blocked({_, waiter}, {_, blocker}, 0),
    do: flunk("backend #{waiter} was never blocked by #{blocker}")

  defp await_blocked({_, waiter} = w, {_, blocker} = b, attempts) do
    %{rows: [[blocked?]]} =
      SQL.query!(Repo, "SELECT $2::int = ANY(pg_blocking_pids($1::int))", [waiter, blocker])

    unless blocked? do
      Process.sleep(25)
      await_blocked(w, b, attempts - 1)
    end
  end

  ## Fixture database and bounded cleanup

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp assert_test_database! do
    expected = "sdr_agent_test" <> (System.get_env("MIX_TEST_PARTITION") || "")
    assert Mix.env() == :test
    assert Repo.config()[:database] == expected
    assert %{rows: [[^expected]]} = SQL.query!(Repo, "SELECT current_database()", [])
  end

  # Only this fixture's tenant rows and its user's tokens; never another
  # tenant's data and never global provenance snapshots.
  defp cleanup!(tenant, admin) do
    assert_test_database!()
    tenant_id = Ecto.UUID.dump!(tenant.id)
    tables = tenant_tables()

    assert {:ok, _} =
             Repo.transaction(fn ->
               SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])
               subject = AshAuthentication.user_to_subject(admin)
               SQL.query!(Repo, "DELETE FROM tokens WHERE subject = $1", [subject])
               Enum.each(tables, &delete_tenant_rows!(&1, tenant_id))

               assert %{num_rows: 1} =
                        SQL.query!(Repo, "DELETE FROM tenants WHERE id = $1", [tenant_id])
             end)

    for table <- tables do
      assert %{rows: [[0]]} =
               SQL.query!(Repo, "SELECT count(*) FROM \"#{table}\" WHERE tenant_id = $1", [
                 tenant_id
               ])
    end
  end

  defp tenant_tables do
    SQL.query!(
      Repo,
      "SELECT c.table_name FROM information_schema.columns c " <>
        "JOIN information_schema.tables t USING (table_schema, table_name) " <>
        "WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE' " <>
        "AND c.column_name = 'tenant_id' AND c.table_name <> 'tenants' ORDER BY c.table_name",
      []
    ).rows
    |> List.flatten()
  end

  defp delete_tenant_rows!(table, tenant_id),
    do: SQL.query!(Repo, ~s(DELETE FROM "#{table}" WHERE tenant_id = $1), [tenant_id])
end
