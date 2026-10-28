defmodule SdrAgent.Prototype.SeedInActionFaultTest do
  @moduledoc """
  Read failures bound to the named in-action sites of `SettingsRevision
  :seed_prototype` (Codex ed0a67b5 item 2; targeting ruling d8fc857a; oracle
  corrections T1-T4 of 3749bfb0). Ash authorizes a create in a pre-flight
  (`Ash.can`) before the action's transaction and its `before_action` hooks,
  and the policy's `OperatorAction` runs the full live path there, so a fault
  scope around the whole create would fire in the pre-flight, not at the
  in-action site. The sites are local test-build seams of
  `SdrAgent.Prototype.Changes.SeedAnchor` and
  `SdrAgent.Prototype.Changes.SeedNote`:

  - **G0, the in-action live-check site** (`{SeedAnchor, :live_wrap}`): a
    recording wrapper is entered exactly once per create, inside the
    transaction, after the pre-flight's live read; inside it the real check
    runs exactly once, as exactly this read sequence: the binding row and the
    live identity (`check_live/0`), the binding row and the live identity
    again (`operator_actor/1`'s own `check_live/0`), then the delegation; and
    the create succeeds exactly as without a wrapper. Harness and regression
    controls (scope restoration, another process's wrapper, the closed
    observer labels) are not RED.
  - **G2 and G3, a real SQL abort at the anchor and the provenance Payload
    reads** (`{SeedAnchor | SeedNote, :read_fault} = {:abort, ref}`): exactly
    one tagged `SELECT 1 / 0` (`:division_by_zero`), then the real read at
    that site observing the aborted transaction (`:in_failed_sql_transaction`,
    25P02), then exactly one successful rollback by the owner and nothing
    else (no later business read or write, no recovery); the exact owner
    outcome; no SettingsRevision, `settings.revision.created` event, Payload
    or audit survivor; and `SELECT 1` usable after. Under the action's own
    transaction and under an `SdrAgent.Audit.transaction/1` caller.

  Owner outcomes are closed shapes (an unknown one fails). The sandbox owner
  unwinding is a logical-transaction control, not a committed durability
  proof. The G1 controls, which open S1's live-read fault scope inside the G0
  wrapper, follow S1's seam gate. Observations keep closed labels only
  (statement verb, table, result code, fault tag), never SQL text,
  parameters or error terms. Synthetic `.test` data.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts.User
  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.Audit.Payload
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.Changes.SeedAnchor
  alias SdrAgent.Prototype.Changes.SeedNote

  # The closed observer vocabulary (T3): anything else is :other.
  @verbs %{
    "select" => :select,
    "insert" => :insert,
    "update" => :update,
    "delete" => :delete,
    "begin" => :begin,
    "commit" => :commit,
    "rollback" => :rollback,
    "savepoint" => :savepoint,
    "release" => :release
  }
  @tables %{
    "prototype_database_bindings" => :bindings,
    "prototype_delegations" => :delegations,
    "users" => :users,
    "payloads" => :payloads,
    "settings_revisions" => :settings_revisions,
    "audit_events" => :audit_events
  }
  @codes [:division_by_zero, :in_failed_sql_transaction]
  @fault_sites [:anchor_read, :payload_read]

  # The closed owner-outcome vocabulary (T4): anything else is :other or
  # :unknown, which no expectation names.
  @result_modules [
    SettingsRevision,
    Ash.Error.Invalid,
    Ash.Error.Forbidden,
    Ash.Error.Unknown,
    Ash.Error.Framework
  ]
  @query_resources [User, Payload]

  # The real check inside the wrapper, exactly (T1).
  @live_check [
    {:select, :bindings, :ok, nil},
    {:select, :none, :ok, nil},
    {:select, :bindings, :ok, nil},
    {:select, :none, :ok, nil},
    {:select, :delegations, :ok, nil}
  ]

  setup do
    fixture = bound!()
    provenance = F.stored_provenance!(fixture.actor)
    %{actor: fixture.actor, tenant: fixture.tenant, note: provenance.note}
  end

  defp create(ctx) do
    SettingsRevision
    |> Ash.Changeset.for_create(
      :seed_prototype,
      %{kind: :writing_guide, content: F.seed_contents()["writing_guide.json"], note: ctx.note},
      actor: ctx.actor
    )
    |> Ash.create()
  end

  # The owner of the create's transaction: the action itself, or an Audit
  # transaction around it. The result, a raise or a throw, as a closed shape.
  defp owned(:action, fun), do: outcome(fun)
  defp owned(:audit, fun), do: outcome(fn -> SdrAgent.Audit.transaction(fun) end)

  defp outcome(fun) do
    shape(fun.())
  rescue
    error -> {:raised, closed(error.__struct__, @result_modules)}
  catch
    :throw, _value -> :thrown
  end

  defp shape({tag, value}) when tag in [:ok, :error], do: {tag, inner(value)}
  defp shape(_other), do: :unknown

  defp inner(%Ash.Query{resource: resource}), do: {Ash.Query, closed(resource, @query_resources)}
  defp inner(%module{}), do: closed(module, @result_modules)
  defp inner({tag, _value} = nested) when tag in [:ok, :error], do: shape(nested)
  defp inner(:rollback), do: :rollback
  defp inner(_other), do: :unknown

  defp closed(module, allowed), do: if(module in allowed, do: module, else: :other)

  # Puts `value` under `key` for `fun`, then restores the previous value (or
  # its absence) on every exit, so an outer scope is never erased.
  defp with_seam(key, value, fun) do
    previous = Process.get(key, :__absent__)
    Process.put(key, value)

    try do
      fun.()
    after
      if previous == :__absent__, do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  # The repo statements of this process while `fun` runs, in order, as
  # closed labels, interleaved with the wrapper's own markers; and `fun`'s
  # value.
  defp observed(fun) do
    parent = self()
    handler = "s3-inaction-#{System.unique_integer([:positive])}"

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
      {:s3_wrap, _ref, _event} = marker -> stream([marker | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A closed label {verb, table, result code, fault tag}: each part from its
  # reviewed set, else :other; nothing else of the event leaves the handler.
  defp label(metadata) when is_map(metadata) do
    {verb(Map.get(metadata, :query)), table(Map.get(metadata, :source)),
     code(Map.get(metadata, :result)), tag(Map.get(metadata, :options))}
  end

  defp verb(query) when is_binary(query) do
    word = query |> String.split(" ", parts: 2) |> hd() |> String.downcase()
    Map.get(@verbs, word, :other)
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
      {_key, {site, ref}} when site in @fault_sites and is_reference(ref) -> {site, ref}
      _other -> :other
    end
  end

  defp tag(_options), do: nil

  defp survivors(ctx) do
    tables =
      Map.new(~w(settings_revisions payloads audit_events), fn table ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
        {table, n}
      end)

    Map.put(tables, :created, length(events_of_type(ctx.tenant, "settings.revision.created")))
  end

  describe "G0: the in-action live-check site" do
    for {owner, success} <- [
          action: {:ok, SettingsRevision},
          audit: {:ok, {:ok, SettingsRevision}}
        ] do
      test "a recording wrapper is entered once, after the pre-flight and inside the transaction, around exactly the real check (#{owner} owner)",
           ctx do
        ref = make_ref()
        parent = self()

        wrap = fn inner ->
          send(parent, {:s3_wrap, ref, {:entered, Repo.in_transaction?()}})
          result = inner.()
          send(parent, {:s3_wrap, ref, :returned})
          result
        end

        {stream, result} =
          observed(fn ->
            with_seam({SeedAnchor, :live_wrap}, wrap, fn ->
              owned(unquote(owner), fn -> create(ctx) end)
            end)
          end)

        entered = for {:s3_wrap, ^ref, {:entered, in_tx}} <- stream, do: in_tx
        returned = for {:s3_wrap, ^ref, :returned} <- stream, do: :returned

        assert length(entered) == 1,
               "the in-action wrapper was entered #{length(entered)} times (expected 1)"

        assert entered == [true], "the wrapper was not entered inside the transaction"
        assert returned == [:returned], "the real check did not return through the wrapper"

        assert {before, [_entered | rest]} =
                 Enum.split_while(stream, &(not match?({:s3_wrap, ^ref, {:entered, _}}, &1)))

        assert {inside, [_returned | _after]} =
                 Enum.split_while(rest, &(not match?({:s3_wrap, ^ref, :returned}, &1)))

        # The pre-flight's live read precedes the wrapper (T3 positive).
        assert {:select, :bindings, :ok, nil} in before, "no pre-flight read before the wrapper"
        # Inside it, exactly the real check, once (T1).
        assert inside == @live_check, "inside the wrapper: #{inspect(inside)}"
        # Otherwise unchanged: the create succeeds exactly as without a wrapper.
        assert result == unquote(Macro.escape(success)), "the create returned #{inspect(result)}"
      end
    end

    test "with_seam restores an outer value after a return, a raise and a throw" do
      key = {__MODULE__, :scope_probe}
      Process.put(key, :outer)

      assert with_seam(key, :inner, fn -> Process.get(key) end) == :inner
      assert Process.get(key) == :outer

      assert_raise RuntimeError, fn -> with_seam(key, :inner, fn -> raise "probe" end) end
      assert Process.get(key) == :outer

      assert catch_throw(with_seam(key, :inner, fn -> throw(:probe) end)) == :probe
      assert Process.get(key) == :outer

      Process.delete(key)
      with_seam(key, :inner, fn -> :ok end)
      assert Process.get(key, :absent) == :absent
    end

    test "another process's wrapper is never entered by this process's create", ctx do
      ref = make_ref()
      parent = self()

      other =
        spawn(fn ->
          Process.put({SeedAnchor, :live_wrap}, fn inner ->
            send(parent, {:s3_wrap, ref, :foreign})
            inner.()
          end)

          receive do
            :stop -> :ok
          end
        end)

      result = owned(:action, fn -> create(ctx) end)
      send(other, :stop)

      refute_received {:s3_wrap, ^ref, :foreign}
      assert result == {:ok, SettingsRevision}, "the create returned #{inspect(result)}"
    end

    test "the observer keeps closed labels only, never query text, parameters or error terms" do
      secret = "s3-probe-#{System.unique_integer([:positive])}"
      ref = make_ref()

      cases = [
        {%{
           query: "DROP TABLE #{secret}",
           source: secret,
           params: [secret],
           result:
             {:error, %Postgrex.Error{postgres: %{code: :unique_violation, message: secret}}},
           options: [d237_s3_fault: {:other_site, ref}]
         }, {:other, :other, :other_pg_error, :other}},
        {%{
           query: "SELECT #{secret} FROM users",
           source: "users",
           result: {:error, %RuntimeError{message: secret}},
           options: [d237_s3_fault: secret]
         }, {:select, :users, :other_error, :other}},
        {%{query: ["SELECT"], source: nil, result: secret, options: :not_a_list},
         {:other, :none, :other, nil}},
        {%{
           query: "rollback",
           source: nil,
           result: {:ok, secret},
           options: [d237_s3_fault: {:anchor_read, ref}]
         }, {:rollback, :none, :ok, {:anchor_read, ref}}},
        {%{}, {:other, :none, :other, nil}}
      ]

      for {metadata, expected} <- cases do
        result = label(metadata)
        assert result == expected
        refute inspect(result) =~ secret
      end
    end
  end

  # G2 and G3: the anchor read (SeedAnchor's before_action) and the
  # provenance Payload read (SeedNote's, after it), with each owner's exact
  # outcome (T4).
  @g23 [
    {:anchor_read, SeedAnchor, :users, :action, {:error, Ash.Error.Unknown}},
    {:anchor_read, SeedAnchor, :users, :audit, {:error, {Ash.Query, User}}},
    {:payload_read, SeedNote, :payloads, :action, {:error, Ash.Error.Unknown}},
    {:payload_read, SeedNote, :payloads, :audit, {:error, {Ash.Query, Payload}}}
  ]

  describe "G2/G3: a real SQL abort at the anchor and the Payload reads" do
    for {site, module, table, owner, expected} <- @g23 do
      test "#{site}: one tagged abort, the real read sees 25P02, then exactly the owner's rollback, no survivor (#{owner} owner)",
           ctx do
        site = unquote(site)
        table = unquote(table)
        ref = make_ref()
        before = survivors(ctx)

        {stream, result} =
          observed(fn ->
            with_seam({unquote(module), :read_fault}, {:abort, ref}, fn ->
              owned(unquote(owner), fn -> create(ctx) end)
            end)
          end)

        tagged = Enum.filter(stream, &match?({_verb, _table, _code, {^site, ^ref}}, &1))

        assert length(tagged) == 1,
               "#{site}: #{length(tagged)} tagged abort statements (expected 1); " <>
                 "result #{inspect(result)}"

        assert {_head, [{:select, :none, :division_by_zero, {^site, ^ref}} | rest]} =
                 Enum.split_while(stream, &(not match?({_v, _t, _c, {^site, ^ref}}, &1))),
               "#{site}: stream #{inspect(stream)}"

        # The real read at the named site observes the aborted transaction,
        # then exactly one successful owner rollback and nothing else (T2).
        assert rest == [
                 {:select, table, :in_failed_sql_transaction, nil},
                 {:rollback, :none, :ok, nil}
               ],
               "#{site}: after the abort #{inspect(rest)}"

        assert result == unquote(Macro.escape(expected)),
               "#{site}: owner outcome #{inspect(result)}"

        assert survivors(ctx) == before
        assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
      end
    end
  end
end
