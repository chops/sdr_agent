defmodule SdrAgent.Outreach.FollowupSuppressionReadTest do
  @moduledoc """
  Suppression safety fix, defect A (plan r3 §3, §6 A1–A8): the follow-up
  scheduler (SCH) reads the tenant's covering suppressions through one
  tenant-bound read action, `Suppression :followup_matching`, and the
  guarded wrapper `Outreach.followup_suppressions/2` — the tenant's rows or
  an error, never a policy-filtered `[]`. Only
  `%SdrAgent.Actor{type: :scheduler}` with a canonical UUID-text
  `tenant_id` may run it; every other caller is refused
  (`Ash.Error.Forbidden`), and each refused wrapper invocation appends
  exactly one `authz.denied` naming the resource and the action, never the
  email. SCH gains no other read (A8, a control).
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [operator!: 2]

  alias SdrAgent.Actor
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Outreach.SuppressionMatch

  @action :followup_matching
  @wrapper {:followup_suppressions, 2}

  # Structural guards (plan §6 "S"), placed after the fixtures: on a build
  # without the action or the wrapper they fail as assertions, not as a
  # compile or undefined-function error.
  defp assert_read_defined! do
    assert Ash.Resource.Info.action(Suppression, @action) != nil,
           "Suppression has no #{inspect(@action)} read action"

    {name, arity} = @wrapper

    assert Code.ensure_loaded?(Outreach) and function_exported?(Outreach, name, arity),
           "Outreach.#{name}/#{arity} is not defined"
  end

  defp direct(args, actor) do
    Suppression
    |> Ash.Query.for_read(@action, args, actor: actor)
    |> Ash.read()
  end

  # The wrapper under test, called after `assert_read_defined!/0` (the
  # project's RED convention: a guard, then `apply/3`).
  defp followup_suppressions(email, actor) do
    {name, _arity} = @wrapper
    apply(Outreach, name, [email, [actor: actor]])
  end

  # The wrapper may raise for a malformed actor whose denial cannot be
  # appended (plan §3, a bounded property of the existing kernel); a raise
  # is reported as `{:raised, exception}` so each case fails as an assertion.
  defp wrapper(email, actor) do
    {:returned, followup_suppressions(email, actor)}
  rescue
    exception -> {:raised, exception}
  end

  defp scheduler(ctx), do: Actor.system(:scheduler, ctx.tenant.id)

  defp denials(ctx), do: events_of_type(ctx.tenant, "authz.denied")

  defp suppress!(ctx, scope, value) do
    {:ok, suppression} = Outreach.suppress(%{scope: scope, value: value}, actor: ctx.admin)
    suppression
  end

  defp ids({:ok, rows}) when is_list(rows), do: Enum.map(rows, & &1.id)
  defp ids(other), do: other

  test "A1: the scheduler sees the tenant's email suppression (action and wrapper)", ctx do
    email = "a1.covered@followup-read.test"
    suppression = suppress!(ctx, :email, email)
    sch = scheduler(ctx)
    assert_read_defined!()

    assert ids(direct(%{email: email}, sch)) == [suppression.id]
    assert ids(followup_suppressions(email, sch)) == [suppression.id]
  end

  test "A2: the scheduler sees the tenant's domain suppression for a mixed-case, padded email",
       ctx do
    suppression = suppress!(ctx, :domain, "followup-domain.test")
    padded = "  A2.Someone@Followup-Domain.TEST "
    sch = scheduler(ctx)
    assert_read_defined!()

    assert ids(followup_suppressions(padded, sch)) == [suppression.id]
    assert ids(direct(%{email: SuppressionMatch.normalize(padded)}, sch)) == [suppression.id]
  end

  test "A3: a tenantless scheduler is refused: the action is Forbidden; the wrapper is Forbidden and adds exactly one authz.denied without the email",
       ctx do
    email = "a3.tenantless@followup-read.test"
    suppress!(ctx, :email, email)
    tenantless = Actor.system(:scheduler, nil)
    before = denials(ctx)
    assert_read_defined!()

    assert match?({:error, %Ash.Error.Forbidden{}}, direct(%{email: email}, tenantless))
    assert match?({:returned, {:error, %Ash.Error.Forbidden{}}}, wrapper(email, tenantless))

    added = denials(ctx) -- before
    assert length(added) == 1, "expected exactly one new authz.denied, got #{length(added)}"
    [denied] = added
    assert denied.subject_resource == inspect(Suppression)
    assert denied.action == "followup_matching"

    assert denied.payload == %{
             "action" => "followup_matching",
             "resource" => inspect(Suppression)
           }

    refute inspect(denied, limit: :infinity, printable_limit: :infinity) =~ email
  end

  test "A4: ADM seeds a covering email suppression; the own scheduler reads it (action and wrapper); a scheduler of another valid UUID gets {:ok, []} on both, with no new denial",
       ctx do
    email = "a4.covering@followup-read.test"
    suppression = suppress!(ctx, :email, email)
    own = scheduler(ctx)
    foreign = Actor.system(:scheduler, Ecto.UUID.generate())
    assert Ecto.UUID.cast(foreign.tenant_id) == {:ok, foreign.tenant_id}
    refute foreign.tenant_id == ctx.tenant.id
    assert_read_defined!()

    assert ids(direct(%{email: email}, own)) == [suppression.id]
    assert ids(followup_suppressions(email, own)) == [suppression.id]

    before = denials(ctx)
    assert direct(%{email: email}, foreign) == {:ok, []}
    assert followup_suppressions(email, foreign) == {:ok, []}
    assert denials(ctx) == before
  end

  test "A5: every other caller is refused: the direct action is Forbidden; each wrapper call is Forbidden and adds exactly one denial",
       ctx do
    email = "a5.others@followup-read.test"
    suppress!(ctx, :email, email)
    tenant_id = ctx.tenant.id

    callers = [
      {"nil", nil},
      {"ADM", ctx.admin},
      {"REV", operator!(ctx, :reviewer)},
      {"AUR", operator!(ctx, :auditor)},
      {"AGT", Actor.system(:agent_runtime, tenant_id)},
      {"DLV", Actor.system(:delivery_worker, tenant_id)},
      {"REC", Actor.system(:reconciler, tenant_id)},
      {"WHK", Actor.system(:webhook_ingestor, tenant_id)},
      {"ANC", Actor.system(:anchorer, tenant_id)},
      {"MRT", Actor.system(:model_runtime, tenant_id)},
      {"AUD", Actor.system(:auditor_cli, tenant_id)},
      {"SEED", Actor.system(:seeder, tenant_id)},
      {"KRN without context", Actor.system(:kernel, tenant_id)}
    ]

    assert_read_defined!()

    for {label, actor} <- callers do
      assert match?({:error, %Ash.Error.Forbidden{}}, direct(%{email: email}, actor)), label

      before = length(denials(ctx))
      assert match?({:returned, {:error, %Ash.Error.Forbidden{}}}, wrapper(email, actor)), label
      assert length(denials(ctx)) == before + 1, label
    end
  end

  test "A6: malformed scheduler actors are refused: the action is Forbidden; the wrapper never returns {:ok, _}",
       ctx do
    email = "a6.malformed@followup-read.test"
    suppress!(ctx, :email, email)
    tenant_id = ctx.tenant.id
    {:ok, raw} = Ecto.UUID.dump(tenant_id)
    upper = String.upcase(tenant_id)

    # Mere cast success is not the contract: both representations cast, to
    # canonical text that differs from the input (plan §3 check 1).
    assert Ecto.UUID.cast(raw) == {:ok, tenant_id} and raw != tenant_id
    assert Ecto.UUID.cast(upper) == {:ok, tenant_id} and upper != tenant_id

    malformed = [
      {"plain map", %{type: :scheduler, tenant_id: tenant_id}},
      {"non-UUID text", Actor.system(:scheduler, "not-a-uuid")},
      {"raw 16-byte binary", Actor.system(:scheduler, raw)},
      {"uppercase UUID text", Actor.system(:scheduler, upper)},
      {"integer", Actor.system(:scheduler, 42)}
    ]

    assert_read_defined!()

    for {label, actor} <- malformed do
      assert match?({:error, %Ash.Error.Forbidden{}}, direct(%{email: email}, actor)), label
      refute match?({:returned, {:ok, _}}, wrapper(email, actor)), label
    end
  end

  test "A7: a missing email argument is an invalid error, not an empty result", ctx do
    sch = scheduler(ctx)
    assert_read_defined!()

    for {label, args} <- [{"no argument", %{}}, {"nil argument", %{email: nil}}] do
      assert match?({:error, %Ash.Error.Invalid{}}, direct(args, sch)), label
    end

    assert match?({:error, %Ash.Error.Invalid{}}, followup_suppressions(nil, sch))
  end

  # Control (least privilege; vacuous on main): the scheduler's generic reads
  # stay filtered to nothing.
  test "A8: the scheduler gains no other read: list_records, matching_suppressions and :read stay empty",
       ctx do
    email = "a8.least-privilege@followup-read.test"
    suppress!(ctx, :email, email)
    sch = scheduler(ctx)

    assert Outreach.list_records(Suppression, actor: sch) == {:ok, []}
    assert Outreach.matching_suppressions(email, actor: sch) == {:ok, []}
    assert Suppression |> Ash.Query.for_read(:read, %{}, actor: sch) |> Ash.read() == {:ok, []}
  end
end
