defmodule SdrAgent.Prototype.ImportTenantPropagationTest do
  @moduledoc """
  The reference reads of `SdrAgent.Sales.Validations.ImportTenant` on the
  existing D-237 import actions (Codex 683a74e6; the common error rule of
  Codex 6d1ead6d): Contact `:import_prototype` `account_id`, and Lead
  `:import_prototype` `contact_id` then `account_id`, as the live operator,
  through the raw action (no Guard wrapper, so a statement stream after a
  fault shows only the business path; denial auditing is inspected
  separately in the map).

  Each fault is bound to one exact edge (`%{field:, resource:, id:,
  tenant_id:}`) and a fresh ref through the test-seam build's
  `{ImportTenant, :read_fault}` scope, saved and restored around each call;
  the seam echoes its reach to that ref. Lead has two reads: a fault on
  `account_id` must not be consumed by `contact_id`, whose read succeeds
  first.

  - **Returned Forbidden and Unknown** reach the selected read (exactly
    once), nothing but the owner's rollback follows, nothing survives, and
    (the RED) the injected error must keep its identity: never relabelled
    "is not a row of this tenant". Today's helper folds every returned read
    error into that absence, so this is a reached behavioural RED.
  - **Missing, foreign and positive** stay distinct: a missing reference is
    required at the input, a foreign row is the value-free absence refusal,
    a same-tenant row imports (controls).
  - **A real abort** (tagged `SELECT 1 / 0`, then the real read) shows the
    owner's rollback after the failed read seeing 25P02 and zero survivors,
    under the action's own transaction and under an `SdrAgent.Audit.transaction/1`
    caller; **a fixed synthetic raise** propagates with the same cleanup
    (characterization controls of the unchanged throw and raise paths).
  - **Through the public guarded wrappers** (Guard unchanged, by the
    coordinator's disposition): at top level the action's rollback comes
    first, no business row or event survives, and a returned Forbidden is
    audited as exactly one `authz.denied` of the wrapper's resource and
    action with the caller as the actor (coarse by contract: it cannot be
    told apart from the action's own policy refusal), an Unknown as none;
    under an `SdrAgent.Audit.transaction/1` owner the inner rollback throws
    to the owner, Guard never observes a result and no denial is queued
    (characterization, made explicit).
  - **Seam controls:** a scope for another edge is a no-op (the real read,
    no reach); a prior scope survives an inner scope's return, raise and
    throw; the build without test seams has no fault path (a twin compiled
    from the exact source with the flag false, as the S1 production-branch
    test does).

  Synthetic `.test` data. A foreign row exists only by moving a real row's
  `tenant_id` (`SdrAgent.AuditCase.tamper!/2`).
  """
  use SdrAgent.PrototypeCase, async: false

  alias Ash.Error.Forbidden.ForbiddenField
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Contact
  alias SdrAgent.Sales.Lead
  alias SdrAgent.Sales.Validations.ImportTenant

  @key {ImportTenant, :read_fault}
  @tables %{
    "accounts" => :accounts,
    "contacts" => :contacts,
    "leads" => :leads,
    "audit_events" => :audit_events
  }
  @codes [:division_by_zero, :in_failed_sql_transaction]
  @rollback {:rollback, :none, :ok, nil}
  # Characterized at the first sealed run (c3-20261028T123632Z-96545): the
  # action owner's outcome of a real abort is an Unknown class holding one
  # UnknownError leaf; a raise at the read is raised again as an Ash
  # Unknown (Ash wraps it), after the owner's rollback.
  @action_abort {:error, Ash.Error.Unknown, [{UnknownError, nil}]}

  setup do
    fixture = bound!()
    %{actor: fixture.actor, tenant: fixture.tenant}
  end

  ## Prerequisites (the operator's own import actions)

  defp account!(ctx, n) do
    result =
      Sales.import_prototype_account(
        %{
          name: "Acme #{n} Logistics Software",
          domain: "acme#{n}.test",
          website_url: "https://www.acme#{n}.test/about"
        },
        actor: ctx.actor
      )

    assert match?({:ok, _}, result),
           "prerequisite: the account returned #{inspect(outcome(result))}"

    elem(result, 1)
  end

  defp contact_attrs(account, local \\ "jordan") do
    %{
      account_id: account.id,
      first_name: "Jordan",
      last_name: "Testperson",
      title: "Head of Growth",
      email: "#{local}@#{account.domain}"
    }
  end

  defp contact!(ctx, account, local) do
    result = Sales.import_prototype_contact(contact_attrs(account, local), actor: ctx.actor)

    assert match?({:ok, _}, result),
           "prerequisite: the contact returned #{inspect(outcome(result))}"

    elem(result, 1)
  end

  defp raw(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:import_prototype, attrs, actor: actor)
    |> Ash.create()
  end

  # Moves a real row to another tenant id (see the moduledoc).
  defp move_to_foreign_tenant!(table, id) do
    tamper!("UPDATE #{table} SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(id)
    ])

    :ok
  end

  # One edge's call: {resource, attrs, the edge's field, its referenced
  # resource and id}. Fresh prerequisites per call.
  defp edge(ctx, :contact_account) do
    account = account!(ctx, 1)
    {Contact, contact_attrs(account), :account_id, Account, account.id}
  end

  defp edge(ctx, :lead_contact) do
    account = account!(ctx, 2)
    contact = contact!(ctx, account, "lee")
    {Lead, %{contact_id: contact.id, account_id: account.id}, :contact_id, Contact, contact.id}
  end

  defp edge(ctx, :lead_account) do
    account = account!(ctx, 3)
    contact = contact!(ctx, account, "kim")
    {Lead, %{contact_id: contact.id, account_id: account.id}, :account_id, Account, account.id}
  end

  defp selector(ctx, field, resource, id),
    do: %{field: field, resource: resource, id: id, tenant_id: ctx.tenant.id}

  # Puts the scope for `fun`, then restores the prior one (or its absence)
  # on every exit.
  defp with_fault(scope, fun) do
    previous = Process.get(@key, :__absent__)
    Process.put(@key, scope)

    try do
      fun.()
    after
      if previous == :__absent__, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  ## Observation (closed labels only) and outcomes

  defp observed(fun) do
    parent = self()
    handler = "s3-import-tenant-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:s3_obs, label(metadata)})
      end,
      nil
    )

    value =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {stream([]), value}
  end

  defp stream(acc) do
    receive do
      {:s3_obs, label} -> stream([label | acc])
      {ImportTenant, :reached, ref} -> stream([{:reached, ref} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp label(metadata) do
    {verb(Map.get(metadata, :query)), table(Map.get(metadata, :source)),
     code(Map.get(metadata, :result)), tag(Map.get(metadata, :options))}
  end

  defp verb(query) when is_binary(query) do
    case query |> String.split(" ", parts: 2) |> hd() |> String.downcase() do
      "select" -> :select
      "insert" -> :insert
      "update" -> :update
      "delete" -> :delete
      "rollback" -> :rollback
      "commit" -> :commit
      "begin" -> :begin
      _other -> :other
    end
  end

  defp verb(_query), do: :other

  defp table(nil), do: :none
  defp table(source) when is_binary(source), do: Map.get(@tables, source, :other)
  defp table(_source), do: :other

  defp code({:ok, _result}), do: :ok
  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}) when code in @codes, do: code
  defp code({:error, %Postgrex.Error{}}), do: :other_pg_error
  defp code({:error, _error}), do: :other_error
  defp code(_result), do: :other

  defp tag(options) when is_list(options) do
    case List.keyfind(options, :d237_s3_fault, 0) do
      nil -> nil
      {_key, {:import_tenant, ref}} when is_reference(ref) -> {:import_tenant, ref}
      _other -> :other
    end
  end

  defp tag(_options), do: nil

  # From the seam's reach to the end.
  defp after_reach(stream, ref) do
    case Enum.split_while(stream, &(&1 != {:reached, ref})) do
      {before, [{:reached, ^ref} | rest]} -> {before, rest}
      {before, []} -> {before, :not_reached}
    end
  end

  defp outcome(fun) when is_function(fun, 0) do
    outcome(fun.())
  rescue
    error -> {:raised, error.__struct__}
  end

  defp outcome({:ok, %module{}}), do: {:ok, module}
  defp outcome({:ok, {:ok, %module{}}}), do: {:ok, {:ok, module}}
  defp outcome({:error, %Ash.Query{resource: resource}}), do: {:error, {Ash.Query, resource}}

  defp outcome({:error, %module{errors: errors}}),
    do: {:error, module, Enum.map(errors, &{&1.__struct__, Map.get(&1, :field)})}

  defp outcome(_other), do: :unknown

  defp leaves(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &leaves/1)
  defp leaves(error), do: [error]

  # The value-free business refusal of a missing tenant row.
  defp absent_refusal?({:error, %Ash.Error.Invalid{errors: errors}}, field) do
    Enum.any?(errors, fn error ->
      Map.get(error, :field) == field and
        Map.get(error, :message) == "is not a row of this tenant"
    end)
  end

  defp absent_refusal?(_result, _field), do: false

  defp survivors(ctx) do
    rows =
      Map.new(~w(accounts contacts leads), fn table ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
        {table, n}
      end)

    Map.put(rows, :events, length(events(ctx.tenant)))
  end

  # The injected leaf and its returned class, per kind.
  defp injection(:forbidden, referenced) do
    leaf = ForbiddenField.exception(resource: referenced, field: :s3_probe)
    {leaf, Ash.Error.Forbidden.exception(errors: [leaf])}
  end

  defp injection(:unknown, _referenced) do
    leaf = UnknownError.exception(error: "s3 probe: reference read")
    {leaf, Ash.Error.Unknown.exception(errors: [leaf])}
  end

  # The injected leaf as an action's returned error class carries it. A
  # validation's returned class is kept unchanged in the changeset (so an
  # owner's rolled-back changeset holds `injected` itself), but create's
  # error return (create.ex:228-230, Ash.Error.to_error_class) passes the
  # class through Splode's stacktrace filter, Ash.Error's ["Ash.",
  # "Splode."]: the leaf's frames are filtered and every other field is
  # unchanged. Exactly that, nothing looser.
  defp returned(%{stacktrace: %Splode.Stacktrace{stacktrace: frames}} = leaf)
       when is_list(frames) do
    filtered = Splode.filter_stacktrace(frames, Ash.Error.__stacktrace_filters__())
    %{leaf | stacktrace: %Splode.Stacktrace{stacktrace: filtered}}
  end

  defp sibling_succeeded?(:lead_account, pre), do: {:select, :contacts, :ok, nil} in pre
  defp sibling_succeeded?(_edge, _pre), do: true

  defp owned_call(:action, create), do: create
  defp owned_call(:audit, create), do: fn -> SdrAgent.Audit.transaction(create) end

  @edges [:contact_account, :lead_contact, :lead_account]

  describe "a returned read error keeps its identity (the RED)" do
    for name <- @edges, kind <- [:forbidden, :unknown] do
      test "#{name}, returned #{kind}: reaches exactly that read, then only the rollback; the error is never relabelled as absence",
           ctx do
        {resource, attrs, field, referenced, id} = edge(ctx, unquote(name))
        ref = make_ref()

        {injected, class} = injection(unquote(kind), referenced)
        before = survivors(ctx)
        scope = {selector(ctx, field, referenced, id), ref, {:error, class}}

        {stream, result} =
          observed(fn -> with_fault(scope, fn -> raw(resource, attrs, ctx.actor) end) end)

        {pre, post} = after_reach(stream, ref)
        assert post != :not_reached, "the #{field} read was not reached"
        assert Enum.count(stream, &(&1 == {:reached, ref})) == 1

        # Lead's account read comes after its contact read, which succeeded.
        assert sibling_succeeded?(unquote(name), pre), "no successful contact read first"

        assert post == [@rollback], "after the fault: #{inspect(post)}"
        assert survivors(ctx) == before
        assert match?({:error, _}, result), "the import returned #{inspect(outcome(result))}"

        refute absent_refusal?(result, field),
               "#{field}: the returned #{unquote(kind)} was relabelled as absence"

        assert returned(injected) in leaves(elem(result, 1)),
               "#{field}: the injected leaf is not in #{inspect(outcome(result))}"
      end
    end
  end

  describe "missing, foreign and positive stay distinct (controls)" do
    for name <- @edges do
      test "#{name}: missing is required at the input, foreign is the absence refusal, same-tenant imports",
           ctx do
        {resource, attrs, field, referenced, id} = edge(ctx, unquote(name))
        before = survivors(ctx)

        missing = raw(resource, Map.put(attrs, field, nil), ctx.actor)

        assert match?({:error, %Ash.Error.Invalid{}}, missing) and
                 not absent_refusal?(missing, field),
               "missing #{field}: #{inspect(outcome(missing))}"

        table = AshPostgres.DataLayer.Info.table(referenced)
        :ok = move_to_foreign_tenant!(table, id)
        foreign = raw(resource, attrs, ctx.actor)
        assert absent_refusal?(foreign, field), "foreign #{field}: #{inspect(outcome(foreign))}"
        assert survivors(ctx) == before

        :ok = move_back!(table, id, ctx)
        positive = raw(resource, attrs, ctx.actor)
        assert match?({:ok, %{}}, positive), "same-tenant #{field}: #{inspect(outcome(positive))}"
      end
    end
  end

  defp move_back!(table, id, ctx) do
    tamper!("UPDATE #{table} SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(ctx.tenant.id),
      Ecto.UUID.dump!(id)
    ])

    :ok
  end

  describe "a real abort and a raise at the read (characterization of the unchanged paths)" do
    for {name, owner, expected} <- [
          {:contact_account, :action, @action_abort},
          {:contact_account, :audit, {:error, {Ash.Query, Account}}},
          {:lead_contact, :action, @action_abort},
          {:lead_account, :action, @action_abort},
          {:lead_account, :audit, {:error, {Ash.Query, Account}}}
        ] do
      test "#{name}, abort under the #{owner} owner: the failed read, then the rollback, nothing survives",
           ctx do
        {resource, attrs, field, referenced, id} = edge(ctx, unquote(name))
        ref = make_ref()
        before = survivors(ctx)
        scope = {selector(ctx, field, referenced, id), ref, :abort}

        call = owned_call(unquote(owner), fn -> raw(resource, attrs, ctx.actor) end)

        {stream, result} = observed(fn -> with_fault(scope, fn -> outcome(call) end) end)
        {_pre, post} = after_reach(stream, ref)
        target = Map.fetch!(@tables, AshPostgres.DataLayer.Info.table(referenced))

        assert post == [
                 {:select, :none, :division_by_zero, {:import_tenant, ref}},
                 {:select, target, :in_failed_sql_transaction, nil},
                 @rollback
               ],
               "after the reach: #{inspect(post)}"

        assert result == unquote(Macro.escape(expected)), "outcome #{inspect(result)}"
        assert survivors(ctx) == before
        assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
      end
    end

    test "contact_account, a fixed synthetic raise: it propagates after the owner's rollback",
         ctx do
      {resource, attrs, field, referenced, id} = edge(ctx, :contact_account)
      ref = make_ref()
      before = survivors(ctx)
      scope = {selector(ctx, field, referenced, id), ref, :raise}

      {stream, result} =
        observed(fn ->
          with_fault(scope, fn -> outcome(fn -> raw(resource, attrs, ctx.actor) end) end)
        end)

      {_pre, post} = after_reach(stream, ref)
      assert post == [@rollback], "after the reach: #{inspect(post)}"
      assert result == {:raised, Ash.Error.Unknown}
      assert survivors(ctx) == before
    end
  end

  # Codex 58b1feeb / efd6ca3e and the coordinator's disposition (Guard
  # unchanged; S1's caveats): through the PUBLIC guarded wrappers
  # (Sales.import_prototype_contact/2, import_prototype_lead/2:
  # GuardedCall.create, guarded?: true), a returned reference-read error,
  # with business atomicity and denial audit checked separately.
  # - Top level: the action owns its transaction, so the action's rollback
  #   comes first; Guard then sees the wrapper's result. A Forbidden result
  #   is audited as exactly one authz.denied: the wrapper's resource and
  #   action, the CALLER (the operator delegation) as the actor, this
  #   tenant, after the rollback. Coarse by contract: indistinguishable from
  #   the action's own policy refusal. An Unknown is not audited.
  # - Under an Audit.transaction owner (characterization, made explicit):
  #   the action inherits the owner's transaction, so its rollback-on-error
  #   throws to that owner and Guard.run never observes a result; the owner
  #   returns the rolled-back changeset and no denial is queued.
  defp wrapper(Contact, attrs, actor), do: Sales.import_prototype_contact(attrs, actor: actor)
  defp wrapper(Lead, attrs, actor), do: Sales.import_prototype_lead(attrs, actor: actor)

  defp expected_denials(:forbidden), do: 1
  defp expected_denials(:unknown), do: 0

  @business ~w(sales.account.created sales.contact.created sales.lead.created)

  defp business(ctx) do
    rows = Map.delete(survivors(ctx), :events)
    Map.put(rows, :business_events, Enum.map(@business, &length(events_of_type(ctx.tenant, &1))))
  end

  defp business_write?({verb, table, _code, _tag}),
    do: verb in [:insert, :update, :delete] and table in [:accounts, :contacts, :leads]

  defp business_write?(_marker), do: false

  describe "through the public guarded wrappers (denial audit)" do
    for name <- @edges, kind <- [:forbidden, :unknown] do
      test "#{name}, returned #{kind}, top level: the action's rollback, then the wrapper's exact denial incidence",
           ctx do
        {resource, attrs, field, referenced, id} = edge(ctx, unquote(name))
        {injected, class} = injection(unquote(kind), referenced)
        ref = make_ref()
        rows = business(ctx)
        denials = length(events_of_type(ctx.tenant, "authz.denied"))
        scope = {selector(ctx, field, referenced, id), ref, {:error, class}}

        {stream, result} =
          observed(fn -> with_fault(scope, fn -> wrapper(resource, attrs, ctx.actor) end) end)

        {_pre, post} = after_reach(stream, ref)
        assert post != :not_reached, "the #{field} read was not reached"

        # Business atomicity: the action's own rollback first, no business
        # write after the fault, no business row or creation event survives.
        assert hd(post) == @rollback, "after the reach: #{inspect(post)}"
        refute Enum.any?(post, &business_write?/1), "a business write followed the fault"
        assert business(ctx) == rows

        # Denial audit, separately: exactly the wrapper's denial incidence,
        # attributed exactly (resource, action, caller, tenant).
        new = Enum.drop(events_of_type(ctx.tenant, "authz.denied"), denials)

        assert length(new) == expected_denials(unquote(kind)),
               "#{field} #{unquote(kind)}: #{length(new)} new authz.denied; result #{inspect(outcome(result))}"

        for denial <- new do
          assert {denial.subject_resource, denial.action, denial.actor_type, denial.actor_id,
                  denial.tenant_id} ==
                   {inspect(resource), "import_prototype", :prototype_operator, ctx.actor.id,
                    ctx.tenant.id}
        end

        # The returned error keeps its identity through the wrapper.
        assert match?({:error, _}, result) and returned(injected) in leaves(elem(result, 1)),
               "#{field}: the injected leaf is not in #{inspect(outcome(result))}"
      end
    end

    for name <- [:contact_account, :lead_account], kind <- [:forbidden, :unknown] do
      test "#{name}, returned #{kind}, under an Audit.transaction owner: the owner rolls back; no denial is queued (characterization)",
           ctx do
        {resource, attrs, field, referenced, id} = edge(ctx, unquote(name))
        {injected, class} = injection(unquote(kind), referenced)
        ref = make_ref()
        rows = business(ctx)
        denials = length(events_of_type(ctx.tenant, "authz.denied"))
        scope = {selector(ctx, field, referenced, id), ref, {:error, class}}

        {stream, result} =
          observed(fn ->
            with_fault(scope, fn ->
              SdrAgent.Audit.transaction(fn -> wrapper(resource, attrs, ctx.actor) end)
            end)
          end)

        {_pre, post} = after_reach(stream, ref)
        assert post != :not_reached, "the #{field} read was not reached"

        # The inner wrapper never returns: the owner's rollback is the only
        # statement after the fault and nothing survives.
        assert post == [@rollback], "after the reach: #{inspect(post)}"
        assert business(ctx) == rows

        assert match?({:error, %Ash.Changeset{}}, result),
               "the owner returned #{inspect(outcome(result))}"

        assert Enum.drop(events_of_type(ctx.tenant, "authz.denied"), denials) == [],
               "a denial was queued although Guard.run never observed a result"

        # The returned error keeps its identity in the rolled-back changeset.
        assert injected in leaves(elem(result, 1)),
               "#{field}: the injected leaf is not in the owner's rolled-back changeset"
      end
    end
  end

  describe "seam controls" do
    test "a scope for another edge is a no-op: the real read, no reach, the import succeeds",
         ctx do
      {resource, attrs, field, referenced, _id} = edge(ctx, :contact_account)
      ref = make_ref()
      other = selector(ctx, field, referenced, Ecto.UUID.generate())
      unforced = Ash.Error.Unknown.exception(errors: [UnknownError.exception(error: "unused")])

      {stream, result} =
        observed(fn ->
          with_fault({other, ref, {:error, unforced}}, fn -> raw(resource, attrs, ctx.actor) end)
        end)

      refute {:reached, ref} in stream
      assert match?({:ok, %Contact{}}, result), "the import returned #{inspect(outcome(result))}"
    end

    test "a prior scope survives an inner scope's return, raise and throw" do
      Process.put(@key, :outer)

      assert with_fault(:inner, fn -> Process.get(@key) end) == :inner
      assert Process.get(@key) == :outer
      assert_raise RuntimeError, fn -> with_fault(:inner, fn -> raise "probe" end) end
      assert Process.get(@key) == :outer
      assert catch_throw(with_fault(:inner, fn -> throw(:probe) end)) == :probe
      assert Process.get(@key) == :outer

      Process.delete(@key)
      with_fault(:inner, fn -> :ok end)
      assert Process.get(@key, :absent) == :absent
    end

    @source "lib/sdr_agent/sales/validations/import_tenant.ex"
    @subject "SdrAgent.Sales.Validations.ImportTenant"
    @twin SdrAgent.Sales.Validations.ImportTenantNoSeamTwin

    test "the build without test seams has no fault path (a twin of the exact source, flag false)" do
      twin_source = String.replace(File.read!(@source), @subject, inspect(@twin))
      assert twin_source =~ "defmodule #{inspect(@twin)} do"
      previous = Application.fetch_env(:sdr_agent, :claude_cli_test_seams)

      {modules, diagnostics} =
        try do
          Application.put_env(:sdr_agent, :claude_cli_test_seams, false)

          Code.with_diagnostics(fn ->
            Code.compile_string(twin_source, "import_tenant_no_seam_twin.ex")
          end)
        after
          case previous do
            {:ok, value} -> Application.put_env(:sdr_agent, :claude_cli_test_seams, value)
            :error -> Application.delete_env(:sdr_agent, :claude_cli_test_seams)
          end
        end

      assert diagnostics == [], "the twin compile emitted #{inspect(diagnostics)}"
      assert [{@twin, binary}] = modules
      # The fault path is the local fault/3; the scope key is a literal, not
      # an atom-table entry, so the comparison is of local functions.
      {:ok, {@twin, [locals: twin_locals]}} = :beam_lib.chunks(binary, [:locals])

      {:ok, {ImportTenant, [locals: seam_locals]}} =
        :beam_lib.chunks(:code.which(ImportTenant), [:locals])

      assert {:fault, 3} in seam_locals, "the test-seam build has no fault/3"
      assert {:reference_read, 2} in seam_locals and {:reference_read, 2} in twin_locals
      refute {:fault, 3} in twin_locals, "the no-seam twin has a fault path"
    end
  end
end
