defmodule SdrAgent.Prototype.SeedInActionFaultTest do
  @moduledoc """
  Read failures bound to the named in-action sites of `SettingsRevision
  :seed_prototype` (Codex ed0a67b5 item 2; targeting ruling d8fc857a). Ash
  authorizes a create in a pre-flight (`Ash.can`) before the action's
  transaction and its `before_action` hooks, and the policy's
  `OperatorAction` runs the full live path there, so a fault scope around the
  whole create would fire in the pre-flight, not at the in-action site.

  This stage is the RED of the seam-independent part, with the sites only
  declared (no-op) in `SdrAgent.Prototype.Changes.SeedAnchor` and
  `SdrAgent.Prototype.Changes.SeedNote`:

  - **G0, the in-action live-check site** (`{SeedAnchor, :live_wrap}`): a
    recording wrapper must be entered exactly once per create, after the
    pre-flight and inside the transaction, with the real live check running
    inside it exactly once and the create otherwise unchanged. Harness and
    regression controls (scope restoration, another process's wrapper) pass
    already and are not RED.
  - **G2 and G3, a real SQL abort at the anchor and the provenance Payload
    reads** (`{SeedAnchor | SeedNote, :read_fault} = {:abort, ref}`): one
    tagged `SELECT 1 / 0` (`:division_by_zero`), then the real read at that
    site observing the aborted transaction (`:in_failed_sql_transaction`,
    25P02), then no later business read or write before the owner's
    rollback; no SettingsRevision, `settings.revision.created` event, Payload
    or audit survivor and no seed success, under the action's own transaction
    and under an `SdrAgent.Audit.transaction/1` caller.

  Owner result shapes are recorded as diagnostics only; they are pinned after
  the seam's reviewed GREEN characterizes them. The G1 controls, which open
  S1's live-read fault scope inside the G0 wrapper, follow S1's seam gate.
  Observations keep finite labels (statement verb, table, result code, tag),
  never SQL text, parameters or error terms. Synthetic `.test` data.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.Changes.SeedAnchor
  alias SdrAgent.Prototype.Changes.SeedNote

  @owners [:action, :audit]

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
  # transaction around it. The result, a raise or a throw, as a shape.
  defp owned(:action, fun), do: outcome(fun)
  defp owned(:audit, fun), do: outcome(fn -> SdrAgent.Audit.transaction(fun) end)

  defp outcome(fun) do
    shape(fun.())
  rescue
    error -> {:raised, error.__struct__}
  catch
    :throw, value -> {:thrown, shape(value)}
  end

  defp shape({tag, %Ash.Query{resource: resource}}), do: {tag, {Ash.Query, resource}}
  defp shape({tag, {inner, value}}), do: {tag, shape({inner, value})}
  defp shape({tag, %module{}}), do: {tag, module}
  defp shape({tag, value}) when is_atom(value), do: {tag, value}
  defp shape(value) when is_atom(value), do: value
  defp shape(_value), do: :value

  defp success?(shape),
    do: shape in [{:ok, SettingsRevision}, {:ok, {:ok, SettingsRevision}}]

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
  # finite labels {verb, table, result code, fault tag}, interleaved with the
  # wrapper's own {:wrap, ...} markers; and `fun`'s value.
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

  defp label(metadata) do
    tag = Keyword.get(Map.get(metadata, :options) || [], :d237_s3_fault)
    {verb(metadata[:query]), metadata[:source], code(metadata[:result]), tag}
  end

  defp verb(query) when is_binary(query) or is_atom(query),
    do: query |> to_string() |> String.split(" ", parts: 2) |> hd() |> String.downcase()

  defp verb(_query), do: "other"

  defp code({:ok, _result}), do: :ok
  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp code({:error, %module{}}), do: module
  defp code(_result), do: :other

  defp survivors(ctx) do
    tables =
      Map.new(~w(settings_revisions payloads audit_events), fn table ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
        {table, n}
      end)

    Map.put(tables, :created, length(events_of_type(ctx.tenant, "settings.revision.created")))
  end

  defp sources(labels), do: for({_verb, source, _code, _tag} <- labels, source, do: source)

  describe "G0: the in-action live-check site" do
    for owner <- @owners do
      test "a recording wrapper is entered once, after the pre-flight and inside the transaction, around the real check (#{owner} owner)",
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

        {inside, _after} = Enum.split_while(rest, &(not match?({:s3_wrap, ^ref, :returned}, &1)))

        # The pre-flight's live read precedes the wrapper; the real check runs
        # inside it (the binding and the delegation reads).
        assert "prototype_database_bindings" in sources(before)
        assert "prototype_database_bindings" in sources(inside)
        assert "prototype_delegations" in sources(inside)
        # Otherwise unchanged: the create succeeds as without a wrapper.
        assert success?(result), "the create returned #{inspect(result)}"
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

      result = create(ctx)
      send(other, :stop)

      refute_received {:s3_wrap, ^ref, :foreign}
      assert success?(shape(result)), "the create returned #{inspect(shape(result))}"
    end
  end

  # G2 and G3: the anchor read (SeedAnchor's before_action) and the
  # provenance Payload read (SeedNote's, after it).
  @sites [anchor_read: {SeedAnchor, "users"}, payload_read: {SeedNote, "payloads"}]

  describe "G2/G3: a real SQL abort at the anchor and the Payload reads" do
    for {site, {module, table}} <- @sites, owner <- @owners do
      test "#{site}: one tagged abort, the real read sees 25P02, no later business statement, no survivor (#{owner} owner)",
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

        tagged = Enum.filter(stream, &match?({_verb, _source, _code, {^site, ^ref}}, &1))

        assert length(tagged) == 1,
               "#{site}: #{length(tagged)} tagged abort statements (expected 1); " <>
                 "result #{inspect(result)}"

        assert {_head, [{_verb, nil, :division_by_zero, {^site, ^ref}} | rest]} =
                 Enum.split_while(stream, &(not match?({_v, _s, _c, {^site, ^ref}}, &1)))

        # The real read at the named site observes the aborted transaction.
        assert [{"select", ^table, :in_failed_sql_transaction, nil} | later] = rest

        # After it only the owner's rollback: no later business read or write.
        assert Enum.all?(later, &match?({"rollback", nil, _code, nil}, &1)),
               "#{site}: later statements #{inspect(later)}"

        refute success?(result), "#{site}: the create succeeded: #{inspect(result)}"
        assert survivors(ctx) == before
        assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
      end
    end
  end
end
