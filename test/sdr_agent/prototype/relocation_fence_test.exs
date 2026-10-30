defmodule SdrAgent.Prototype.RelocationFenceTest do
  @moduledoc """
  S-B1 RED (ADR-0024 decision 1; plan R2 "Predicates" and "Final fence
  serialization"; r4a C1): the identity-scoped fence on the spending writes
  `SdrAgent.Agents.reserve_model_invocation/3` and
  `SdrAgent.Agents.admit_launch/3`, in prototype runtime with S1's real
  provisioning (`SdrAgent.PrototypeGateFixtures.prototype!/1`).

  Contract specified here:

  - a database holding a `fenced` event whose identity equals its own live
    identity, with no later `aborted` in that relocation, refuses a
    reservation and a launch admission with `{:error, :relocation_fenced}`,
    writing no invocation, no audit event and no status change; the check
    runs after `Kernel.lock_head`, so a reservation made before the fence
    committed is refused at admission;
  - an `aborted` after the fence lifts it on the source;
  - the copied fence names the source identity: the destination (a
    different live identity) with an activation admits a reservation;
  - C1: a restored archive whose identity matches no activated to_identity
    and is not the original admits no reservation.

  The concurrent proof that a writer holding the head lock before the
  `fenced` append commits first and a later writer is refused (plan r1 S-B1
  "a stale pre-fence writer is serialized by the head lock") is
  `SdrAgent.Prototype.RelocationFenceRaceTest`
  (`relocation_fence_race_test.exs`), on independent connections.

  Chain writes are owner-run (the `:relocation` kernel marker) in ordinary
  runtime; the live identity is the test-build seam
  (`PrototypeFixtures.put_live_identity/1`). Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeGateFixtures, as: G

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @source_side [:planned, :writers_stopped, :fenced]

  setup do
    fx = G.prototype!()
    run = G.run!(fx)
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    archive = %{
      original
      | database_oid: original.database_oid + 2_000,
        system_identifier: original.system_identifier - 2
    }

    %{fx: fx, run: run, original: original, destination: destination, archive: archive}
  end

  ## Helpers

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  # Owner-run writes in ordinary runtime at `live`, then back in prototype
  # runtime at `live`.
  defp owner_run!(ctx, live, fun) do
    assert PrototypeFixtures.leave_runtime() == :ok
    assert PrototypeFixtures.put_live_identity(live) == :ok
    result = fun.()
    G.enter!(ctx.fx)
    result
  end

  defp relocation!(ctx) do
    loaded!(@relocation)

    result =
      @relocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          binding_id: ctx.fx.binding.id,
          relocation_seq: 1,
          from_identity: ctx.original,
          to_identity: ctx.destination
        },
        owner(ctx.fx)
      )
      |> Ash.create()

    assert match?({:ok, %{id: _}}, result), "prerequisite: relocation create: #{inspect(result)}"
    {:ok, relocation} = result
    relocation
  end

  defp append!(ctx, relocation, kinds) do
    loaded!(@event)

    for kind <- kinds do
      result =
        @event
        |> Ash.Changeset.for_create(
          :append,
          %{relocation_id: relocation.id, kind: kind},
          owner(ctx.fx)
        )
        |> Ash.create()

      assert match?({:ok, %{id: _}}, result), "prerequisite: append #{kind}: #{inspect(result)}"
    end

    :ok
  end

  # The source fenced at the original identity; returns the relocation.
  defp fenced!(ctx) do
    owner_run!(ctx, ctx.original, fn ->
      relocation = relocation!(ctx)
      append!(ctx, relocation, @source_side)
      relocation
    end)
  end

  # The destination's copy: the source events, then restored and activated
  # at the destination identity.
  defp activated_copy!(ctx) do
    relocation = fenced!(ctx)
    owner_run!(ctx, ctx.destination, fn -> append!(ctx, relocation, [:restored, :activated]) end)
    relocation
  end

  defp effects(ctx), do: {G.invocations(ctx.fx), length(events(ctx.fx.tenant))}

  defp status(invocation),
    do: Ash.get!(ModelInvocation, invocation.id, authorize?: false).status

  ## Tests

  describe "the fence on the source" do
    test "a fenced source refuses a reservation, writing nothing", ctx do
      _relocation = fenced!(ctx)
      before = effects(ctx)
      result = G.reserve(ctx.fx, ctx.run)

      assert result == {:error, :relocation_fenced},
             "reserve on a fenced source: #{inspect(result)}"

      assert effects(ctx) == before, "the refused reservation wrote an invocation or event"
    end

    test "a reservation made before the fence is refused at admission, unchanged", ctx do
      reserved = G.reserve(ctx.fx, ctx.run)

      assert match?({:ok, %ModelInvocation{}}, reserved),
             "prerequisite: pre-fence reserve: #{inspect(reserved)}"

      {:ok, invocation} = reserved
      _relocation = fenced!(ctx)
      before = {status(invocation), length(events(ctx.fx.tenant))}

      result = G.launch(ctx.fx, invocation)

      assert result == {:error, :relocation_fenced},
             "admit on a fenced source: #{inspect(result)}"

      assert {status(invocation), length(events(ctx.fx.tenant))} == before
    end

    test "the source stays fenced after the destination activates", ctx do
      _relocation = activated_copy!(ctx)
      assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
      result = G.reserve(ctx.fx, ctx.run)
      assert result == {:error, :relocation_fenced}, "reserve on the source: #{inspect(result)}"
    end

    test "aborted after the fence lifts it", ctx do
      relocation = fenced!(ctx)
      owner_run!(ctx, ctx.original, fn -> append!(ctx, relocation, [:aborted]) end)
      result = G.reserve(ctx.fx, ctx.run)
      assert match?({:ok, %ModelInvocation{}}, result), "reserve after abort: #{inspect(result)}"
    end
  end

  describe "the copied fence on the destination" do
    test "with an activation, the destination's different identity admits a reservation", ctx do
      _relocation = activated_copy!(ctx)
      assert PrototypeFixtures.put_live_identity(ctx.destination) == :ok
      result = G.reserve(ctx.fx, ctx.run)

      assert match?({:ok, %ModelInvocation{}}, result),
             "reserve on the activated destination: #{inspect(result)}"
    end
  end

  describe "read-only recovery (C1)" do
    test "a restored archive matching no activation and not the original admits nothing", ctx do
      _relocation = activated_copy!(ctx)
      assert PrototypeFixtures.put_live_identity(ctx.archive) == :ok
      before = G.invocations(ctx.fx)
      result = G.reserve(ctx.fx, ctx.run)
      refute match?({:ok, _}, result), "the archive admitted a reservation: #{inspect(result)}"
      assert G.invocations(ctx.fx) == before
    end
  end
end
