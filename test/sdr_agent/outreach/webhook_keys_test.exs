defmodule SdrAgent.Outreach.WebhookKeysTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 K (T-K1, T-K2, T-K3, T-K6): the webhook
  order of section 6.2 under the identity keys of section 2.6. A reply
  passes `{reply-message: Message-ID, email: from}` before the stored-reply
  check (which replaces `serialize_message`), matches unlocked, takes
  `Locks.targets` and revalidates the match under the locks
  (`:reply_match_changed`, nothing written); an unsubscribe link reads the
  contact, passes `{email}` and re-reads it (`:conflict`, nothing written);
  no `hashtextextended` or raw `pg_advisory` remains outside `IdentityKeys`.
  T-K4 and T-K5 are RED-3 [P] races (`webhook_keys_race_test.exs`).

  The pass is observed without a seam: the test opens the application
  scope (`Audit.transaction`) around `Webhooks.process/4`, whose own
  `Audit.transaction` joins it, and reads the section 2.4 state query
  (`sdr.identity_pass`) inside that scope after the call returns. A matched
  delivery needs the seeded demo data and a drafting run, so the suite uses
  `SdrAgent.SDRCase`, as the existing webhook suites do (`AuditCase` cannot
  build one).

  RED form: T-K1, T-K2 (unmatched and matched), T-K3 (pass) and T-K6 are
  behavioural (the webhook order exists on main and publishes no pass; the
  pass record assertion fails before any new function is called; T-K6
  finds `webhooks.ex`). The changed-match and the changed-email cases need
  an interleaving between two steps of one processing transaction, which a
  single sandbox connection cannot produce without a race; they use the
  narrowest test-build seam and are structural (its presence guard fails).
  Every new function is guarded (`Code.ensure_loaded?/1`,
  `function_exported?/3`) and called through `apply/3`.

  Interface names chosen here for review:
    * `SdrAgent.Outreach.Webhooks.TestHooks.with_hook(point, hook, fun)`, a
      compile-time test-build seam (as `IdentityKeys.TestFaults`): runs
      `fun`, and calls the arity-0 `hook` once, in the processing process
      and inside its transaction, at `point`:
        * `:after_reply_match`: after `match/3` (section 6.2 reply step 5),
          before `Locks.targets` (step 6);
        * `:before_unsubscribe_pass`: after the contact read and token
          check (unsubscribe steps 2-3), before the pass (step 4);
    * the key kind `:"reply-message"` with the raw Message-ID, and
      `:email` with the raw `from` (RED-1 `IdentityKeys.id/3`);
    * `:conflict` returned by `Webhooks.process/4` as `{:error, :conflict}`
      (transient, not final).
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures

  @keys SdrAgent.Audit.IdentityKeys
  @hooks SdrAgent.Outreach.Webhooks.TestHooks
  @scope_key {SdrAgent.Audit.IdentityKeys, :scope}

  # Section 2.3: "v1;<token>;<backend pid>;<id>,<id>,…".
  @record_format ~r/^v1;[0-9a-f]{32};\d+;(-?\d+(,-?\d+)*)?$/

  # Section 2.4, verbatim: the one state query, no lock clause.
  @state_sql """
  SELECT current_setting('sdr.identity_pass', true),
         pg_backend_pid(),
         coalesce(array_agg((l.classid::bigint << 32) | l.objid::bigint)
                  FILTER (WHERE l.pid IS NOT NULL), '{}')
  FROM (SELECT 1) AS one
  LEFT JOIN pg_locks l
    ON  l.locktype = 'advisory'
    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND l.pid      = pg_backend_pid()
    AND l.objsubid = 1
    AND l.mode     = 'ExclusiveLock'
    AND l.granted
  """

  describe "T-K1 reply pass and duplicate under the reply-message key" do
    # Behavioural RED: main serializes on hashtextextended and publishes no pass.
    test "T-K1 a matched reply passes {reply-message, email from} in the processing scope", ctx do
      op = delivered!(ctx)
      reply = reply_event!(op, "Thanks, this sounds interesting.")

      {result, observed} = in_scope(fn -> process(ctx, reply) end)

      assert result == :ok
      pass = assert_pass!(observed)
      assert pass.ids == expected_ids(ctx, reply.message_id, reply.from)
      assert [%{match_status: :matched, webhook_event_id: id}] = replies!(ctx)
      assert id == reply.event.id
    end

    test "T-K1 a duplicate (same Message-ID, another event) passes the same keys and stops at the stored-reply check",
         ctx do
      op = delivered!(ctx)
      first = reply_event!(op, "Interested.")
      assert :ok = process(ctx, first)
      received = length(events_of_type(ctx.tenant, "outreach.reply.received"))

      duplicate = reply_event!(op, "Interested.", message_id: first.message_id)
      {result, observed} = in_scope(fn -> process(ctx, duplicate) end)

      assert result == :ok
      pass = assert_pass!(observed)
      assert pass.ids == expected_ids(ctx, first.message_id, first.from)
      assert [%{webhook_event_id: owner}] = replies!(ctx)
      assert owner == first.event.id
      assert webhook!(ctx, duplicate.event).processing_status == :processed
      assert length(events_of_type(ctx.tenant, "outreach.reply.received")) == received
    end
  end

  describe "T-K2 unmatched, matched and changed match" do
    # Behavioural RED: no pass is published on main.
    test "T-K2 an unmatched reply passes {reply-message, email from} and is stored unmatched",
         ctx do
      op = delivered!(ctx)
      stranger = "c302-stranger-#{SalesFixtures.unique()}@unknown.example.test"

      reply =
        reply_event!(op, "Who is this?",
          from: stranger,
          in_reply_to: "<nothing@elsewhere.example.test>"
        )

      {result, observed} = in_scope(fn -> process(ctx, reply) end)

      assert result == :ok
      pass = assert_pass!(observed)
      assert pass.ids == expected_ids(ctx, reply.message_id, stranger)
      assert [%{match_status: :unmatched, lead_id: nil}] = replies!(ctx)
      assert events_of_type(ctx.tenant, "sdr.reply.received") == []
    end

    # Behavioural RED: no pass is published on main.
    test "T-K2 a matched reply (latest delivery) revalidates under the locks with no late key",
         ctx do
      op = delivered!(ctx)
      reply = reply_event!(op, "Replying from my phone.", in_reply_to: nil)

      {result, observed} = in_scope(fn -> process(ctx, reply) end)

      assert result == :ok, "C3-02: the locked revalidation must not request a key late"
      pass = assert_pass!(observed)
      assert pass.ids == expected_ids(ctx, reply.message_id, reply.from)
      assert [stored] = replies!(ctx)
      assert {stored.match_status, stored.delivery_operation_id} == {:matched, op.id}
      assert to_string(stored.from_email) == reply.from
    end

    # Structural RED (test-build seam): the match must change between the
    # unlocked match/3 and Locks.targets, inside one processing transaction.
    test "T-K2 a match changed before the locks: :reply_match_changed, nothing written; final attempt fails as crash",
         ctx do
      present!(@hooks, :with_hook, 3)
      op = delivered!(ctx)
      reply = reply_event!(op, "Please remove me from your list.", in_reply_to: nil)
      before = length(events(ctx.tenant))

      result =
        with_hook(:after_reply_match, fn -> bounce!(ctx, op) end, fn -> process(ctx, reply) end)

      assert_received :c302_hook_ran,
                      "C3-02: not established: the :after_reply_match hook never ran"

      assert result == {:error, :reply_match_changed}
      assert_nothing_written!(ctx, reply, op, before)
      assert webhook!(ctx, reply.event).processing_status == :received

      final =
        with_hook(:after_reply_match, fn -> bounce!(ctx, op) end, fn ->
          Webhooks.process(reply.event.id, ctx.tenant.id, reply.body, final?: true)
        end)

      assert_received :c302_hook_ran
      assert final == :ok
      event = webhook!(ctx, reply.event)
      assert event.processing_status == :failed
      {:ok, failure} = Operations.get_failure(event.failure_id, actor: ctx.admin)
      assert failure.class == :crash
      assert replies!(ctx) == []
      assert outreach!(ctx, op).state == :accepted
    end
  end

  describe "T-K3 unsubscribe :conflict" do
    # Behavioural RED: main locks the suppression targets with no pass.
    test "T-K3 an unsubscribe link passes {email} of the contact it read", ctx do
      contact = contact!(ctx, fixture_lead!(ctx, "02"))
      body = unsubscribe_body(contact)
      assert {:ok, %{status: :accepted, event: event}} = ingest!("unsubscribe", body)

      {result, observed} =
        in_scope(fn -> Webhooks.process(event.id, ctx.tenant.id, body) end)

      assert result == :ok
      pass = assert_pass!(observed)
      present!(@keys, :id, 3)
      assert pass.ids == MapSet.new([key_id(ctx.tenant.id, :email, to_string(contact.email))])
      assert [%{reason: :unsubscribe_link}] = unsubscribe_suppressions(ctx, :unsubscribe_link)
    end

    # Structural RED (test-build seam): the email must change between the
    # contact read and the key, inside one processing transaction.
    test "T-K3 the contact's email changed between the read and the key: :conflict, nothing written",
         ctx do
      present!(@hooks, :with_hook, 3)
      contact = contact!(ctx, fixture_lead!(ctx, "02"))
      old = to_string(contact.email)
      new = "c302-moved-#{SalesFixtures.unique()}@example.test"
      body = unsubscribe_body(contact)
      assert {:ok, %{status: :accepted, event: event}} = ingest!("unsubscribe", body)
      before = length(events(ctx.tenant))

      hook = fn -> change_email!(ctx, contact, new) end

      result =
        with_hook(:before_unsubscribe_pass, hook, fn ->
          Webhooks.process(event.id, ctx.tenant.id, body)
        end)

      assert_received :c302_hook_ran,
                      "C3-02: not established: the :before_unsubscribe_pass hook never ran"

      assert result == {:error, :conflict}
      assert to_string(reload!(ctx, contact).email) == old
      assert unsubscribe_suppressions(ctx, :unsubscribe_link) == []
      assert {:ok, []} = Outreach.matching_suppressions(new, actor: ctx.admin)
      assert length(events(ctx.tenant)) == before
      assert webhook!(ctx, event).processing_status == :received
    end
  end

  describe "T-K6 no hashtextextended or raw pg_advisory outside IdentityKeys" do
    # Behavioural RED: lib/sdr_agent/outreach/webhooks.ex serialize_message
    # (pg_advisory_xact_lock(hashtextextended(...))) is deleted by G6.
    test "T-K6 only IdentityKeys takes advisory locks or hashes text into lock keys" do
      root = Path.expand("../../..", __DIR__)
      files = Path.wildcard(Path.join(root, "lib/**/*.{ex,exs}"))
      assert files != []

      offenders =
        for path <- files,
            rel = Path.relative_to(path, root),
            not identity_keys?(rel),
            File.read!(path) =~ ~r/hashtextextended|hashtext\s*\(|pg_(try_)?advisory/,
            do: rel

      assert offenders == [],
             "C3-02: advisory locks outside IdentityKeys: #{Enum.join(offenders, ", ")}"
    end
  end

  ## Fixtures

  defp delivered!(ctx) do
    approved = approved!(ctx)
    assert %{success: 1} = deliver!()
    outreach!(ctx, approved.delivery)
  end

  # A signed reply event for `delivery`, ingested; options as `reply_body/3`
  # plus `:message_id`.
  defp reply_event!(delivery, text, opts \\ []) do
    id = "evt_c302_" <> Ecto.UUID.generate()
    data_opts = Keyword.take(opts, [:from, :in_reply_to]) ++ [id: id]
    decoded = delivery |> reply_body(text, data_opts) |> Jason.decode!()

    decoded =
      case Keyword.fetch(opts, :message_id) do
        {:ok, message_id} -> put_in(decoded, ["data", "message_id"], message_id)
        :error -> decoded
      end

    body = Jason.encode!(decoded)
    assert {:ok, %{status: :accepted, event: event}} = ingest!("reply", body)

    %{
      event: event,
      body: body,
      message_id: decoded["data"]["message_id"],
      from: decoded["data"]["from"]
    }
  end

  defp process(ctx, reply), do: Webhooks.process(reply.event.id, ctx.tenant.id, reply.body)

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  defp unsubscribe_suppressions(ctx, reason),
    do: Enum.filter(suppressions!(ctx), &(&1.reason == reason))

  # The hook of the changed-match case: the delivery bounces (accepted →
  # bounced), so the latest delivery to the sender no longer matches.
  defp bounce!(ctx, delivery) do
    whk = Actor.system(:webhook_ingestor, ctx.tenant.id)

    assert {:ok, %{state: :bounced}} =
             delivery
             |> Ash.Changeset.for_update(:mark_bounced, %{last_error: %{"reason" => "c302 hook"}},
               actor: whk
             )
             |> Ash.update()

    send(self(), :c302_hook_ran)
    :ok
  end

  defp change_email!(ctx, contact, email) do
    assert {:ok, _} = Sales.update(contact, :change_email, %{email: email}, actor: ctx.admin)
    send(self(), :c302_hook_ran)
    :ok
  end

  defp assert_nothing_written!(ctx, reply, delivery, events_before) do
    assert replies!(ctx) == []
    assert unsubscribe_suppressions(ctx, :unsubscribe_reply) == []
    assert outreach!(ctx, delivery).state == :accepted
    assert length(events(ctx.tenant)) == events_before
    assert events_of_type(ctx.tenant, "outreach.reply.received") == []
    refute webhook!(ctx, reply.event).processing_status == :processed
  end

  defp identity_keys?(rel),
    do:
      rel == "lib/sdr_agent/audit/identity_keys.ex" or
        String.starts_with?(rel, "lib/sdr_agent/audit/identity_keys/")

  ## The pass, observed inside the caller-opened application scope

  # Runs `fun` inside an `Audit.transaction` (the application scope; the
  # processing transaction joins it) and reads the pass record and the
  # scope entry before the scope ends.
  defp in_scope(fun) do
    assert {:ok, {result, observed}} =
             Audit.transaction(fn ->
               result = fun.()
               {result, %{record: record(), held: held(), scope: Process.get(@scope_key)}}
             end)

    {result, observed}
  end

  defp assert_pass!(%{record: record, held: held, scope: scope}) do
    assert record != nil,
           "C3-02: the event published no identity pass (sdr.identity_pass, section 6.2)"

    assert match?(%{token: _}, scope), "C3-02: no application scope was registered"
    assert record.token == scope.token, "C3-02: the pass belongs to another scope"
    assert MapSet.subset?(record.ids, held), "C3-02: a manifest id is not held"
    record
  end

  defp expected_ids(ctx, message_id, from) do
    present!(@keys, :id, 3)

    MapSet.new([
      key_id(ctx.tenant.id, :"reply-message", message_id),
      key_id(ctx.tenant.id, :email, from)
    ])
  end

  defp state do
    %{rows: [[setting, pid, ids]]} = Repo.query!(@state_sql)
    %{setting: setting, pid: pid, held: MapSet.new(ids)}
  end

  defp held, do: state().held

  defp record do
    case state().setting do
      value when value in [nil, ""] ->
        nil

      value ->
        assert value =~ @record_format, "C3-02: sdr.identity_pass is not a v1 record"
        [_version, token, pid, ids] = String.split(value, ";")
        %{token: token, pid: String.to_integer(pid), ids: parse_ids(ids)}
    end
  end

  defp parse_ids(""), do: MapSet.new()
  defp parse_ids(ids), do: ids |> String.split(",") |> MapSet.new(&String.to_integer/1)

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp key_id(tenant, kind, raw), do: call(@keys, :id, [tenant, kind, raw])
  defp with_hook(point, hook, fun), do: call(@hooks, :with_hook, [point, hook, fun])
end
