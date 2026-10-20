# C3-02 migration proof: one phase, in a fresh BEAM without the application.
#
#   before     migrate up to, excluding, the additive migration;
#   prechecks  commit the planned pre-cutover rows (a canonical domain
#              collision, and a contact covered by a domain suppression with
#              an open lead), then attempt the additive migration;
#   fence      delete one account of the collision, then attempt it again;
#   clean      delete the covering suppression, then attempt it again.
#
# Rows are written as a database administrator (session_replication_role
# replica, as `SdrAgent.AuditCase.tamper!/2`), with query logging off, so no
# planned value reaches the output. The attempt runs `Ecto.Migrator.run/3` up
# to the additive migration's version only, in a monitored process: the
# migration's own exception is the outcome. Writes one JSON result: the
# outcome (the exception's module, message and counts, or the versions
# applied), the DDL facts after it, and per-row digests before and after it.
#
# Usage: mix run --no-start step.exs DATABASE PHASE PLAN_JSON OUT_JSON
Code.require_file("common.exs", __DIR__)

defmodule SdrAgent.MigrationProof.Step do
  @moduledoc false

  alias SdrAgent.MigrationProof.Harness

  @admin "SET LOCAL session_replication_role = replica"

  @facts_sql """
  SELECT
    EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1) AS version_applied,
    to_regprocedure('public.sdr_canonical_domain(text)') IS NOT NULL AS canonical_function,
    to_regclass('public.lead_admissions') IS NOT NULL AS lead_admissions_table,
    to_regclass('public.accounts_canonical_domain_index') IS NOT NULL AS canonical_index,
    to_regclass('public.leads_one_open_per_account_index') IS NOT NULL
      AS one_open_per_account_index,
    EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'leads'
               AND column_name = 'admission_id') AS leads_admission_id,
    EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_id_tenant_key')
      AS users_id_tenant_key,
    EXISTS (SELECT 1 FROM pg_constraint
             WHERE conname = 'leads_status'
               AND pg_get_constraintdef(oid) LIKE '%''referred''%') AS referred_status
  """

  # {plan key, table} of every planned row.
  @rows [
    {"collision_www_id", "accounts"},
    {"collision_plain_id", "accounts"},
    {"fence_account_id", "accounts"},
    {"contact_id", "contacts"},
    {"lead_id", "leads"},
    {"suppression_id", "suppressions"}
  ]

  def run(repo, "before", _plan) do
    _ = Ecto.Migrator.run(repo, :up, to_exclusive: Harness.version(), log: false)
    %{"phase" => "before", "facts" => facts(repo)}
  end

  def run(repo, "prechecks", plan) do
    admin!(repo, fn -> seed!(repo, plan) end)
    attempt(repo, plan, "prechecks")
  end

  def run(repo, "fence", plan) do
    admin!(repo, fn ->
      one!(repo, "DELETE FROM accounts WHERE id = $1", [uuid(plan, "collision_plain_id")])
    end)

    attempt(repo, plan, "fence")
  end

  def run(repo, "clean", plan) do
    admin!(repo, fn ->
      one!(repo, "DELETE FROM suppressions WHERE id = $1", [uuid(plan, "suppression_id")])
    end)

    attempt(repo, plan, "clean")
  end

  defp seed!(repo, plan) do
    account = """
    INSERT INTO accounts (id, tenant_id, name, domain, source, status, trace_id, span_id,
                          inserted_at, updated_at)
    VALUES ($1, $2, 'C3-02 migration proof', $3, 'manual', 'active', $4, $5, now(), now())
    """

    one!(repo, account, [
      uuid(plan, "collision_www_id"),
      uuid(plan, "collision_tenant_id"),
      plan["collision_www_domain"] | trace()
    ])

    one!(repo, account, [
      uuid(plan, "collision_plain_id"),
      uuid(plan, "collision_tenant_id"),
      plan["collision_plain_domain"] | trace()
    ])

    one!(repo, account, [
      uuid(plan, "fence_account_id"),
      uuid(plan, "fence_tenant_id"),
      plan["fence_domain"] | trace()
    ])

    one!(
      repo,
      """
      INSERT INTO contacts (id, tenant_id, account_id, first_name, last_name, email, trace_id,
                            span_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'Proof', 'Contact', $4, $5, $6, now(), now())
      """,
      [
        uuid(plan, "contact_id"),
        uuid(plan, "fence_tenant_id"),
        uuid(plan, "fence_account_id"),
        plan["email"] | trace()
      ]
    )

    one!(
      repo,
      """
      INSERT INTO leads (id, tenant_id, account_id, contact_id, source, status, status_reason,
                         trace_id, span_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'manual', 'new', 'c302 migration proof', $5, $6, now(), now())
      """,
      [
        uuid(plan, "lead_id"),
        uuid(plan, "fence_tenant_id"),
        uuid(plan, "fence_account_id"),
        uuid(plan, "contact_id") | trace()
      ]
    )

    one!(
      repo,
      """
      INSERT INTO suppressions (id, tenant_id, scope, value, reason, effective_at, trace_id,
                                span_id, inserted_at)
      VALUES ($1, $2, 'domain', $3, 'manual', now(), $4, $5, now())
      """,
      [
        uuid(plan, "suppression_id"),
        uuid(plan, "fence_tenant_id"),
        plan["fence_domain"] | trace()
      ]
    )
  end

  defp attempt(repo, plan, phase) do
    before = digests(repo, plan)
    outcome = migrate(repo)

    %{
      "phase" => phase,
      "outcome" => outcome,
      "facts" => facts(repo),
      "rows_before" => before,
      "rows_after" => digests(repo, plan)
    }
  end

  # The migrator's own process (and its migration task) ends with the
  # migration's exception; the versions are sent only after a normal return.
  defp migrate(repo) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        versions = Ecto.Migrator.run(repo, :up, to: Harness.version(), log: false)
        send(parent, {:ran, self(), versions})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        receive do
          {:ran, ^pid, versions} -> %{"result" => "applied", "versions" => versions}
        after
          0 -> aborted(reason)
        end
    end
  end

  defp aborted(reason) do
    case exception(reason) do
      %{__exception__: true} = error ->
        %{
          "result" => "aborted",
          "module" => inspect(error.__struct__),
          "message" => Exception.message(error),
          "counts" => Map.get(error, :counts)
        }

      nil ->
        %{"result" => "crashed", "reason" => inspect(reason, limit: 20)}
    end
  end

  defp exception({%{__exception__: true} = error, _stacktrace}), do: error
  defp exception({{%{__exception__: true} = error, _stacktrace}, _await}), do: error
  defp exception(_reason), do: nil

  defp facts(repo) do
    %{columns: columns, rows: [row]} = repo.query!(@facts_sql, [Harness.version()], log: false)
    columns |> Enum.zip(row) |> Map.new()
  end

  defp digests(repo, plan) do
    Map.new(@rows, fn {key, table} ->
      sql = "SELECT to_jsonb(t)::text FROM #{table} AS t WHERE t.id = $1"
      %{rows: rows} = repo.query!(sql, [uuid(plan, key)], log: false)

      digest =
        case rows do
          [[json]] -> :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
          [] -> "absent"
        end

      {key, digest}
    end)
  end

  defp admin!(repo, fun) do
    {:ok, _} =
      repo.transaction(fn ->
        repo.query!(@admin, [], log: false)
        fun.()
      end)

    :ok
  end

  defp one!(repo, sql, params) do
    %{num_rows: 1} = repo.query!(sql, params, log: false)
  end

  defp uuid(plan, key), do: Ecto.UUID.dump!(Map.fetch!(plan, key))

  defp trace,
    do: [hex(:crypto.strong_rand_bytes(16)), hex(:crypto.strong_rand_bytes(8))]

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end

[database, phase, plan_path, out] = System.argv()
SdrAgent.MigrationProof.validate_target!(database)
plan = JSON.decode!(File.read!(plan_path))
^database = plan["database"]

{:ok, result, _apps} =
  Ecto.Migrator.with_repo(
    SdrAgent.Repo,
    &SdrAgent.MigrationProof.Step.run(&1, phase, plan),
    mode: :temporary
  )

File.write!(out, JSON.encode!(result))
