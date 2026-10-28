defmodule SdrAgent.Prototype.AdmissionOriginTest do
  @moduledoc """
  RED-b2 r6, the trusted admission origin at raw `:reserve` (Codex
  ff812f6d ruling c; Codex 3603b76f M2; Codex 92332009 N2; mechanism note
  r3 section B), D-237 slice S2, in prototype runtime with S1's real
  provisioning.

  A registration exists only as `Admission.admit/5` returns it with an
  admitted charge in prototype runtime (no public register function). Each
  case builds the `:reserve` changeset as `Agents.reserve_model_invocation/3`
  does, inside one transaction, with the ONE admitted instant passed to
  `admit/5` reused as the charge's `reserved_at`:

  - repeated `Ash.can?/2` (build-time verification) leaves the registration
    available; one insert consumes it; a second raw write is Forbidden;
  - a valid registration authorizes no other run, profile or purpose;
  - a registration is invalid in another process, after a literal
    `ROLLBACK TO SAVEPOINT` (the connection stays usable), and once its
    owner discarded it after its callback. Sandboxed transaction callbacks
    are SAVEPOINTs sharing one PostgreSQL xid (Codex 3b2e8c61 N1), so no test
    here proves a real top-level transaction boundary: that proof is OWED
    to an approved isolated harness;
  - `pending/0` (this process's owned registrations: live, stale and
    consumed) returns to its pre-call value after a reservation succeeds,
    after a gate refusal, after a Forbidden caller authority and after a
    rolled-back insert (a real first success, then a duplicate idempotency
    key).

  Direct `admit/5` calls are cleaned up by the test itself, in `after`,
  with `discard/1` (note r3). A raise inside the reserve is UNTESTED here:
  it has no public trigger without a new seam, and none is added; its
  cleanup stays owed. The registry API (`registered?/1`, `pending/0`,
  `discard/1`) and the charge's `:registration` do not exist yet: each is
  asserted first, and a missing one is a STRUCTURAL failure, never a
  reached behavioural RED.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.Repo

  setup do
    fx = G.prototype!()
    %{fx: fx, run: G.run!(fx)}
  end

  ## Helpers

  # A function of the registry API, asserted exported first (structural).
  defp api!(fun, arity) do
    assert Code.ensure_loaded?(AdmissionContext) and
             function_exported?(AdmissionContext, fun, arity),
           "structural: AdmissionContext.#{fun}/#{arity} is not exported"

    Function.capture(AdmissionContext, fun, arity)
  end

  # `Admission.admit/5` for an in-scope call in `run`, at one captured
  # instant, inside the caller's transaction: `{charge, admitted_at}`. The
  # charge must carry its registration (structural).
  defp admit!(ctx, run, call \\ %{}) do
    call =
      Map.merge(
        %{
          profile_id: :claude_cli_opus,
          purpose: :qualification,
          idempotency_key: "origin-#{System.unique_integer([:positive])}"
        },
        call
      )

    admitted_at = SdrAgent.Clock.utc_now()
    gate = %{store: Gate.observe_store(), calibration: nil}
    result = Admission.admit(run, call, admitted_at, [ctx.fx.grant.id], gate)
    assert match?({:ok, %{}}, result), "prerequisite: admit: #{inspect(result)}"
    {:ok, charge} = result

    assert Map.has_key?(charge, :registration),
           "structural: Admission.admit/5 returns no :registration"

    {charge, admitted_at}
  end

  # The charge's registration: a key admit/5 does not return yet (asserted
  # present first, structural), read dynamically so the test compiles
  # against today's inferred return type.
  defp registration(charge), do: Function.capture(Map, :fetch!, 2).(charge, :registration)

  # Every registration a direct admit!/3 made in `fun` is discarded after it,
  # whatever happens: the test owns that cleanup.
  defp owned(fun) do
    discard = api!(:discard, 1)
    Process.put(:owned_registrations, [])

    try do
      fun.()
    after
      for registration <- Process.get(:owned_registrations, []), do: discard.(registration)
      Process.delete(:owned_registrations)
    end
  end

  defp own!({charge, _admitted_at} = admitted) do
    Process.put(:owned_registrations, [
      registration(charge) | Process.get(:owned_registrations, [])
    ])

    admitted
  end

  # A Fake seed (outside the transaction) for the request digest.
  defp seed!(ctx, run) do
    result =
      Agents.reserve_model_invocation(
        run,
        AgentsFixtures.model_attrs("origin-seed-#{System.unique_integer([:positive])}"),
        actor: ctx.fx.agent
      )

    assert match?({:ok, _}, result), "prerequisite: Fake seed: #{inspect(result)}"
    {:ok, seed} = result
    seed
  end

  defp changeset(ctx, run, seed, {charge, admitted_at}, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      "origin-#{n}"
      |> AgentsFixtures.claude_attrs()
      |> Map.drop([:request])
      |> Map.merge(%{
        agent_run_id: run.id,
        sequence_in_run: 100 + n,
        request_sha256: seed.request_sha256
      })
      |> Map.merge(overrides)

    Ash.Changeset.for_create(ModelInvocation, :reserve, attrs,
      actor: ctx.fx.agent,
      context: AdmissionContext.context(Map.put(charge, :reserved_at, admitted_at))
    )
  end

  defp locked_run!(run) do
    SdrAgent.Agents.AgentRun
    |> Ash.Query.filter(id == ^run.id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one!(authorize?: false)
  end

  defp claude_invocations(fx) do
    ModelInvocation
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id and provider == :claude_cli)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  defp in_transaction(fun) do
    result = SdrAgent.Audit.transaction(fun)
    assert match?({:ok, _}, result), "prerequisite: transaction: #{inspect(result)}"
    {:ok, value} = result
    value
  end

  ## Cases

  test "can? leaves it available; one insert consumes it; a second raw write is Forbidden",
       ctx do
    registered? = api!(:registered?, 1)
    seed = seed!(ctx, ctx.run)

    {cans, available, first, consumed, second} =
      owned(fn ->
        in_transaction(fn ->
          admitted = own!(admit!(ctx, locked_run!(ctx.run)))
          {charge, _at} = admitted
          changeset = changeset(ctx, ctx.run, seed, admitted)

          cans = [Ash.can?(changeset, ctx.fx.agent), Ash.can?(changeset, ctx.fx.agent)]
          available = registered?.(registration(charge))
          first = Ash.create(changeset)
          consumed = not registered?.(registration(charge))
          second = Ash.create(changeset(ctx, ctx.run, seed, admitted))
          {cans, available, first, consumed, second}
        end)
      end)

    assert cans == [true, true], inspect(cans)
    assert available, "can? consumed the registration"
    assert match?({:ok, %ModelInvocation{}}, first), "first insert: #{inspect(first)}"
    assert consumed, "the insert left the registration available"
    assert match?({:error, %Ash.Error.Forbidden{}}, second), "second write: #{inspect(second)}"
    assert claude_invocations(ctx.fx) == 1
  end

  test "a valid registration authorizes no other run, profile or purpose", ctx do
    other_run = G.run!(ctx.fx)
    seed = seed!(ctx, ctx.run)
    other_seed = seed!(ctx, other_run)

    outcomes =
      owned(fn ->
        for {label, {run, seed, overrides}} <- [
              run: {other_run, other_seed, %{}},
              profile: {ctx.run, seed, %{profile_id: :claude_cli_sonnet}},
              purpose: {ctx.run, seed, %{purpose: :evidence_extraction}}
            ] do
          result =
            in_transaction(fn ->
              admitted = own!(admit!(ctx, locked_run!(ctx.run)))
              Ash.create(changeset(ctx, run, seed, admitted, overrides))
            end)

          {label, result}
        end
      end)

    assert Enum.all?(outcomes, &match?({_label, {:error, %Ash.Error.Forbidden{}}}, &1)),
           inspect(outcomes)

    assert claude_invocations(ctx.fx) == 0
  end

  test "another process never sees the registration", ctx do
    registered? = api!(:registered?, 1)

    seen =
      owned(fn ->
        in_transaction(fn ->
          {charge, _at} = own!(admit!(ctx, locked_run!(ctx.run)))
          # A pure check: no database use from the task.
          Task.await(Task.async(fn -> registered?.(registration(charge)) end))
        end)
      end)

    refute seen, "another process saw the registration"
  end

  # Codex 3b2e8c61 N1: in this sandbox a transaction callback is a SAVEPOINT,
  # so two callbacks share one PostgreSQL xid. This test does NOT prove a real
  # transaction boundary (that proof is OWED to an approved isolated
  # harness); it proves the owner's cleanup: a registration its owner
  # discarded after its callback (as the reserve's `after` does) is invalid
  # in the next one, and `pending/0` is back to its pre-call value.
  test "a registration its owner discarded after its callback is invalid", ctx do
    registered? = api!(:registered?, 1)
    discard = api!(:discard, 1)
    pending = api!(:pending, 0)
    seed = seed!(ctx, ctx.run)
    before = pending.()

    {available, write} =
      owned(fn ->
        admitted = in_transaction(fn -> own!(admit!(ctx, locked_run!(ctx.run))) end)
        {charge, _at} = admitted
        :ok = discard.(registration(charge))

        in_transaction(fn ->
          {registered?.(registration(charge)),
           Ash.create(changeset(ctx, ctx.run, seed, admitted))}
        end)
      end)

    refute available, "a discarded registration is still registered"
    assert match?({:error, %Ash.Error.Forbidden{}}, write), "write: #{inspect(write)}"
    assert pending.() == before
    assert claude_invocations(ctx.fx) == 0
  end

  test "after ROLLBACK TO SAVEPOINT the registration is invalid and the connection usable",
       ctx do
    registered? = api!(:registered?, 1)
    seed = seed!(ctx, ctx.run)

    {available, write, select} =
      owned(fn ->
        in_transaction(fn ->
          run = locked_run!(ctx.run)
          Repo.query!("SAVEPOINT s2_admission_origin")
          admitted = own!(admit!(ctx, run))
          Repo.query!("ROLLBACK TO SAVEPOINT s2_admission_origin")
          {charge, _at} = admitted

          {registered?.(registration(charge)),
           Ash.create(changeset(ctx, ctx.run, seed, admitted)), Repo.query!("SELECT 1").rows}
        end)
      end)

    refute available, "a registration survived ROLLBACK TO SAVEPOINT"
    assert match?({:error, %Ash.Error.Forbidden{}}, write), "write: #{inspect(write)}"
    assert select == [[1]]
    assert claude_invocations(ctx.fx) == 0
  end

  test "pending/0 returns to its pre-call value after success, a gate refusal, a Forbidden authority and a rollback",
       ctx do
    pending = api!(:pending, 0)
    before = pending.()

    success = G.reserve(ctx.fx, ctx.run)
    after_success = pending.()

    refusal = G.reserve(ctx.fx, ctx.run, purpose: :reply_classification)
    after_refusal = pending.()

    forbidden =
      Agents.reserve_model_invocation(
        ctx.run,
        Map.put(G.call_attrs(), :prototype_authority, %{"forged" => "yes"}),
        actor: ctx.fx.agent
      )

    after_forbidden = pending.()

    attrs = G.call_attrs()
    first = Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.fx.agent)
    duplicate = Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.fx.agent)
    after_rollback = pending.()

    assert match?({:ok, _}, success), "prerequisite: success: #{inspect(success)}"
    assert match?({:error, %Admission.Refused{}}, refusal), "refusal: #{inspect(refusal)}"
    assert match?({:error, %Ash.Error.Forbidden{}}, forbidden), inspect(forbidden)

    assert match?({:ok, %ModelInvocation{}}, first),
           "prerequisite: the first of the duplicate pair: #{inspect(first)}"

    assert match?({:error, %Ash.Error.Invalid{}}, duplicate), "rollback: #{inspect(duplicate)}"

    assert {after_success, after_refusal, after_forbidden, after_rollback} ==
             {before, before, before, before}
  end
end
