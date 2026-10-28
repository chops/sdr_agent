defmodule SdrAgent.Prototype.SetupActionsTest do
  @moduledoc """
  The D-237 setup-only actions and their marker check, exercised directly
  (Codex 2416ce0b must-fix: no `bound!`, snapshot or operator resolver; real
  synthetic prerequisites only):

  - structural: `User :create_prototype_anchor` and
    `:create_prototype_auditor`, `PrototypeDatabaseBinding :create` and
    `PrototypeDelegation :create_setup` exist as create actions;
  - `SdrAgent.Prototype.Checks.KernelMarker`: a `:kernel` actor whose
    request carries the private kernel marker AND the `:setup` marker is
    the sole positive case; an unmarked kernel request, the wrong marker,
    an unknown marker option, no context, a human, a forged operator and no
    actor are refused;
  - authorization: each action is `Forbidden`, writing no row and no event,
    for an unmarked kernel request, a kernel request with the `:task_entry`
    marker, a kernel actor with no context, an admin carrying the `:setup`
    marker and a forged operator carrying it; the marked kernel request
    succeeds.

  Valid inputs throughout, so a refusal is the authorization's and never a
  validation, foreign-key or missing-action error.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Operations.PrototypeDatabaseBinding
  alias SdrAgent.Operations.PrototypeDelegation
  alias SdrAgent.Prototype.Checks.KernelMarker

  @setup_actions [
    {User, :create_prototype_anchor},
    {User, :create_prototype_auditor},
    {PrototypeDatabaseBinding, :create},
    {PrototypeDelegation, :create_setup}
  ]
  @tables ~w(users prototype_database_bindings prototype_delegations)
  @auditor_password String.duplicate("p", 43)

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  defp kernel(tenant), do: Actor.system(:kernel, tenant.id)
  defp setup_opts(tenant), do: [actor: kernel(tenant), context: KernelMarker.context(:setup)]

  defp forged_operator(tenant),
    do: %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: tenant.id}

  # Every caller that must be refused, as Ash options.
  defp refused_callers(tenant) do
    [
      unmarked_kernel: [actor: kernel(tenant), context: KernelContext.context()],
      wrong_marker: [actor: kernel(tenant), context: KernelMarker.context(:task_entry)],
      kernel_without_context: [actor: kernel(tenant)],
      admin_with_marker: [actor: human(:admin, tenant), context: KernelMarker.context(:setup)],
      forged_operator_with_marker: [
        actor: forged_operator(tenant),
        context: KernelMarker.context(:setup)
      ]
    ]
  end

  defp create(resource, action, params, opts) do
    resource
    |> Ash.Changeset.for_create(action, params, opts)
    |> Ash.create()
  end

  # Valid inputs for each action; the binding names an existing user of the
  # tenant (its composite foreign key) and plausible identity values.
  defp params(User, :create_prototype_anchor, _tenant), do: %{}
  defp params(User, :create_prototype_auditor, _tenant), do: %{password: @auditor_password}

  defp params(PrototypeDatabaseBinding, :create, tenant) do
    %{
      instance_id: Ecto.UUID.generate(),
      operator_user_id: human(:reviewer, tenant).id,
      policy_entry_sha256: String.duplicate("a", 64),
      database_oid: 16_384,
      system_identifier: 7_000_000_000_000_000_001
    }
  end

  defp params(PrototypeDelegation, :create_setup, _tenant),
    do: %{agent: "claude_code", session_correlation: "setup-actions-0001"}

  describe "structure" do
    test "the four setup-only actions exist as create actions" do
      for {resource, name} <- @setup_actions do
        action = Ash.Resource.Info.action(resource, name)
        assert action, "#{inspect(resource)} has no #{name} action"
        assert action.type == :create
      end
    end
  end

  describe "KernelMarker" do
    setup do
      %{tenant: bootstrap!()}
    end

    defp marker?(actor, context, opts \\ [marker: :setup]),
      do: KernelMarker.match?(actor, %{subject: %{context: context}}, opts)

    test "a kernel request carrying the kernel and :setup markers is the positive case", ctx do
      assert marker?(kernel(ctx.tenant), KernelMarker.context(:setup)),
             "the marked kernel request was refused"
    end

    test "every other request is refused", ctx do
      setup_context = KernelMarker.context(:setup)

      refused = [
        unmarked_kernel: marker?(kernel(ctx.tenant), KernelContext.context()),
        wrong_marker: marker?(kernel(ctx.tenant), KernelMarker.context(:task_entry)),
        unknown_marker_option: marker?(kernel(ctx.tenant), setup_context, marker: :other),
        no_context: marker?(kernel(ctx.tenant), %{}),
        setup_marker_only:
          marker?(kernel(ctx.tenant), Map.delete(setup_context, :sdr_audit_kernel)),
        admin: marker?(human(:admin, ctx.tenant), setup_context),
        forged_operator: marker?(forged_operator(ctx.tenant), setup_context),
        no_actor: marker?(nil, setup_context)
      ]

      for {name, result} <- refused do
        refute result, "#{name} passed the setup marker check"
      end
    end
  end

  describe "the setup-only actions refuse every caller but the marked kernel" do
    setup do
      %{tenant: bootstrap!()}
    end

    for {resource, name} <- @setup_actions do
      @resource resource
      @name name

      test "#{inspect(resource)} #{name} is Forbidden, writing nothing", ctx do
        # Arrange every prerequisite (the input's user, the refused callers'
        # admin) BEFORE the counts, so they measure only the refused calls.
        params = params(@resource, @name, ctx.tenant)
        callers = refused_callers(ctx.tenant)
        before_rows = Map.new(@tables, &{&1, count(&1)})
        before_events = length(events(ctx.tenant))

        for {caller, opts} <- callers do
          result = create(@resource, @name, params, opts)

          assert match?({:error, %Ash.Error.Forbidden{}}, result),
                 "#{caller}: expected Forbidden, got #{inspect(result)}"
        end

        assert Map.new(@tables, &{&1, count(&1)}) == before_rows
        assert length(events(ctx.tenant)) == before_events
      end
    end

    test "the marked kernel request creates the anchor", ctx do
      result = create(User, :create_prototype_anchor, %{}, setup_opts(ctx.tenant))
      assert match?({:ok, %User{}}, result), "anchor: #{inspect(result)}"
      {:ok, anchor} = result
      assert anchor.role == :agent_operator
      assert to_string(anchor.email) == "d237-operator@prototype.invalid"
    end

    test "the marked kernel request creates the auditor", ctx do
      result =
        create(
          User,
          :create_prototype_auditor,
          %{password: @auditor_password},
          setup_opts(ctx.tenant)
        )

      assert match?({:ok, %User{}}, result), "auditor: #{inspect(result)}"
      {:ok, auditor} = result
      assert auditor.role == :auditor
    end

    test "the marked kernel request creates the binding, then the setup delegation", ctx do
      binding =
        create(
          PrototypeDatabaseBinding,
          :create,
          params(PrototypeDatabaseBinding, :create, ctx.tenant),
          setup_opts(ctx.tenant)
        )

      assert match?({:ok, %PrototypeDatabaseBinding{}}, binding), "binding: #{inspect(binding)}"
      {:ok, binding} = binding
      assert binding.tenant_id == ctx.tenant.id
      assert binding.policy_id == "d237-prototype/1"

      delegation =
        create(
          PrototypeDelegation,
          :create_setup,
          params(PrototypeDelegation, :create_setup, ctx.tenant),
          setup_opts(ctx.tenant)
        )

      assert match?({:ok, %PrototypeDelegation{}}, delegation),
             "delegation: #{inspect(delegation)}"

      {:ok, delegation} = delegation
      assert delegation.binding_id == binding.id
      assert delegation.operator_user_id == binding.operator_user_id
      assert delegation.tenant_id == ctx.tenant.id
    end
  end
end
