defmodule SdrAgent.Prototype.RelocationLiveAuthorityTest do
  @moduledoc """
  S-B1 RED (ADR-0024 decision 1; plan R2 "Current authority" and
  "History"; r1 affected modules authority_core.ex:841-845 and
  boot_check.ex; r4a C1): the live checks compare the live identity with
  the CURRENT-AUTHORITY identity derived from the relocation chain, never
  with the binding row, which is never edited.

  Contract specified here:

  - `SdrAgent.Prototype.check_live/0` (authority_core `live_matches?`) is
    `:ok` on the activated destination's identity and
    `{:error, :binding_mismatch}` on the relocated-away source and on a
    restored archive (C1: matching no activated to_identity, not the
    original);
  - `SdrAgent.Prototype.BootCheck.check/1` is `{:ok, :prototype, snapshot}`
    (the unchanged binding snapshot) on the activated destination, and
    never the spending prototype runtime on the source after activation or
    on a restored archive;
  - the binding row is unchanged by relocation.

  With no relocation, the existing live-identity rules are unchanged
  (`live_identity_override_test.exs`, `boot_check_test.exs`). Chain writes
  are owner-run (the `:relocation` kernel marker) in ordinary runtime.
  Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Operations.PrototypeDatabaseBinding
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.BootCheck
  alias SdrAgent.Prototype.Checks.KernelMarker

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent

  setup do
    fx = bound!(enter_runtime: false)
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

    %{fx: fx, original: original, destination: destination, archive: archive}
  end

  ## Helpers

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

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

  # Seq 1 original → destination, fenced at the original and restored and
  # activated at the destination, in ordinary runtime.
  defp activated!(ctx) do
    loaded!(@relocation)
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok

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
    append!(ctx, relocation, [:planned, :writers_stopped, :fenced])
    assert PrototypeFixtures.put_live_identity(ctx.destination) == :ok
    append!(ctx, relocation, [:restored, :activated])
    relocation
  end

  defp check_live_at(ctx, live) do
    assert PrototypeFixtures.put_live_identity(live) == :ok
    enter!(ctx.fx)
    result = Prototype.check_live()
    assert PrototypeFixtures.leave_runtime() == :ok
    result
  end

  defp boot_at(ctx, live) do
    assert PrototypeFixtures.put_live_identity(live) == :ok
    BootCheck.check(PrototypeFixtures.switch(ctx.fx))
  end

  describe "check_live/0 follows the current authority" do
    test "the activated destination's identity checks :ok", ctx do
      _relocation = activated!(ctx)
      assert check_live_at(ctx, ctx.destination) == :ok
    end

    test "the relocated-away source is a mismatch", ctx do
      _relocation = activated!(ctx)
      assert check_live_at(ctx, ctx.original) == {:error, :binding_mismatch}
    end

    test "a restored archive matching no activation is a mismatch (C1)", ctx do
      _relocation = activated!(ctx)
      assert check_live_at(ctx, ctx.archive) == {:error, :binding_mismatch}
    end
  end

  describe "BootCheck follows the current authority" do
    test "the activated destination boots prototype runtime with the unchanged snapshot", ctx do
      _relocation = activated!(ctx)
      assert boot_at(ctx, ctx.destination) == {:ok, :prototype, ctx.fx.snapshot}
    end

    test "the source after activation never boots the spending runtime", ctx do
      _relocation = activated!(ctx)
      result = boot_at(ctx, ctx.original)
      refute match?({:ok, :prototype, _}, result), "the source booted: #{inspect(result)}"
    end

    test "a restored archive never boots the spending runtime (C1)", ctx do
      _relocation = activated!(ctx)
      result = boot_at(ctx, ctx.archive)
      refute match?({:ok, :prototype, _}, result), "the archive booted: #{inspect(result)}"
    end
  end

  describe "history" do
    test "the binding row is unchanged by relocation", ctx do
      _relocation = activated!(ctx)

      rows =
        PrototypeDatabaseBinding
        |> Ash.Query.for_read(:read, %{}, SdrAgent.Audit.Kernel.opts())
        |> Ash.read!()

      assert [row] = rows
      assert Map.take(row, [:database, :database_oid, :system_identifier]) == ctx.original
      assert row.bound_at == ctx.fx.binding.bound_at
    end
  end
end
