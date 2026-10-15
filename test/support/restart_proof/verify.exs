# C9-04 restart proof, phase 2, in a fresh BEAM: read back what phase 1
# committed and admit against it. Writes one JSON result and exits 0 only
# when every check holds. Usage: mix run --no-compile verify.exs DATABASE IN_JSON OUT_JSON
Code.require_file("common.exs", __DIR__)

require Ash.Query

alias SdrAgent.{Accounts, Actor, Agents, AgentsFixtures, RestartProof}
alias SdrAgent.Agents.Admission.Refused

[database, input, out] = System.argv()
:ok = RestartProof.connect!(database)
setup = JSON.decode!(File.read!(input))
^database = setup["database"]

seeder = Actor.system(:seeder, setup["tenant_id"], "restart-proof")
{:ok, admin} = Accounts.get_user(setup["admin_id"], actor: seeder)
{:ok, grant} = Agents.get_grant(setup["grant_id"], actor: admin)
by_key = Map.new(grant.allocations, &{to_string(&1.key), &1})
tenant = SdrAgent.AuditCase.bootstrap!()
true = tenant.id == setup["tenant_id"]

counts = fn ->
  Map.new(by_key, fn {key, a} -> {key, RestartProof.consumed(allocation_id: a.id)} end)
end

before = counts.()
assignment = AgentsFixtures.running_run(tenant, usage_origin: :assignment)
reply = AgentsFixtures.running_run(tenant, usage_origin: :reply)

{b5_full, b1_next, b1_full} =
  SdrAgent.AdmissionFixtures.admitting(fn ->
    {RestartProof.reserve(reply, "verify-b5"), RestartProof.reserve(assignment, "verify-b1"),
     RestartProof.reserve(assignment, "verify-b1-again")}
  end)

after_counts = counts.()
b1_id = by_key["b1"].id
grant_id = grant.id

checks = %{
  "grant_revision_persisted" => grant.revision == setup["grant_revision"],
  "total_attempts_persisted" => grant.total_attempts == setup["total_attempts"],
  "allocations_persisted" => RestartProof.allocations(grant) == setup["allocations"],
  "workshop_release_persisted" => not is_nil(by_key["workshop"].released_at),
  "setup_charges_still_counted" => before == %{"b1" => 1, "b5" => 1, "workshop" => 0},
  "setup_charges_bound_to_their_allocations" =>
    setup["invocations"]["b1"]["allocation_id"] == by_key["b1"].id and
      setup["invocations"]["b5"]["allocation_id"] == by_key["b5"].id,
  "full_b5_refused_exactly" =>
    match?({:error, %Refused{reason: {:budget_exhausted, :allocation}}}, b5_full),
  "next_b1_charged_to_b1" =>
    match?({:ok, %{allocation_id: ^b1_id, grant_id: ^grant_id}}, b1_next),
  "full_b1_refused_exactly" =>
    match?({:error, %Refused{reason: {:budget_exhausted, :allocation}}}, b1_full),
  "no_borrowing_or_extra_debit" => after_counts == %{"b1" => 2, "b5" => 1, "workshop" => 0},
  "grant_total_counted" => RestartProof.consumed(grant_id: grant.id) == 3
}

ok = Enum.all?(checks, fn {_, v} -> v end)
File.write!(out, JSON.encode!(%{"ok" => ok, "checks" => checks}))
System.halt(if ok, do: 0, else: 1)
