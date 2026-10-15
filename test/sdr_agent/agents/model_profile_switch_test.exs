defmodule SdrAgent.Agents.ModelProfileSwitchTest do
  @moduledoc """
  C2-02a (#52, slice a): the switch records. The contract is
  `docs/product/r0/c2-02a-interface.md` (interface and narrow entity PASS
  at 66cc086), on the accepted R0 rows for ModelProfileSetting,
  ModelProfileSwitch and Actor `:model_runtime`.

  RED: the domain functions and resources don't exist on main. Every
  call goes through `call/2`, which first asserts that the function is
  exported. Each test therefore fails on an explicit assertion after its
  fixtures, not on an undefined-function crash.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Agents

  @setting SdrAgent.Agents.ModelProfileSetting
  @switch SdrAgent.Agents.ModelProfileSwitch

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      runtime: system_actor(:model_runtime, tenant),
      agent: system_actor(:agent_runtime, tenant)
    }
  end

  ## Calls (presence-guarded)

  defp call(fun, args) do
    assert function_exported?(Agents, fun, length(args)),
           "C2-02a: SdrAgent.Agents.#{fun}/#{length(args)} is not implemented"

    apply(Agents, fun, args)
  end

  defp request(ctx, attrs \\ %{}, actor \\ nil) do
    attrs =
      Map.merge(
        %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: 1},
        attrs
      )

    call(:request_profile_switch, [attrs, [actor: actor || ctx.admin]])
  end

  defp complete(ctx, switch, generation \\ 1, actor \\ nil),
    do:
      call(:complete_profile_switch, [
        switch,
        %{server_generation: generation},
        [actor: actor || ctx.runtime]
      ])

  defp fail(ctx, switch, generation \\ 1, actor \\ nil),
    do:
      call(:fail_profile_switch, [
        switch,
        %{server_generation: generation, failure_reason: "activation failed (test)"},
        [actor: actor || ctx.runtime]
      ])

  defp block(ctx, switch, generation \\ 1, actor \\ nil),
    do:
      call(:block_profile_switch, [
        switch,
        %{server_generation: generation, failure_reason: "unconfirmed work (test)"},
        [actor: actor || ctx.runtime]
      ])

  defp setting(actor), do: call(:get_profile_setting, [[actor: actor]])
  defp switches(actor), do: call(:list_profile_switches, [[actor: actor]])

  defp count(type, ctx), do: length(events_of_type(ctx.tenant, type))

  defp nothing_written(ctx) do
    assert {:ok, nil} = setting(ctx.admin)
    assert {:ok, []} = switches(ctx.admin)
    assert count("model.profile.setting_initialized", ctx) == 0
    assert count("model.profile.switch_requested", ctx) == 0
  end

  defp pending!(ctx) do
    assert {:ok, switch} = request(ctx)
    switch
  end

  ## Request

  describe "request" do
    test "an admin's first request initializes the setting and records a pending switch", ctx do
      assert {:ok, switch} = request(ctx)
      assert switch.status == :pending

      assert {switch.from_profile_id, switch.to_profile_id} ==
               {:claude_cli_opus, :claude_cli_sonnet}

      assert switch.server_generation == 1
      assert switch.requested_by_id == ctx.admin.id
      assert switch.requested_at
      assert switch.finished_at == nil

      assert {:ok, setting} = setting(ctx.admin)
      assert {setting.desired_profile_id, setting.revision} == {:claude_cli_opus, 1}

      assert count("model.profile.setting_initialized", ctx) == 1
      assert count("model.profile.switch_requested", ctx) == 1
    end

    test "a request against an existing setting does not re-initialize it", ctx do
      first = pending!(ctx)
      assert {:ok, _} = fail(ctx, first)

      assert {:ok, _} = request(ctx, %{server_generation: 2})
      assert count("model.profile.setting_initialized", ctx) == 1
      assert {:ok, %{revision: 1}} = setting(ctx.admin)
    end

    for {label, attrs} <- [
          {"a stale revision", %{expected_revision: 2}},
          {"to equal to the current desired profile", %{to_profile_id: :claude_cli_opus}},
          {"to :fake", %{to_profile_id: :fake}},
          {"an unknown profile", %{to_profile_id: :not_a_profile}},
          {"a non-positive generation", %{server_generation: 0}}
        ] do
      test "#{label} is refused, and a first request leaves nothing", ctx do
        assert {:error, _} = request(ctx, unquote(Macro.escape(attrs)))
        nothing_written(ctx)
      end
    end

    test "a second pending switch is refused", ctx do
      _first = pending!(ctx)
      assert {:error, _} = request(ctx, %{server_generation: 2})
      assert {:ok, [_one]} = switches(ctx.admin)
    end

    test "an existing blocked switch blocks a new request", ctx do
      first = pending!(ctx)
      assert {:ok, %{status: :blocked}} = block(ctx, first)
      assert {:error, _} = request(ctx, %{server_generation: 2})
      assert {:ok, [_one]} = switches(ctx.admin)
    end
  end

  describe "request authorization" do
    for role <- [:reviewer, :auditor] do
      test "a #{role} is refused and nothing is written", ctx do
        assert {:error, %Ash.Error.Forbidden{}} =
                 request(ctx, %{}, human(unquote(role), ctx.tenant))

        nothing_written(ctx)
      end
    end

    test "a disabled admin holding a stale struct is refused", ctx do
      stale = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_status(stale, :disabled, actor: ctx.admin)
      assert {:error, %Ash.Error.Forbidden{}} = request(ctx, %{}, stale)
      nothing_written(ctx)
    end

    test "an admin demoted since the struct was read is refused", ctx do
      stale = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_role(stale, :reviewer, actor: ctx.admin)
      assert {:error, %Ash.Error.Forbidden{}} = request(ctx, %{}, stale)
      nothing_written(ctx)
    end

    test "a missing actor and another tenant's admin are refused", ctx do
      other = %{ctx.admin | tenant_id: Ecto.UUID.generate()}

      for actor <- [nil, other] do
        assert {:error, _} =
                 call(:request_profile_switch, [
                   %{
                     to_profile_id: :claude_cli_sonnet,
                     expected_revision: 1,
                     server_generation: 1
                   },
                   [actor: actor]
                 ])
      end

      nothing_written(ctx)
    end

    test "model_runtime and every other system actor are refused", ctx do
      for type <- [:model_runtime, :agent_runtime, :kernel, :seeder, :scheduler, :reconciler] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 request(ctx, %{}, system_actor(type, ctx.tenant))
      end

      nothing_written(ctx)
    end
  end

  ## Runtime transitions

  describe "complete, fail and block" do
    test "complete applies the switch to the setting in the same transaction", ctx do
      switch = pending!(ctx)
      assert {:ok, completed} = complete(ctx, switch)
      assert completed.status == :completed
      assert completed.finished_at

      assert {:ok, setting} = setting(ctx.admin)
      assert {setting.desired_profile_id, setting.revision} == {:claude_cli_sonnet, 2}
      assert count("model.profile.switch_completed", ctx) == 1
    end

    test "fail leaves the setting unchanged", ctx do
      switch = pending!(ctx)

      assert {:ok, %{status: :failed, failure_reason: "activation failed (test)"}} =
               fail(ctx, switch)

      assert {:ok, %{desired_profile_id: :claude_cli_opus, revision: 1}} = setting(ctx.admin)
    end

    test "block leaves the setting unchanged", ctx do
      switch = pending!(ctx)
      assert {:ok, %{status: :blocked}} = block(ctx, switch)
      assert {:ok, %{desired_profile_id: :claude_cli_opus, revision: 1}} = setting(ctx.admin)
    end

    test "only model_runtime may complete, fail or block", ctx do
      switch = pending!(ctx)

      for actor <- [
            ctx.admin,
            human(:reviewer, ctx.tenant),
            ctx.agent,
            system_actor(:kernel, ctx.tenant)
          ] do
        assert {:error, %Ash.Error.Forbidden{}} = complete(ctx, switch, 1, actor)
        assert {:error, %Ash.Error.Forbidden{}} = fail(ctx, switch, 1, actor)
        assert {:error, %Ash.Error.Forbidden{}} = block(ctx, switch, 1, actor)
      end

      assert {:ok, [%{status: :pending}]} = switches(ctx.admin)
    end
  end

  describe "idempotency and conflicts" do
    for {action, status} <- [complete: :completed, fail: :failed, block: :blocked] do
      test "a same-generation #{action} replay is a no-op", ctx do
        switch = pending!(ctx)
        assert {:ok, first} = unquote(action)(ctx, switch)
        events = length(events(ctx.tenant))
        {:ok, before} = setting(ctx.admin)

        assert {:ok, again} = unquote(action)(ctx, first)
        assert again.status == unquote(status)

        assert {again.finished_at, again.failure_reason} ==
                 {first.finished_at, first.failure_reason}

        assert length(events(ctx.tenant)) == events
        assert setting(ctx.admin) == {:ok, before}
      end
    end

    test "a stale generation is refused before any replay", ctx do
      switch = pending!(ctx)
      assert {:error, _} = complete(ctx, switch, 2)
      assert {:ok, completed} = complete(ctx, switch)
      assert {:error, _} = complete(ctx, completed, 2)
    end

    test "complete and fail on a blocked switch are refused as blocked", ctx do
      switch = pending!(ctx)
      assert {:ok, blocked} = block(ctx, switch)
      assert {:error, :switch_blocked} = complete(ctx, blocked)
      assert {:error, :switch_blocked} = fail(ctx, blocked)
    end

    test "conflicting terminal actions are refused as already finished", ctx do
      completed = ctx |> pending!() |> then(&elem(complete(ctx, &1), 1))
      assert {:error, :switch_already_finished} = fail(ctx, completed)
      assert {:error, :switch_already_finished} = block(ctx, completed)

      assert {:ok, _} =
               request(ctx, %{
                 to_profile_id: :claude_cli_opus,
                 expected_revision: 2,
                 server_generation: 2
               })

      [failed_switch | _] = elem(switches(ctx.admin), 1)
      assert {:ok, failed} = fail(ctx, failed_switch, 2)
      assert {:error, :switch_already_finished} = complete(ctx, failed, 2)
      assert {:error, :switch_already_finished} = block(ctx, failed, 2)
    end

    test "history is never relabelled", ctx do
      first = pending!(ctx)
      assert {:ok, first} = fail(ctx, first)
      assert {:ok, _second} = request(ctx, %{server_generation: 2})
      assert {:ok, list} = switches(ctx.admin)
      assert Enum.find(list, &(&1.id == first.id)).status == :failed
    end
  end

  ## Internal actions and reads

  describe "the internal setting actions and reads" do
    test "the setting's internal actions can't be called directly", ctx do
      assert Code.ensure_loaded?(@setting), "C2-02a: #{inspect(@setting)} is not implemented"

      assert {:error, %Ash.Error.Forbidden{}} =
               @setting
               |> Ash.Changeset.for_create(:initialize, %{tenant_id: ctx.tenant.id},
                 actor: ctx.admin
               )
               |> Ash.create()

      switch = pending!(ctx)
      {:ok, setting} = setting(ctx.admin)

      for actor <- [ctx.admin, ctx.runtime] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 setting
                 |> Ash.Changeset.for_update(:apply_switch, %{switch_id: switch.id}, actor: actor)
                 |> Ash.update()
      end

      assert {:ok, %{revision: 1}} = setting(ctx.admin)
    end

    test "a forged phase marker in caller context is not enough", ctx do
      assert Code.ensure_loaded?(@setting), "C2-02a: #{inspect(@setting)} is not implemented"
      switch = pending!(ctx)
      {:ok, setting} = setting(ctx.admin)

      forged = %{
        profile_switch: %{
          phase: :apply,
          action: :complete,
          tenant_id: ctx.tenant.id,
          switch_id: switch.id
        }
      }

      assert {:error, _} =
               setting
               |> Ash.Changeset.for_update(:apply_switch, %{switch_id: switch.id},
                 actor: ctx.runtime,
                 context: forged
               )
               |> Ash.update()

      assert {:ok, %{revision: 1, desired_profile_id: :claude_cli_opus}} = setting(ctx.admin)
    end

    test "reads: admin, auditor (audited) and agent_runtime; not a reviewer or model_runtime",
         ctx do
      _switch = pending!(ctx)

      for actor <- [ctx.admin, human(:auditor, ctx.tenant), ctx.agent] do
        assert {:ok, %{revision: 1}} = setting(actor)
        assert {:ok, [_]} = switches(actor)
      end

      # Denied either as an empty read or as Forbidden.
      for actor <- [human(:reviewer, ctx.tenant), ctx.runtime] do
        assert setting(actor) in [{:ok, nil}] or
                 match?({:error, %Ash.Error.Forbidden{}}, setting(actor))

        assert switches(actor) in [{:ok, []}] or
                 match?({:error, %Ash.Error.Forbidden{}}, switches(actor))
      end
    end
  end

  ## Database checks (direct SQL, one rule each)

  # Runs `statements` with triggers off, so only the check, unique index
  # or constraint under test can fail, and returns the first error.
  defp sql_error(statements) do
    SdrAgent.Repo.transaction(fn ->
      SdrAgent.Repo.query!("SET LOCAL session_replication_role = replica")
      statements |> Enum.reduce_while(:no_error, &run_statement/2) |> SdrAgent.Repo.rollback()
    end)
  end

  defp run_statement(sql, _acc) do
    case SdrAgent.Repo.query(sql) do
      {:ok, _} -> {:cont, :no_error}
      {:error, error} -> {:halt, error}
    end
  end

  defp table!(name) do
    exists = SdrAgent.Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name]).rows
    assert exists == [[true]], "C2-02a: table #{name} does not exist"
  end

  # A copy of the table's first row under a new id.
  defp duplicate(table) do
    [
      "CREATE TEMP TABLE probe_copy ON COMMIT DROP AS SELECT * FROM #{table} LIMIT 1",
      "UPDATE probe_copy SET id = gen_random_uuid()",
      "INSERT INTO #{table} SELECT * FROM probe_copy"
    ]
  end

  describe "database checks" do
    test "one setting per tenant", ctx do
      table!("model_profile_settings")
      _ = pending!(ctx)

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               sql_error(duplicate("model_profile_settings"))
    end

    test "the setting's desired profile can't be :fake", ctx do
      table!("model_profile_settings")
      _ = pending!(ctx)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               sql_error(["UPDATE model_profile_settings SET desired_profile_id = 'fake'"])
    end

    test "a switch's from and to must differ", ctx do
      table!("model_profile_switches")
      _ = pending!(ctx)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               sql_error(["UPDATE model_profile_switches SET to_profile_id = from_profile_id"])
    end

    test "a switch's status is closed", ctx do
      table!("model_profile_switches")
      _ = pending!(ctx)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               sql_error(["UPDATE model_profile_switches SET status = 'bogus'"])
    end

    test "at most one pending or blocked switch per tenant", ctx do
      table!("model_profile_switches")
      _ = pending!(ctx)

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               sql_error(duplicate("model_profile_switches"))
    end
  end

  test "the resources are the accepted ones", _ctx do
    for module <- [@setting, @switch] do
      assert Code.ensure_loaded?(module), "C2-02a: #{inspect(module)} is not implemented"
    end

    assert :model_runtime in SdrAgent.Actor.types(),
           "C2-02a: actor type :model_runtime is missing"
  end
end
