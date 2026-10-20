defmodule SdrAgent.SDR.DefinitionBootstrapTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 N (T-N1..T-N9; T-N10 and T-N11 are [P],
  in `definition_bootstrap_physical_test.exs`): the definition bootstrap
  lifecycle of sections 7.2 and 7.3. `SDR.bootstrap_definitions/1` is the
  only registration path of the `SDRAgent` definition (idempotent, refused
  inside a transaction); `SDRAgent.fetch_definition/1` is a read-only
  lookup that compares the stored hash with the hash of current code;
  standalone `assign_lead/2` and `ReplyIntake.received/3` fail closed on a
  miss and never register; the boot child `SDR.DefinitionBootstrap` runs
  after the Repo and before Oban and the Endpoint, and every outcome goes
  through `disposition/1` (D-174 Q-O4: any non-success is
  `{:error, {:definition_bootstrap_failed, class}}`; only "no tenant" is
  `:ignore`); `Demo.Seed` and `mix sdr.bootstrap_admin` register. G3-2
  (Codex 944d822, added after RED-2): every DB call of the boot run gets
  `min(remaining, 5_000)` and no attempt starts once the budget is spent.

  RED form: absent subjects are guarded (`Code.ensure_loaded?/1`,
  `function_exported?/3`) and called through `apply/3`. T-N6, T-N7 and
  T-N8 are behavioural: `assign_lead/2`, `ReplyIntake.received/3`,
  `Demo.Seed.run/0` and the mix task exist on main (main registers on
  assignment and on a matched reply, and the seed and the task register
  nothing). The rest are structural.

  Interface names chosen here for review:
  `DefinitionBootstrap.run(opts)` runs the work in the caller and returns
  `:no_tenant | {:ok, [definition]} | {:error, class}`;
  `DefinitionBootstrap.disposition(outcome)` takes `:no_tenant`,
  `{:ok, definitions}`, `{:error, class}`, `{:crash, reason}` or
  `:timeout` and returns `:ignore` (no tenant only), `:ok`, or
  `{:error, {:definition_bootstrap_failed, class}}`, an unknown error term
  being reduced to one of the sanitized classes; `start_link(opts)`
  returns `:ignore`, `{:ok, pid}` on success, or the failure tuple, and
  takes `deadline_ms:` (default from config, proposed 30 000);
  `SDR.assign_lead/2` on a miss returns
  `{:error, :agent_definition_unavailable}`; a pre-existing different-hash
  `SDRAgent` row of the code's version makes `bootstrap_definitions/1`
  return `{:error, :definition_conflict}`.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Ash.Query

  alias Mix.Tasks.Sdr.BootstrapAdmin
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.Runtime, as: ModelProviderRuntime
  alias SdrAgent.Application, as: App
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR
  alias SdrAgent.SDR.ReplyIntake
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SettingsFixtures

  @sdr SdrAgent.SDR
  @bootstrap SdrAgent.SDR.DefinitionBootstrap
  @lookup SdrAgent.SDR.SDRAgent
  @classes [:timeout, :crash, :schema_not_migrated, :connection, :definition_conflict]
  @unavailable :agent_definition_unavailable
  @counted ~w(agent_definitions agent_runs run_settings_snapshots oban_jobs audit_events)
  @row_lock ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/
  @write ~r/^\s*(INSERT|UPDATE|DELETE)\b/i
  # Test-only password for the bootstrap_admin task (synthetic).
  @admin_password "c302-stdin-password-0123456789"

  describe "T-N1 boot child order (section 7.3)" do
    test "T-N1 DefinitionBootstrap starts after the Repo and before the provider, Oban, PubSub, the Relay and the Endpoint" do
      guard_child!()
      modules = Enum.map(App.children(), &child_module/1)

      assert Enum.count(modules, &(&1 == @bootstrap)) == 1,
             "C3-02: DefinitionBootstrap is one child of SdrAgent.Application"

      at = Enum.find_index(modules, &(&1 == @bootstrap))
      assert position!(modules, SdrAgent.Repo) < at, "C3-02: after SdrAgent.Repo"

      later =
        Enum.map(ModelProviderRuntime.children(), &child_module/1) ++
          [Oban, Phoenix.PubSub, SdrAgent.LiveEvents.Relay, SdrAgentWeb.Endpoint]

      for module <- later do
        assert at < position!(modules, module), "C3-02: before #{inspect(module)}"
      end
    end
  end

  describe "T-N2 no tenant" do
    test "T-N2 with no tenant, run/1 is :no_tenant and start_link/1 is :ignore; nothing written" do
      guard_child!()

      assert AuditKernel.singleton_tenant_id() == {:error, :tenant_not_bootstrapped},
             "precondition: no tenant"

      before = counts()
      assert run_bootstrap([]) == :no_tenant
      assert start_child([]) == :ignore
      assert counts() == before
    end

    # G3-2b (Codex 9d5c5c2): a late "no tenant" is not accepted either.
    test "G3-2b a no-tenant answer that arrives after the deadline is :timeout" do
      guard_child!()
      late = fn step -> if step == :tenant, do: Process.sleep(300) end
      result = run_bootstrap(deadline_ms: 100, test_hooks: [observer: self(), after_call: late])

      assert [:tenant | _] = Enum.map(observed_calls(), &elem(&1, 0)),
             "not established: the tenant read did not run"

      assert result == {:error, :timeout}, "C3-02: a late answer was accepted: #{short(result)}"
    end
  end

  describe "T-N3..T-N5 and T-N9 with a tenant" do
    setup do
      %{tenant: bootstrap!()}
    end

    test "T-N3 bootstrap_definitions/1 is idempotent: one valid row, one event", ctx do
      guard_bootstrap!()
      guard_child!()
      first = bootstrap_definitions(ctx.tenant.id)

      assert match?({:ok, %AgentDefinition{}}, first),
             "C3-02: bootstrap_definitions/1: #{short(first)}"

      {:ok, definition} = first
      assert_valid!(definition, ctx.tenant.id)
      assert {:ok, again} = bootstrap_definitions(ctx.tenant.id)
      assert again.id == definition.id
      assert {:ok, [via_run]} = run_bootstrap([])
      assert via_run.id == definition.id
      assert ids(definitions(ctx.tenant.id)) == [definition.id]

      assert length(events_of_type(ctx.tenant, "agents.definition.registered")) == 1,
             "C3-02: a repeated bootstrap writes nothing"
    end

    test "T-N4 disposition/1 maps every outcome; only no tenant is :ignore; no message leaks" do
      guard_child!()
      canary = "c302canary#{SalesFixtures.unique()}"
      crash = %RuntimeError{message: canary}
      definition = struct(AgentDefinition, name: "SDRAgent", version: SDRAgent.version())

      outcomes =
        [
          {:no_tenant, :ignore},
          {{:ok, [definition]}, :ok},
          {:timeout, failed(:timeout)},
          {{:crash, crash}, failed(:crash)},
          {{:crash, {crash, []}}, failed(:crash)}
        ] ++ for(class <- @classes, do: {{:error, class}, failed(class)})

      log =
        capture_log([level: :debug], fn ->
          for {outcome, expected} <- outcomes do
            assert disposition(outcome) == expected, "C3-02: disposition(#{inspect(outcome)})"
          end

          unknown = disposition({:error, {:c302_unexpected, canary}})

          assert match?(
                   {:error, {:definition_bootstrap_failed, class}} when class in @classes,
                   unknown
                 ),
                 "C3-02: an unknown error is reduced to a sanitized class"

          refute inspect(unknown) =~ canary
        end)

      refute log =~ canary, "C3-02: a crash reaches the disposition without its message"
      ignored = for {outcome, _} <- outcomes, disposition(outcome) == :ignore, do: outcome
      assert ignored == [:no_tenant], "C3-02: only no tenant returns :ignore"
    end

    test "T-N4 start_link/1 returns the disposition of the real outcome (success)", ctx do
      guard_child!()
      started = start_child([])

      assert match?({:ok, pid} when is_pid(pid), started),
             "C3-02: a successful bootstrap starts the child: #{short(started)}"

      {:ok, pid} = started
      stop!(pid)
      assert [definition] = definitions(ctx.tenant.id)
      assert_valid!(definition, ctx.tenant.id)
    end

    test "T-N4 start_link/1 refuses to start on a different-hash definition (definition_conflict)",
         ctx do
      guard_child!()
      guard_bootstrap!()
      winner = hash_different!(ctx.tenant)
      assert start_child([]) == failed(:definition_conflict)
      assert run_bootstrap([]) == {:error, :definition_conflict}
      assert bootstrap_definitions(ctx.tenant.id) == {:error, :definition_conflict}
      assert ids(definitions(ctx.tenant.id)) == [winner.id]
    end

    test "T-N5 fetch_definition/1 refuses a missing definition, never registers, never locks",
         ctx do
      guard_lookup!()
      # A definition of another version (the fixture's SDRAgent v1) does not count.
      AgentsFixtures.definition!(ctx.tenant)
      before = counts()

      for tenant_id <- [ctx.tenant.id, Ecto.UUID.generate()] do
        {result, queries} = trace(fn -> fetch_definition(tenant_id) end)
        assert result == {:error, @unavailable}, "C3-02: a missing definition is unavailable"
        assert_read_only!(queries)
      end

      assert counts() == before
      assert definitions(ctx.tenant.id) == []
    end

    test "T-N5 fetch_definition/1 refuses a retired definition", ctx do
      guard_lookup!()
      retired = retired!(ctx.tenant)
      {result, queries} = trace(fn -> fetch_definition(ctx.tenant.id) end)
      assert result == {:error, @unavailable}, "C3-02: a retired definition is unavailable"
      assert_read_only!(queries)
      assert snapshot(definitions(ctx.tenant.id)) == snapshot([retired])
    end

    test "T-N5 fetch_definition/1 refuses an active definition whose hash is not current code's",
         ctx do
      guard_lookup!()
      other = hash_different!(ctx.tenant)
      {result, queries} = trace(fn -> fetch_definition(ctx.tenant.id) end)
      assert result == {:error, @unavailable}, "C3-02: a different-hash definition is unavailable"
      assert_read_only!(queries)
      assert snapshot(definitions(ctx.tenant.id)) == snapshot([other])
    end

    test "T-N5 fetch_definition/1 returns the bootstrapped definition", ctx do
      guard_lookup!()
      guard_bootstrap!()
      assert {:ok, definition} = bootstrap_definitions(ctx.tenant.id)
      {result, queries} = trace(fn -> fetch_definition(ctx.tenant.id) end)
      assert match?({:ok, %AgentDefinition{}}, result), "C3-02: got #{short(result)}"
      {:ok, found} = result
      assert found.id == definition.id
      assert_read_only!(queries)
    end

    test "T-N9 inside a transaction bootstrap_definitions/1 refuses and writes nothing", ctx do
      guard_bootstrap!()
      before = counts()

      assert Audit.transaction(fn -> bootstrap_definitions(ctx.tenant.id) end) ==
               {:ok, {:error, :bootstrap_in_transaction}},
             "C3-02: refused inside Audit.transaction/1"

      assert Repo.transaction(fn -> bootstrap_definitions(ctx.tenant.id) end) ==
               {:ok, {:error, :bootstrap_in_transaction}},
             "C3-02: refused inside a Repo transaction"

      assert counts() == before
      assert definitions(ctx.tenant.id) == []
    end
  end

  # G3-2 (Codex 944d822 review): plan r8 section 7.3, "each DB call uses
  # timeout: min(remaining, 5_000)", for the tenant enumeration, the
  # registration and the post-rollback re-read; no attempt starts once the
  # budget is spent, including after a backoff. Observed through the
  # test-build hooks of `DefinitionBootstrap.run/1` (`test_hooks:`, absent
  # from dev and prod): `observer:` receives `{:c302_bootstrap_call, step,
  # timeout}` for each DB call with the client timeout that call is
  # actually given (`:default` when none), `{:c302_bootstrap_attempt, n}`
  # and `{:c302_bootstrap_outcome, n, outcome}` for each attempt; `connection_faults:`
  # makes the first n attempts fail as `:connection` before any DB call;
  # `backoff_ms:` and `sleep:` replace the backoff and its sleep. The
  # physical proof that a blocked read is cut off by its client timeout is
  # T-N10 in `definition_bootstrap_physical_test.exs`.
  describe "G3-2 the boot budget bounds every DB call" do
    setup do
      %{tenant: bootstrap!()}
    end

    test "G3-2 every DB call of run/1 gets min(remaining, cap), lowered by step_ms, through the re-read",
         ctx do
      # An existing other-hash row: tenant read, registration (refused), then
      # the re-read outside the ended transaction.
      hash_different!(ctx.tenant)
      result = run_bootstrap(deadline_ms: 3_000, step_ms: 700, test_hooks: [observer: self()])
      assert result == {:error, :definition_conflict}, "C3-02: got #{short(result)}"
      calls = observed_calls()
      steps = Enum.map(calls, &elem(&1, 0))

      for step <- [:tenant, :registration, :reread] do
        assert step in steps, "C3-02: the #{step} call ran without a bounded timeout"
      end

      assert Enum.find_index(steps, &(&1 == :tenant)) < Enum.find_index(steps, &(&1 == :reread))

      for {step, timeout_ms} <- calls do
        assert is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= 700,
               "C3-02: #{step} got timeout #{inspect(timeout_ms)}, not min(remaining, 700)"
      end
    end

    test "G3-2 a spent budget starts no DB call", ctx do
      before = counts()

      {result, queries} =
        trace(fn -> run_bootstrap(deadline_ms: 0, test_hooks: [observer: self()]) end)

      assert result == {:error, :timeout}, "C3-02: got #{short(result)}"
      assert queries == [], "C3-02: a spent budget must not start a DB call"
      assert observed_calls() == []
      assert counts() == before
      assert definitions(ctx.tenant.id) == []
    end

    # G3-2b (Codex 9d5c5c2): a read that returns successfully after the
    # deadline (made late by the `after_call:` hook) is not accepted.
    # Control: the next call's budget check already refuses it at this head.
    test "G3-2b (control) a late tenant answer is :timeout; nothing registered",
         ctx do
      late = fn step -> if step == :tenant, do: Process.sleep(300) end
      result = run_bootstrap(deadline_ms: 100, test_hooks: [observer: self(), after_call: late])

      assert [:tenant | _] = Enum.map(observed_calls(), &elem(&1, 0)),
             "not established: the tenant read did not run"

      assert result == {:error, :timeout}, "C3-02: a late answer was accepted: #{short(result)}"
      assert definitions(ctx.tenant.id) == []
    end

    test "G3-2b a winner re-read that returns after the deadline is :timeout", ctx do
      hash_different!(ctx.tenant)
      late = fn step -> if step == :reread, do: Process.sleep(400) end

      result =
        run_bootstrap(deadline_ms: 250, test_hooks: [observer: self(), after_call: late])

      assert :reread in Enum.map(observed_calls(), &elem(&1, 0)),
             "not established: the re-read did not run"

      assert result == {:error, :timeout}, "C3-02: a late re-read was accepted: #{short(result)}"
    end

    test "G3-2 no attempt starts after a backoff that outlived the budget", ctx do
      parent = self()
      started = System.monotonic_time(:millisecond)

      hooks = [
        observer: parent,
        connection_faults: 10,
        backoff_ms: 50,
        sleep: fn ms ->
          Process.sleep(ms + 300)
          send(parent, {:c302_backoff, ms, System.monotonic_time(:millisecond)})
        end
      ]

      result = run_bootstrap(deadline_ms: 200, test_hooks: hooks)

      # Preconditions: the injected connection failure came first, and the
      # selected backoff ran and ended past the 200 ms budget.
      assert [{1, {:error, :connection}} | _] = observed_outcomes(),
             "C3-02: not established: the first attempt was not the injected connection failure"

      assert_received {:c302_backoff, 50, slept_until}, "C3-02: not established: no backoff ran"

      assert slept_until >= started + 200,
             "C3-02: not established: the backoff did not outlive the budget"

      assert observed_attempts() == [1], "C3-02: a second attempt started after the budget"
      assert result == {:error, :timeout}, "C3-02: got #{short(result)}"
      assert definitions(ctx.tenant.id) == []
    end
  end

  describe "T-N6 and T-N7 request paths on a miss" do
    setup do
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      SettingsFixtures.save_offering!(admin)
      contact = SalesFixtures.contact!(tenant)

      # Source :fixture, the only seed source valid after the cutover (C3-R1,
      # T-E3); the miss under test does not depend on the lead's source.
      {:ok, lead} =
        Sales.seed_lead(
          %{
            id: Ecto.UUID.generate(),
            contact_id: contact.id,
            account_id: contact.account_id,
            source: :fixture
          },
          actor: system_actor(:seeder, tenant)
        )

      %{
        tenant: tenant,
        admin: admin,
        lead: lead,
        campaign: SalesFixtures.active_campaign!(tenant)
      }
    end

    # Behavioural RED: main registers the definition under the head and assigns.
    test "T-N6 assign_lead/2 on a miss returns :agent_definition_unavailable and writes nothing",
         ctx do
      before = counts()

      result =
        outcome(fn ->
          SDR.assign_lead(ctx.lead, actor: ctx.admin, campaign_id: ctx.campaign.id)
        end)

      assert result == {:error, @unavailable},
             "C3-02: a definition miss fails closed before any write: #{short(result)}"

      assert counts() == before
      assert definitions(ctx.tenant.id) == []
      assert {:ok, %{status: :new}} = Sales.fetch(Sales.Lead, ctx.lead.id, actor: ctx.admin)
    end

    # Behavioural RED: main registers at reply_intake.ex:28 and hands off at once.
    for variant <- [:absent, :retired, :hash_different] do
      @tag variant: variant
      test "T-N7 ReplyIntake.received/3 on a #{variant} definition defers and writes nothing",
           %{variant: variant} = ctx do
        existing = ctx.tenant |> miss!(variant) |> snapshot()
        before = counts()
        reply = %{id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id, webhook_event_id: uuid()}
        match = %{lead_id: ctx.lead.id, campaign_id: ctx.campaign.id, enrollment_id: uuid()}
        ingestor = system_actor(:webhook_ingestor, ctx.tenant)

        result =
          outcome(fn ->
            Audit.transaction(fn -> ReplyIntake.received(reply, match, ingestor) end)
          end)

        assert result == {:ok, {:deferred, @unavailable}},
               "C3-02: the hand-off defers on a #{variant} definition: #{short(result)}"

        assert counts() == before, "C3-02: no run, snapshot, job or event"
        assert snapshot(definitions(ctx.tenant.id)) == existing, "C3-02: it never registers"
      end
    end
  end

  describe "T-N8 tenants created after boot" do
    # Behavioural RED: on main the seed and the task register no definition.
    test "T-N8 Demo.Seed registers the definition after bootstrapping the tenant" do
      assert {:ok, _summary} = Seed.run()
      assert_registered!()
    end

    test "T-N8 mix sdr.bootstrap_admin registers the definition after bootstrapping the tenant" do
      result = run_admin_task()
      refute match?({:raised, _}, result), "the task must succeed: #{short(result)}"
      assert_registered!()
    end
  end

  ## Subjects and fixtures

  defp miss!(_tenant, :absent), do: []
  defp miss!(tenant, :retired), do: [retired!(tenant)]
  defp miss!(tenant, :hash_different), do: [hash_different!(tenant)]

  defp retired!(tenant) do
    assert {:ok, definition} = SDRAgent.register(tenant.id)
    assert {:ok, retired} = Agents.retire_definition(definition, actor: kernel(tenant))
    assert retired.status == :retired
    retired
  end

  # An active row at the code's name and version with a hash that is not
  # the hash of current code (main's register_definition/2 accepts it).
  defp hash_different!(tenant) do
    assert {:ok, definition} =
             Agents.register_definition(
               %{
                 name: "SDRAgent",
                 version: SDRAgent.version(),
                 module: inspect(SDRAgent),
                 definition: %{"c302" => "hash-different"}
               },
               actor: kernel(tenant)
             )

    refute definition.definition_sha256 == code_sha()
    definition
  end

  defp kernel(tenant), do: Actor.system(:kernel, tenant.id)

  defp run_admin_task do
    argv = ["--email", "c302-admin-#{SalesFixtures.unique()}@example.test", "--password-stdin"]

    capture_log([level: :debug], fn -> capture_stderr(argv) end)
    assert_received {:c302_task, result}
    result
  end

  defp capture_stderr(argv), do: capture_io(:stderr, fn -> capture_stdin(argv) end)

  defp capture_stdin(argv) do
    capture_io(@admin_password <> "\n", fn ->
      send(self(), {:c302_task, task_outcome(argv)})
    end)
  end

  defp task_outcome(argv) do
    BootstrapAdmin.run(argv)
  rescue
    error in Mix.Error -> {:raised, Exception.message(error)}
  end

  ## Assertions

  defp assert_registered! do
    assert {:ok, tenant_id} = AuditKernel.singleton_tenant_id()
    found = definitions(tenant_id)

    assert match?([%AgentDefinition{}], found),
           "C3-02: the new tenant gets its SDRAgent definition"

    [definition] = found
    assert_valid!(definition, tenant_id)
  end

  defp assert_valid!(definition, tenant_id) do
    assert {definition.tenant_id, definition.name, definition.version, definition.status} ==
             {tenant_id, "SDRAgent", SDRAgent.version(), :active}

    assert definition.definition_sha256 == code_sha(), "C3-02: the hash of current code"
  end

  defp assert_read_only!(queries) do
    for {sql, _params} <- queries do
      refute sql =~ @row_lock, "C3-02: the lookup never locks"
      refute sql =~ @write, "C3-02: the lookup never writes"
    end
  end

  defp failed(class), do: {:error, {:definition_bootstrap_failed, class}}

  defp child_module(module) when is_atom(module), do: module
  defp child_module({module, _arg}) when is_atom(module), do: module
  defp child_module(%{start: {module, _function, _args}}), do: module

  defp position!(modules, module) do
    at = Enum.find_index(modules, &(&1 == module))
    assert at, "#{inspect(module)} is a child of SdrAgent.Application"
    at
  end

  ## Reads

  defp definitions(tenant_id) do
    code_version = SDRAgent.version()

    AgentDefinition
    |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and name == "SDRAgent" and version == ^code_version
    )
    |> Ash.read!()
    |> Enum.sort_by(& &1.id)
  end

  defp snapshot(definitions),
    do: Enum.map(definitions, &{&1.id, &1.status, &1.definition_sha256})

  defp ids(definitions), do: Enum.map(definitions, & &1.id)

  defp code_sha, do: Canonical.sha256(SDRAgent.definition_body())

  defp counts do
    Map.new(@counted, fn table ->
      %{rows: [[count]]} = Repo.query!(~s{SELECT count(*) FROM "#{table}"})
      {table, count}
    end)
  end

  defp uuid, do: Ecto.UUID.generate()

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp guard_bootstrap!, do: present!(@sdr, :bootstrap_definitions, 1)
  defp guard_lookup!, do: present!(@lookup, :fetch_definition, 1)

  defp guard_child! do
    present!(@bootstrap, :start_link, 1)
    present!(@bootstrap, :run, 1)
    present!(@bootstrap, :disposition, 1)
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp bootstrap_definitions(tenant_id), do: call(@sdr, :bootstrap_definitions, [tenant_id])
  defp fetch_definition(tenant_id), do: call(@lookup, :fetch_definition, [tenant_id])
  defp run_bootstrap(opts), do: call(@bootstrap, :run, [opts])
  defp disposition(outcome), do: call(@bootstrap, :disposition, [outcome])

  # start_link/1 links the child to the caller: trap exits around it so a
  # refused start reaches the assertion as a value.
  defp start_child(opts) do
    previous = Process.flag(:trap_exit, true)

    try do
      call(@bootstrap, :start_link, [opts])
    after
      Process.flag(:trap_exit, previous)
      flush_exits()
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp stop!(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  # G3-2: the hook messages the bootstrap sent to this process.
  defp observed_calls do
    receive do
      {:c302_bootstrap_call, step, timeout_ms} -> [{step, timeout_ms} | observed_calls()]
    after
      0 -> []
    end
  end

  defp observed_outcomes do
    receive do
      {:c302_bootstrap_outcome, n, outcome} -> [{n, outcome} | observed_outcomes()]
    after
      0 -> []
    end
  end

  defp observed_attempts do
    receive do
      {:c302_bootstrap_attempt, n} -> [n | observed_attempts()]
    after
      0 -> []
    end
  end

  defp outcome(fun) do
    fun.()
  rescue
    error -> {:raised, error.__struct__}
  end

  defp short(term), do: inspect(term, limit: 12, printable_limit: 300)

  ## Query tracing

  defp trace(fun) do
    parent = self()
    handler = "c3-02-definition-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent do
            send(parent, {:c302_query, IO.iodata_to_binary(metadata.query), metadata[:params]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(acc) do
    receive do
      {:c302_query, sql, params} -> drain([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
