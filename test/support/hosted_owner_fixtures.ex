defmodule SdrAgent.HostedOwnerFixtures do
  @moduledoc """
  Synthetic S-B5 fixtures using the real bootstrap and relocation actions.
  Missing S-B5 APIs fail assertions, not compiler warnings or mocked domain
  results. Every database write is sandbox-owned; no live CLI or host access.
  """

  import ExUnit.Assertions
  import SdrAgent.PrototypeCase

  alias SdrAgent.Actor
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeFixtures

  @owner SdrAgent.Operations.HostedOwner
  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent

  def activated! do
    fx = bound!(auditor: true, enter_runtime: false)
    source = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])
    destination = %{source | database_oid: source.database_oid + 1_000}
    context = %{fx: fx, source: source, destination: destination}
    relocation = relocate!(context, source, destination, 1)
    Map.put(context, :relocation, relocation)
  end

  def relocate!(context, source, destination, sequence) do
    assert :ok = PrototypeFixtures.leave_runtime()
    assert :ok = PrototypeFixtures.put_live_identity(source)

    opts = [
      actor: Actor.system(:kernel, context.fx.tenant.id),
      context: KernelMarker.context(:relocation)
    ]

    assert {:ok, relocation} =
             @relocation
             |> Ash.Changeset.for_create(
               :create,
               %{
                 binding_id: context.fx.binding.id,
                 relocation_seq: sequence,
                 from_identity: source,
                 to_identity: destination
               },
               opts
             )
             |> Ash.create()

    for kind <- [:planned, :writers_stopped, :fenced, :restored, :activated] do
      identity = if kind in [:restored, :activated], do: destination, else: source
      assert :ok = PrototypeFixtures.put_live_identity(identity)

      assert {:ok, _} =
               @event
               |> Ash.Changeset.for_create(
                 :append,
                 %{relocation_id: relocation.id, kind: kind},
                 opts
               )
               |> Ash.create()
    end

    relocation
  end

  def console(context) do
    marker =
      try do
        KernelMarker.context(:hosted_owner)
      rescue
        FunctionClauseError -> flunk("missing :hosted_owner console marker")
      end

    [actor: Actor.system(:kernel, context.fx.tenant.id), context: marker]
  end

  def enrol!(context, attrs \\ %{}) do
    loaded!(@owner)

    attrs =
      Map.merge(%{email: "hosted-owner@example.test", display_name: "Synthetic owner"}, attrs)

    result = call(SdrAgent.Operations, :enrol_hosted_owner, [attrs, console(context)])

    assert match?(
             {:ok, %{owner: %{}, user: %{}, enrollment_token: token}} when is_binary(token),
             result
           )

    {:ok, enrolled} = result
    enrolled
  end

  def consume(token), do: call(SdrAgent.Operations, :consume_hosted_owner_link, [token])

  def consume!(token) do
    result = consume(token)
    assert match?({:ok, %SdrAgent.Accounts.User{}}, result)
    {:ok, user} = result
    user
  end

  def disable(context, id, opts \\ nil),
    do: call(SdrAgent.Operations, :disable_hosted_owner, [id, opts || console(context)])

  def enter!(context) do
    assert :ok = PrototypeFixtures.enter_runtime(context.fx.snapshot)
    context
  end

  def hosted?(user), do: call(SdrAgent.Prototype.Authority, :hosted_owner?, [user])

  def kernel(context), do: SdrAgent.Audit.Kernel.opts(context.fx.tenant.id)
end
