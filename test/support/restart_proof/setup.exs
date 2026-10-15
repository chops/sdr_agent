# C9-04 restart proof, phase 1: commit a grant, its allocations, a release
# and two charged reservations through the domain APIs, record their ids,
# then exit. Usage: mix run --no-compile setup.exs DATABASE OUT_JSON
Code.require_file("common.exs", __DIR__)

alias SdrAgent.{Agents, AgentsFixtures, AuditCase, RestartProof}

[database, out] = System.argv()
:ok = RestartProof.connect!(database)

tenant = AuditCase.bootstrap!()
admin = AuditCase.human(:admin, tenant)

{:ok, grant} =
  Agents.create_grant(
    %{
      name: "G-RESTART",
      purpose: "Synthetic restart proof",
      profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
      total_attempts: 6,
      starts_at: ~U[2026-10-12 00:00:00.000000Z],
      expires_at: ~U[2026-11-06 00:00:00.000000Z],
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 2},
        %{key: :b5, applies_to: [:b5], attempts: 1},
        %{
          key: :workshop,
          applies_to: [:b2],
          attempts: 1,
          available_from: ~U[2026-11-01 00:00:00.000000Z]
        }
      ]
    },
    actor: admin
  )

{:ok, grant} =
  Agents.release_allocation(grant, %{expected_revision: 1, key: :workshop}, actor: admin)

assignment = AgentsFixtures.running_run(tenant, usage_origin: :assignment)
reply = AgentsFixtures.running_run(tenant, usage_origin: :reply)

{:ok, first} =
  SdrAgent.AdmissionFixtures.admitting(fn ->
    with {:ok, b1} <- RestartProof.reserve(assignment, "setup-b1"),
         {:ok, b5} <- RestartProof.reserve(reply, "setup-b5") do
      {:ok, %{"b1" => b1, "b5" => b5}}
    end
  end)

record = %{
  "database" => database,
  "tenant_id" => tenant.id,
  "admin_id" => admin.id,
  "grant_id" => grant.id,
  "grant_revision" => grant.revision,
  "total_attempts" => grant.total_attempts,
  "allocations" => RestartProof.allocations(grant),
  "invocations" =>
    Map.new(first, fn {key, inv} ->
      {key, %{"id" => inv.id, "allocation_id" => inv.allocation_id}}
    end)
}

File.write!(out, JSON.encode!(record))
