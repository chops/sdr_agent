defmodule SdrAgent.Prototype.WindowTest do
  @moduledoc """
  RED-b2, the business-use window (amendment item 9; funding entry
  `d237-funding/1`: `starts_at` 2026-10-30T15:05:40.000000Z INCLUSIVE,
  `expires_at` 2026-11-07T07:00:00.000000Z EXCLUSIVE), D-237 slice S2, at
  reservation, launch and the `released_unverified` decision, with S1's real
  provisioning and the hermetic test clock (`SdrAgent.Clock.freeze/1`).

  Just before the start a reservation is refused, uncharged.   At exactly the start a reservation is admitted; at the last microsecond
  before the end a call is reserved, launched and released; at exactly the
  end there is no new reservation (uncharged), launch (charged) or release
  (withheld `outside_window`, the charge kept). After the end a released
  output still replays, and the operator can still revoke the grant.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Clock
  alias SdrAgent.PrototypeGateFixtures, as: G

  @before ~U[2026-10-30 15:05:39.999999Z]
  @start ~U[2026-10-30 15:05:40.000000Z]
  @last ~U[2026-11-07 06:59:59.999999Z]
  @end_ ~U[2026-11-07 07:00:00.000000Z]

  setup do
    fx = G.prototype!()
    %{fx: fx, run: G.run!(fx)}
  end

  defp code(fx, release) do
    [event] = G.release_events(fx, "model.result.withheld", release)
    event.payload["arguments"]["prototype_refusal"]
  end

  test "a reservation just before the start is refused no_eligible_grant, uncharged", ctx do
    Clock.freeze(@before)
    result = G.reserve(ctx.fx, ctx.run)

    assert match?({:error, %Refused{stage: :reservation, reason: :no_eligible_grant}}, result),
           "just before the start: #{inspect(result)}"

    assert G.charged(ctx.fx) == 0
  end

  test "a reservation at exactly the start is admitted", ctx do
    Clock.freeze(@start)
    result = G.reserve(ctx.fx, ctx.run)
    assert match?({:ok, %ModelInvocation{}}, result), "at the start: #{inspect(result)}"
  end

  test "at the last microsecond a call is reserved, launched and released", ctx do
    Clock.freeze(@last)
    invocation = G.completed!(ctx.fx, ctx.run)
    result = G.finalize(invocation, ctx.run)
    assert match?({:released, %{disposition: :released_unverified}, _}, result), inspect(result)
  end

  # Reservation and launch keep the ordinary grant-window refusals: the
  # provisioned grant's own window is the funding window (amendment item 4,
  # "What stays: grant and allocation windows").
  test "a reservation at exactly the end is refused no_eligible_grant before charge", ctx do
    Clock.freeze(@end_)
    result = G.reserve(ctx.fx, ctx.run)

    assert match?({:error, %Refused{stage: :reservation, reason: :no_eligible_grant}}, result),
           "at the end: #{inspect(result)}"

    assert G.charged(ctx.fx) == 0
  end

  test "a launch at exactly the end is refused grant_expired and keeps its charge", ctx do
    Clock.freeze(@last)
    reserved = G.reserve(ctx.fx, ctx.run)

    assert match?({:ok, %ModelInvocation{}}, reserved),
           "prerequisite: reserve: #{inspect(reserved)}"

    {:ok, invocation} = reserved
    Clock.freeze(@end_)
    result = G.launch(ctx.fx, invocation)

    assert match?(
             {:error,
              %Refused{stage: :launch, reason: :grant_ineligible_at_launch, check: :grant_expired}},
             result
           ),
           "at the end: #{inspect(result)}"

    assert Ash.get!(ModelInvocation, invocation.id, authorize?: false).status == :failed
    assert G.charged(ctx.fx) == 1
  end

  test "a decision at exactly the end records the late withheld outcome (outside_window)",
       ctx do
    Clock.freeze(@last)
    invocation = G.completed!(ctx.fx, ctx.run)
    Clock.freeze(@end_)
    result = G.finalize(invocation, ctx.run)

    assert match?({:withheld, %{reason: :prototype_authority_refused}, _}, result),
           inspect(result)

    {:withheld, release, _run} = result
    assert code(ctx.fx, release) == "outside_window"
    assert G.charged(ctx.fx) == 1
  end

  test "after the end a released output replays and the grant can be revoked", ctx do
    Clock.freeze(@last)
    invocation = G.completed!(ctx.fx, ctx.run)
    released = G.finalize(invocation, ctx.run)

    assert match?({:released, %{disposition: :released_unverified}, _}, released),
           "prerequisite: release: #{inspect(released)}"

    {:released, release, output} = released

    Clock.freeze(@end_)

    assert match?(
             {:released, %{id: id}, ^output} when id == release.id,
             G.finalize(invocation, ctx.run)
           )

    assert match?(
             {:ok, %{status: :revoked}},
             Agents.revoke_grant(ctx.fx.grant, %{expected_revision: ctx.fx.grant.revision},
               actor: ctx.fx.actor
             )
           )
  end
end
