defmodule SdrAgent.Agents.ModelProfileSwitchTest do
  @moduledoc """
  C2-02a (#52, slice a): the switch records. The contract is
  `docs/product/r0/c2-02a-interface.md` (interface and narrow entity PASS
  at 66cc086), on the accepted R0 rows for ModelProfileSetting,
  ModelProfileSwitch and Actor `:model_runtime`.

  Written RED first (verified at f3ef30c): every call goes through
  `call/2`, which first asserts that the function is exported, so on main
  each test failed on an explicit assertion after its fixtures. The GREEN
  review regressions (Codex 62e27b33) are in "the phase authority boundary".
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ProfileSwitches

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

  defp observe(fun) do
    fun.()
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    kind, reason -> {kind, reason}
  end

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
      for type <- Enum.uniq([:model_runtime | SdrAgent.Actor.types()]) do
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
      switch = pending!(ctx)
      assert {:ok, completed} = complete(ctx, switch)
      assert {:error, :switch_already_finished} = fail(ctx, completed)
      assert {:error, :switch_already_finished} = block(ctx, completed)

      assert {:ok, second} =
               request(ctx, %{
                 to_profile_id: :claude_cli_opus,
                 expected_revision: 2,
                 server_generation: 2
               })

      assert {:ok, failed} = fail(ctx, second, 2)
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

      # Denied either as an empty read or as Forbidden; each read once.
      for actor <- [human(:reviewer, ctx.tenant), ctx.runtime] do
        read_setting = setting(actor)
        read_switches = switches(actor)

        assert read_setting == {:ok, nil} or
                 match?({:error, %Ash.Error.Forbidden{}}, read_setting)

        assert read_switches == {:ok, []} or
                 match?({:error, %Ash.Error.Forbidden{}}, read_switches)
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

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :unique_violation,
                  constraint: "model_profile_settings_unique_tenant_index"
                }
              }} =
               sql_error(duplicate("model_profile_settings"))
    end

    test "the setting's desired profile can't be :fake", ctx do
      table!("model_profile_settings")
      _ = pending!(ctx)

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :check_violation,
                  constraint: "model_profile_settings_real_profile"
                }
              }} =
               sql_error(["UPDATE model_profile_settings SET desired_profile_id = 'fake'"])
    end

    test "a switch's from and to must differ", ctx do
      table!("model_profile_switches")
      _ = pending!(ctx)

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :check_violation,
                  constraint: "model_profile_switches_distinct_profiles"
                }
              }} =
               sql_error(["UPDATE model_profile_switches SET to_profile_id = from_profile_id"])
    end

    test "a switch's status is closed", ctx do
      table!("model_profile_switches")
      _ = pending!(ctx)

      assert {:error,
              %Postgrex.Error{
                postgres: %{code: :check_violation, constraint: "model_profile_switches_status"}
              }} =
               sql_error(["UPDATE model_profile_switches SET status = 'bogus'"])
    end

    # Each copy gets a fresh id and generation, so only the open-switch
    # index can be the one violated.
    for {label, original, copy} <- [
          {"pending + pending", :pending, "pending"},
          {"blocked + blocked", :blocked, "blocked"},
          {"blocked + pending", :blocked, "pending"}
        ] do
      test "at most one open switch per tenant: #{label}", ctx do
        table!("model_profile_switches")
        switch = pending!(ctx)

        if unquote(original) == :blocked,
          do: assert({:ok, %{status: :blocked}} = block(ctx, switch))

        statements =
          List.insert_at(
            duplicate("model_profile_switches"),
            2,
            "UPDATE probe_copy SET status = '#{unquote(copy)}', " <>
              "server_generation = server_generation + 100"
          )

        assert {:error,
                %Postgrex.Error{
                  postgres: %{
                    code: :unique_violation,
                    constraint: "model_profile_switches_one_open_index"
                  }
                }} = sql_error(statements)
      end
    end

    test "a completed and a pending switch may coexist", ctx do
      table!("model_profile_switches")
      switch = pending!(ctx)
      assert {:ok, _} = complete(ctx, switch)

      assert {:ok, %{status: :pending}} =
               request(ctx, %{
                 to_profile_id: :claude_cli_opus,
                 expected_revision: 2,
                 server_generation: 2
               })
    end
  end

  ## Phase confinement of the internal actions and reads (RED 6b)

  describe "ProfileSwitchContext phases" do
    setup ctx do
      assert Code.ensure_loaded?(@setting), "C2-02a: #{inspect(@setting)} is not implemented"
      assert {:ok, switch} = request(ctx)
      assert {:ok, setting} = setting(ctx.admin)
      %{switch: switch, setting_row: setting}
    end

    test ":initialize can't be called directly by an admin or model_runtime", ctx do
      for actor <- [ctx.admin, ctx.runtime] do
        result =
          @setting
          |> Ash.Changeset.for_create(
            :initialize,
            %{id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id},
            actor: actor,
            context: phase(ctx, :initialize, :request, nil)
          )
          |> Ash.create()

        assert {:error, %Ash.Error.Forbidden{}} = result
      end

      unchanged!(ctx)
    end

    for {label, overrides, phase_name, action} <- [
          {"the wrong phase", Macro.escape(%{}), :transition, :complete},
          {"the wrong action", Macro.escape(%{}), :apply, :fail},
          {"another tenant", Macro.escape(%{tenant_id: "00000000-0000-0000-0000-000000000001"}),
           :apply, :complete},
          {"another switch", Macro.escape(%{switch_id: "00000000-0000-0000-0000-000000000002"}),
           :apply, :complete}
        ] do
      test "a forged :apply_switch with #{label} is refused", ctx do
        context =
          phase(ctx, unquote(phase_name), unquote(action), ctx.switch, unquote(overrides))

        assert {:error, %Ash.Error.Forbidden{}} =
                 apply_switch(ctx.setting_row, ctx.switch, ctx.runtime, context)

        unchanged!(ctx)
        assert {:ok, [%{status: :pending}]} = switches(ctx.admin)
      end
    end

    # Stored-row guards (not policy). A caller-built marker never opens a
    # phase (the forged cases above are Forbidden), and no exported function
    # opens one, so these use the test build's seam to open a genuine phase
    # the way `complete` does: `:transition` for complete, advanced to
    # `:apply`. The guard then refuses as Invalid on :switch_id: without the
    # `:transition` locks, or on a switch that is not pending.
    test "a premature :apply_switch (no transition lock, switch still pending) is refused",
         ctx do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               opened_apply(ctx, ctx.switch, false)

      assert Enum.any?(errors, &(Map.get(&1, :field) == :switch_id))
      unchanged!(ctx)
    end

    test ":apply_switch on a non-pending switch is refused", ctx do
      assert {:ok, failed} = fail(ctx, ctx.switch)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = opened_apply(ctx, failed, true)

      assert Enum.any?(errors, &(Map.get(&1, :field) == :switch_id))
      unchanged!(ctx)
    end

    test ":apply_switch by an admin, even with a matching marker, is refused", ctx do
      context = phase(ctx, :apply, :complete, ctx.switch)

      assert {:error, %Ash.Error.Forbidden{}} =
               apply_switch(ctx.setting_row, ctx.switch, ctx.admin, context)

      unchanged!(ctx)
    end

    for {label, resource} <- [{"setting", @setting}, {"switch", @switch}] do
      test "the #{label}'s internal transition read can't be used outside its phase", ctx do
        assert Code.ensure_loaded?(unquote(resource)),
               "C2-02a: #{inspect(unquote(resource))} is not implemented"

        foreign =
          phase(ctx, :transition, :complete, ctx.switch, %{tenant_id: Ecto.UUID.generate()})

        same_tenant_forged = phase(ctx, :transition, :complete, ctx.switch)

        for {actor, context} <- [
              {ctx.runtime, %{}},
              {ctx.runtime, foreign},
              {ctx.runtime, same_tenant_forged},
              {ctx.admin, same_tenant_forged}
            ] do
          result =
            unquote(resource)
            |> Ash.Query.for_read(:lock_for_transition, %{switch_id: ctx.switch.id},
              actor: actor,
              context: context
            )
            |> Ash.read()

          assert {:error, %Ash.Error.Forbidden{}} = result
        end
      end
    end

    for action <- [:fail, :block] do
      test "#{action} never writes the setting", ctx do
        assert {:ok, %{status: status}} = unquote(action)(ctx, ctx.switch)
        assert status in [:failed, :blocked]
        unchanged!(ctx)
        assert count("model.profile.setting_initialized", ctx) == 1
      end
    end
  end

  defp phase(ctx, phase, action, switch, overrides \\ %{}) do
    %{
      profile_switch:
        Map.merge(
          %{
            phase: phase,
            action: action,
            tenant_id: ctx.tenant.id,
            switch_id: switch && switch.id
          },
          overrides
        )
    }
  end

  defp apply_switch(setting, switch, actor, context) do
    setting
    |> Ash.Changeset.for_update(:apply_switch, %{switch_id: switch.id},
      actor: actor,
      context: context
    )
    |> Ash.update()
  end

  # A real `:apply` phase, opened as `complete` opens it, in a transaction;
  # with `lock?`, the setting and the switch are first locked under
  # `:transition`.
  defp opened_apply(ctx, switch, lock?) do
    binding = runtime_binding(ctx, :complete, switch)

    SdrAgent.Repo.transaction(fn ->
      ProfileSwitches.with_test_phase(
        :transition,
        binding,
        &apply_in_phase(ctx, switch, lock?, &1)
      )
    end)
    |> case do
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      other -> other
    end
  end

  defp apply_in_phase(ctx, switch, lock?, context) do
    if lock?, do: lock_for_transition!(switch, ctx.runtime, context)
    context = ProfileSwitches.advance_test_phase(context)

    case apply_switch(ctx.setting_row, switch, ctx.runtime, context) do
      {:ok, setting} -> setting
      {:error, error} -> SdrAgent.Repo.rollback(error)
    end
  end

  defp lock_for_transition!(switch, actor, context) do
    for resource <- [@setting, @switch] do
      assert {:ok, [_row]} =
               resource
               |> Ash.Query.for_read(:lock_for_transition, %{switch_id: switch.id},
                 actor: actor,
                 context: context
               )
               |> Ash.read()
    end
  end

  defp unchanged!(ctx) do
    assert {:ok, %{desired_profile_id: :claude_cli_opus, revision: 1}} = setting(ctx.admin)
  end

  defp runtime_binding(ctx, action, switch) do
    %{
      action: action,
      tenant_id: ctx.tenant.id,
      switch_id: switch.id,
      server_generation: switch.server_generation,
      actor: ctx.runtime
    }
  end

  ## The phase authority boundary (GREEN review, Codex 62e27b33)

  describe "the phase authority boundary" do
    test "no exported function opens or advances a phase; only the test build's seam does" do
      for {module, name, arity} <- [
            {ProfileSwitches, :with_phase, 3},
            {ProfileSwitches, :advance, 1},
            {SdrAgent.Agents.Checks.ProfileSwitchContext, :with_phase, 3},
            {SdrAgent.Agents.Checks.ProfileSwitchContext, :advance, 2},
            {SdrAgent.Agents.Checks.ProfileSwitchContext, :put_evidence, 3}
          ] do
        refute function_exported?(module, name, arity),
               "#{inspect(module)}.#{name}/#{arity} must not be exported"
      end

      seams = [with_test_phase: 3, advance_test_phase: 1]

      assert ProfileSwitches.__info__(:functions) -- seams ==
               [
                 get_setting: 1,
                 list_switches: 1,
                 phase: 1,
                 record_evidence: 3,
                 request: 2,
                 transition: 4
               ]

      # The seams exist only under the test-seam compile flag (proved absent
      # in a dev build separately).
      assert Application.get_env(:sdr_agent, :claude_cli_test_seams) == true
    end

    for locks? <- [false, true] do
      test "a completed switch can't be relabelled by a new fail phase (locks: #{locks?})",
           ctx do
        assert {:ok, switch} = request(ctx)
        assert {:ok, completed} = complete(ctx, switch)
        failed_events = count("model.profile.switch_failed", ctx)

        result =
          in_test_phase(ctx, :fail, completed, unquote(locks?), fn context ->
            completed
            |> Ash.Changeset.for_update(:fail, %{failure_reason: "rewritten"},
              actor: ctx.runtime,
              context: context
            )
            |> Ash.update()
          end)

        assert {:error, %Ash.Error.Invalid{}} = result
        assert {:ok, [%{status: :completed, failure_reason: nil}]} = switches(ctx.admin)
        assert count("model.profile.switch_failed", ctx) == failed_events
        assert {:ok, %{desired_profile_id: :claude_cli_sonnet, revision: 2}} = setting(ctx.admin)
      end
    end

    test "a rolled-back apply can't be followed by a completion", ctx do
      assert {:ok, switch} = request(ctx)
      assert {:ok, setting} = setting(ctx.admin)

      result =
        in_test_phase(ctx, :complete, switch, true, fn context ->
          context = ProfileSwitches.advance_test_phase(context)
          SdrAgent.Repo.query!("SAVEPOINT c202a_applied_setting")

          assert {:ok, %{revision: 2}} =
                   setting
                   |> Ash.Changeset.for_update(:apply_switch, %{switch_id: switch.id},
                     actor: ctx.runtime,
                     context: context
                   )
                   |> Ash.update()

          SdrAgent.Repo.query!("ROLLBACK TO SAVEPOINT c202a_applied_setting")

          switch
          |> Ash.Changeset.for_update(:complete, %{}, actor: ctx.runtime, context: context)
          |> Ash.update()
        end)

      assert {:error, %Ash.Error.Invalid{}} = result
      assert {:ok, [%{status: :pending, finished_at: nil}]} = switches(ctx.admin)
      unchanged_setting!(ctx)
      assert count("model.profile.switch_completed", ctx) == 0
    end
  end

  # Runs `fun` behind a genuine phase of `action` for `switch` (the test
  # build's seam), in a transaction, optionally after the `:transition`
  # locks. An `{:error, _}` from `fun` rolls the transaction back.
  defp in_test_phase(ctx, action, switch, locks?, fun) do
    SdrAgent.Repo.transaction(fn ->
      ProfileSwitches.with_test_phase(
        :transition,
        runtime_binding(ctx, action, switch),
        &run_in_test_phase(ctx, switch, locks?, fun, &1)
      )
    end)
    |> case do
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      other -> other
    end
  end

  defp run_in_test_phase(ctx, switch, locks?, fun, context) do
    if locks?, do: lock_for_transition!(switch, ctx.runtime, context)

    case fun.(context) do
      {:ok, value} -> value
      {:error, error} -> SdrAgent.Repo.rollback(error)
    end
  end

  defp unchanged_setting!(ctx) do
    assert {:ok, %{desired_profile_id: :claude_cli_opus, revision: 1}} = setting(ctx.admin)
  end

  ## model_runtime confinement

  describe "model_runtime has no other write authority" do
    setup ctx do
      grant = SdrAgent.AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      %{run: run} = SdrAgent.AgentsFixtures.running_run(ctx.tenant)
      %{grant: grant, run: run, key: grant.allocations |> hd() |> Map.fetch!(:key)}
    end

    # A crash (for example the unknown actor type on main) is observed as a
    # value, so the assertion fails rather than an exception.
    test "creating a grant is Forbidden", ctx do
      attrs = %{
        name: "G-X",
        purpose: "synthetic",
        profile_ids: [:claude_cli_opus],
        total_attempts: 1,
        starts_at: ~U[2026-10-12 00:00:00.000000Z],
        expires_at: ~U[2026-11-06 00:00:00.000000Z],
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               observe(fn -> Agents.create_grant(attrs, actor: ctx.runtime) end)
    end

    test "editing grant terms is Forbidden", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               observe(fn ->
                 Agents.update_grant_terms(
                   ctx.grant,
                   %{expected_revision: ctx.grant.revision, total_attempts: 9},
                   actor: ctx.runtime
                 )
               end)
    end

    test "revoking a grant is Forbidden", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               observe(fn ->
                 Agents.revoke_grant(ctx.grant, %{expected_revision: ctx.grant.revision},
                   actor: ctx.runtime
                 )
               end)
    end

    test "releasing an allocation is Forbidden", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               observe(fn ->
                 Agents.release_allocation(
                   ctx.grant,
                   %{expected_revision: ctx.grant.revision, key: ctx.key},
                   actor: ctx.runtime
                 )
               end)
    end

    test "reserving a model invocation is Forbidden; the same input is allowed for agent_runtime",
         ctx do
      attrs = SdrAgent.AgentsFixtures.model_attrs("runtime-reserve")

      assert {:error, %Ash.Error.Forbidden{}} =
               observe(fn ->
                 Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.runtime)
               end)

      assert {:ok, []} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)

      control = SdrAgent.AgentsFixtures.model_attrs("agent-reserve")
      assert {:ok, _} = Agents.reserve_model_invocation(ctx.run, control, actor: ctx.agent)
    end

    test "a missing or foreign-tenant runtime can't complete, fail or block", ctx do
      switch = pending!(ctx)
      foreign = struct(SdrAgent.Actor, type: :model_runtime, tenant_id: Ecto.UUID.generate())

      for actor <- [nil, foreign] do
        assert {:error, _} =
                 call(:complete_profile_switch, [switch, %{server_generation: 1}, [actor: actor]])

        assert {:error, _} =
                 call(:fail_profile_switch, [
                   switch,
                   %{server_generation: 1, failure_reason: "x"},
                   [actor: actor]
                 ])

        assert {:error, _} =
                 call(:block_profile_switch, [
                   switch,
                   %{server_generation: 1, failure_reason: "x"},
                   [actor: actor]
                 ])
      end

      assert {:ok, [%{status: :pending}]} = switches(ctx.admin)
    end
  end

  ## One transaction, events and audited reads (RED 4)

  describe "transactions, events and audited reads" do
    test "a failure after the setting changes rolls back the setting, the switch and the events",
         ctx do
      switch = pending!(ctx)
      fail_event!("model.profile.switch_completed")

      assert {:error, _} = complete(ctx, switch)
      assert {:ok, %{desired_profile_id: :claude_cli_opus, revision: 1}} = setting(ctx.admin)
      assert {:ok, [%{status: :pending, finished_at: nil}]} = switches(ctx.admin)
      assert count("model.profile.switch_completed", ctx) == 0
    end

    test "a failed first request leaves no setting, switch or event", ctx do
      assert function_exported?(Agents, :request_profile_switch, 2),
             "C2-02a: SdrAgent.Agents.request_profile_switch/2 is not implemented"

      fail_event!("model.profile.switch_requested")
      assert {:error, _} = request(ctx)
      nothing_written(ctx)
    end

    test "events come in order with the documented payload", ctx do
      switch = pending!(ctx)
      assert {:ok, _} = complete(ctx, switch)

      profile_events =
        ctx.tenant
        |> events()
        |> Enum.filter(&String.starts_with?(&1.event_type, "model.profile."))
        |> Enum.sort_by(& &1.sequence)

      assert Enum.map(profile_events, & &1.event_type) == [
               "model.profile.setting_initialized",
               "model.profile.switch_requested",
               "model.profile.switch_completed"
             ]

      [initialized, requested, completed] = profile_events
      assert initialized.payload["desired_profile_id"] == "claude_cli_opus"
      assert initialized.payload["revision"] == 1

      for event <- [requested, completed] do
        assert event.payload["from_profile_id"] == "claude_cli_opus"
        assert event.payload["to_profile_id"] == "claude_cli_sonnet"
        assert event.payload["server_generation"] == 1
      end

      assert completed.payload["setting_revision"] == 2
    end

    test "each auditor read appends its own AuditAccess", ctx do
      _switch = pending!(ctx)
      auditor = human(:auditor, ctx.tenant)

      accesses = fn ->
        hd(hd(SdrAgent.Repo.query!("SELECT count(*) FROM audit_accesses").rows))
      end

      before = accesses.()
      assert {:ok, %{revision: 1}} = setting(auditor)
      after_setting = accesses.()
      assert after_setting == before + 1
      assert {:ok, [_]} = switches(auditor)
      assert accesses.() == after_setting + 1
    end
  end

  defp fail_event!(event_type) do
    SdrAgent.Repo.query!("""
    CREATE FUNCTION sdr_test_fail_switch_event() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected switch event failure'; END $$
    """)

    SdrAgent.Repo.query!(
      "CREATE TRIGGER fail_switch_event BEFORE INSERT ON audit_events FOR EACH ROW " <>
        "WHEN (NEW.event_type = '#{event_type}') EXECUTE FUNCTION sdr_test_fail_switch_event()"
    )
  end

  test "the resources are the accepted ones", _ctx do
    for module <- [@setting, @switch] do
      assert Code.ensure_loaded?(module), "C2-02a: #{inspect(module)} is not implemented"
    end

    assert :model_runtime in SdrAgent.Actor.types(),
           "C2-02a: actor type :model_runtime is missing"
  end
end
