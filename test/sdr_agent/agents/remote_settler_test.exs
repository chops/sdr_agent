defmodule SdrAgent.Agents.RemoteSettlerTest do
  @moduledoc """
  S-B3 RED items 1-6, 8 (structural), 9-19 (entity/plan r1 670c22e4 + r2
  9f3168cc; Codex review 3537e8af, PASS with nits): the settler entry
  `SdrAgent.Agents.RemoteCalls.settle_due/1` (kernel actor plus the
  `:remote_settler` KernelMarker only), the cron worker
  `SdrAgent.Agents.RemoteSettler` and `RemoteModelCall :expire_unclaimed`.

  Contract specified here:

  - a pending call at/after its claim deadline: pending → expired_unclaimed,
    the invocation reserved → failed with error code `remote_unclaimed`,
    the charge kept, one `remote_call.expired_unclaimed` event; before the
    deadline nothing changes;
  - a claimed call at/after its result deadline: claimed → expired_unknown
    and the invocation sent → unknown; before it nothing changes;
  - a completed call with its invocation `sent` settles through the
    existing path: the stored transcript runs through the unchanged
    ClaudeCLI stream validation and init attestation, the output through
    the bound Zoi schema (recovered from the invocation's purpose and
    checked against its frozen id/version/sha256, request_sha256 equal to
    the call's): valid → completed; drift → failed (attestation reason);
    unparseable, malformed ordering, schema drift or a request mismatch →
    failed `remote_result_unprocessable`; a schema-invalid object →
    validation invalid. Never withheld, never valid by default;
  - idempotent: a second pass writes nothing; an invocation already
    terminal gets nothing applied; a missing release stays the
    StaleRunSweeper's gated recovery (no rerun, no refund);
  - only the marked kernel actor reaches the entry; rebinding mismatches
    write nothing; `:expire_unclaimed` is Forbidden outside the scope;
  - transcript bytes never reach a log line or an AuditEvent payload.

  Synthetic transcripts only; no model, no CLI, no network.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Clock
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.RemoteSettlerFixtures, as: S
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.SDR.StaleRunSweeper

  require Ash.Query

  @settler_source "lib/sdr_agent/agents/remote_settler.ex"

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  ## Helpers

  defp charged(fx) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^fx.grant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  # A reservation at a frozen instant; returns the invocation, its call id
  # and the call's claim deadline.
  defp pending!(fx) do
    Clock.freeze(F.instant())
    invocation = F.reserve!(fx)
    row = F.call_of(invocation.id)
    assert row, "prerequisite: no RemoteModelCall for the remote reservation"
    %{invocation: invocation, call_id: F.load(row["id"]), deadline: F.ts(row["claim_deadline"])}
  end

  defp result_deadline(call_id), do: F.ts(F.call_row(call_id)["result_deadline"])

  defp state(call_id), do: F.call_row(call_id)["state"]
  defp status(invocation_id), do: S.invocation_row(invocation_id)["status"]

  defp events(fx, type, id), do: F.subject_count(fx, type, id)

  # Settles a completed call carrying `transcript` (reserved with `overrides`).
  defp settled_completed!(fx, transcript, overrides \\ S.schema_bound()) do
    c = S.completed!(fx, transcript, overrides)
    S.settle!(fx)
    Map.put(c, :row, S.invocation_row(c.invocation.id))
  end

  defp assert_unprocessable!(fx, row, label) do
    assert row["status"] == "failed", "#{label}: status #{inspect(row["status"])}"
    assert row["validation_status"] != "valid", "#{label}: marked valid"

    assert S.error_code?(row, "remote_result_unprocessable"),
           "#{label}: error #{inspect(row["error"])}"

    assert events(fx, "model.invocation.completed", F.load(row["id"])) == 0
  end

  defp unchanged_entry!(fx, pending, result) do
    assert state(pending.call_id) == "pending", "the call changed: #{inspect(result)}"
    assert status(pending.invocation.id) == "reserved"
    assert events(fx, "remote_call.expired_unclaimed", pending.call_id) == 0
    assert events(fx, "model.invocation.failed", pending.invocation.id) == 0
  end

  ## Item 1: unclaimed expiry

  describe "item 1: a pending call" do
    test "at its claim deadline expires unclaimed; the invocation fails remote_unclaimed; the charge is kept",
         %{fx: fx} do
      p = pending!(fx)
      charge = charged(fx)
      Clock.freeze(p.deadline)

      S.settle!(fx)

      assert state(p.call_id) == "expired_unclaimed"
      row = S.invocation_row(p.invocation.id)
      assert row["status"] == "failed"
      assert is_nil(row["sent_at"]), "an unclaimed call was marked sent"
      assert S.error_code?(row, "remote_unclaimed"), "error: #{inspect(row["error"])}"
      assert charged(fx) == charge, "the charge changed"
      assert events(fx, "remote_call.expired_unclaimed", p.call_id) == 1
      assert events(fx, "model.invocation.failed", p.invocation.id) == 1
    end

    test "before its claim deadline is untouched", %{fx: fx} do
      p = pending!(fx)
      Clock.freeze(DateTime.add(p.deadline, -1, :second))
      before = {F.call_row(p.call_id), S.invocation_row(p.invocation.id)}

      S.settle!(fx)

      assert {F.call_row(p.call_id), S.invocation_row(p.invocation.id)} == before
      assert events(fx, "remote_call.expired_unclaimed", p.call_id) == 0
    end
  end

  ## Item 2: claimed expiry

  describe "item 2: a claimed call" do
    test "at its result deadline expires unknown; the invocation becomes unknown", %{fx: fx} do
      c = S.claimed!(fx)
      Clock.freeze(result_deadline(c.call_id))

      S.settle!(fx)

      assert state(c.call_id) == "expired_unknown"
      assert status(c.invocation.id) == "unknown"
      assert events(fx, "remote_call.expired_unknown", c.call_id) == 1
      assert events(fx, "model.invocation.unknown", c.invocation.id) == 1
      assert F.receipts(c.call_id) == [], "the settler appended a receipt"
    end

    test "one second before its result deadline is untouched", %{fx: fx} do
      c = S.claimed!(fx)
      Clock.freeze(DateTime.add(result_deadline(c.call_id), -1, :second))

      S.settle!(fx)

      assert state(c.call_id) == "claimed"
      assert status(c.invocation.id) == "sent"
    end

    test "expired unknown by a late complete (invocation still sent) has its invocation made unknown",
         %{fx: fx} do
      c = S.claimed!(fx)
      Clock.freeze(result_deadline(c.call_id))

      late =
        F.complete(c.token, c.nonce, c.call_id, c.launch.request_sha256, S.valid_transcript())

      assert F.kind(late) == :late
      assert {state(c.call_id), status(c.invocation.id)} == {"expired_unknown", "sent"}

      S.settle!(fx)

      assert status(c.invocation.id) == "unknown"
      assert events(fx, "remote_call.expired_unknown", c.call_id) == 1
    end
  end

  ## Item 3: a valid completed call

  test "item 3: a completed call with a sent invocation settles through the existing path",
       %{fx: fx} do
    c = settled_completed!(fx, S.valid_transcript())

    assert c.row["status"] == "completed"
    assert c.row["validation_status"] == "valid"
    assert c.row["parsed_output"] == S.valid_output()
    assert c.row["validation_errors"] == []
    assert state(c.call_id) == "completed"
    assert events(fx, "model.invocation.completed", c.invocation.id) == 1
    assert F.receipts(c.call_id) |> Enum.map(& &1["kind"]) == ["accepted"]
  end

  ## Item 4: init-attest drift

  for {field, value, reason} <- [
        {"model", "claude-sb3-drift-model", "model_attestation_drift"},
        {"claude_code_version", "0.0.0-sb3-drift", "version_attestation_drift"},
        {"tools", ["Bash"], "tool_attestation_drift"}
      ] do
    test "item 4: init-attest drift (#{field}) fails the invocation, attestation refused",
         %{fx: fx} do
      transcript =
        S.stream([
          S.init_event(%{unquote(field) => unquote(Macro.escape(value))}),
          S.result_event()
        ])

      c = settled_completed!(fx, transcript)

      assert c.row["status"] == "failed"
      assert c.row["validation_status"] != "valid"
      assert S.error_code?(c.row, unquote(reason)), "error: #{inspect(c.row["error"])}"
      assert is_nil(c.row["parsed_output"])
    end
  end

  ## Item 5: unparseable

  test "item 5: an unparseable transcript fails remote_result_unprocessable, never withheld",
       %{fx: fx} do
    c = settled_completed!(fx, "this is not a stream-json transcript\n")
    assert_unprocessable!(fx, c.row, "unparseable")
    assert c.row["status"] in ["failed"], "left withheld: #{inspect(c.row["status"])}"
  end

  ## Item 6: idempotency (the concurrent pair is in remote_settler_race_test.exs)

  describe "item 6: idempotency" do
    test "two settler passes give one transition and one event each", %{fx: fx} do
      c = S.claimed!(fx)
      p = pending!(fx)
      Clock.freeze(DateTime.add(result_deadline(c.call_id), 1, :second))

      S.settle!(fx)
      first = {F.call_row(p.call_id), F.call_row(c.call_id), F.event_count(fx)}
      S.settle!(fx)

      assert {F.call_row(p.call_id), F.call_row(c.call_id), F.event_count(fx)} == first
      assert events(fx, "remote_call.expired_unclaimed", p.call_id) == 1
      assert events(fx, "model.invocation.failed", p.invocation.id) == 1
      assert events(fx, "remote_call.expired_unknown", c.call_id) == 1
      assert events(fx, "model.invocation.unknown", c.invocation.id) == 1
    end

    test "the Oban worker's pass settles a due call; a repeat is a no-op", %{fx: fx} do
      p = pending!(fx)
      Clock.freeze(p.deadline)

      job = %Oban.Job{args: %{}, worker: inspect(S.settler())}
      assert F.invoke(S.settler(), :perform, [job]) == :ok
      assert state(p.call_id) == "expired_unclaimed"
      count = F.event_count(fx)

      assert F.invoke(S.settler(), :perform, [job]) == :ok
      assert F.event_count(fx) == count
    end
  end

  ## Item 8 (structural; the behavioural check is in the race test)

  test "item 8: the settler source names no MacWorker and its passes take no mac_workers lock",
       %{fx: fx} do
    path = Path.join(File.cwd!(), @settler_source)
    assert File.exists?(path), "#{@settler_source} does not exist"
    source = File.read!(path)
    refute source =~ "MacWorker", "the settler names MacWorker"
    refute source =~ "mac_workers", "the settler names mac_workers"

    # One of each case: completed (invocation sent), claimed past its result
    # deadline, pending past its claim deadline.
    _completed = S.completed!(fx, S.valid_transcript())
    d = S.claimed!(fx)
    _pending = pending!(fx)
    Clock.freeze(DateTime.add(result_deadline(d.call_id), 1, :second))

    queries = capture_queries(fn -> S.settle!(fx) end)
    assert queries != [], "no query was observed"

    locks =
      Enum.filter(queries, fn q ->
        q =~ ~s(FROM "mac_workers") and (q =~ "FOR UPDATE" or q =~ "FOR SHARE")
      end)

    assert locks == [], "the settler locked MacWorker: #{inspect(locks)}"
  end

  ## Item 9

  test "item 9: StaleRunSweeper still fails the abandoned run after remote settlement",
       %{fx: fx} do
    fx = S.swept!(fx)
    c = S.claimed!(fx)
    Clock.freeze(result_deadline(c.call_id))
    S.settle!(fx)
    assert status(c.invocation.id) == "unknown"

    started = F.ts(S.run_row(fx.run.id)["started_at"])
    Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))
    assert :ok = StaleRunSweeper.sweep(fx.tenant.id)

    run = S.run_row(fx.run.id)
    assert {run["status"], run["status_reason"]} == {"failed", "crash"}
    assert status(c.invocation.id) == "unknown", "the sweeper re-settled the invocation"
    assert S.invocations_of_run(fx.run.id) == 1, "a model call was re-sent"
  end

  ## Item 10

  test "item 10: non-settler actors are Forbidden on :expire_unclaimed outside the RemoteCalls scope",
       %{fx: fx} do
    resource = S.expire_unclaimed!()
    %{worker: worker} = S.worker!(fx)
    p = pending!(fx)
    Clock.freeze(p.deadline)
    call = Ash.get!(resource, p.call_id, authorize?: false)

    actors = [
      mac_worker: %Actor{type: :mac_worker, id: worker.id, tenant_id: fx.tenant.id},
      user: fx.admin,
      kernel_without_marker: Actor.system(:kernel, fx.tenant.id)
    ]

    for {label, actor} <- actors do
      result =
        F.safely(fn ->
          call
          |> Ash.Changeset.for_update(:expire_unclaimed, %{}, actor: actor)
          |> Ash.update()
        end)

      assert S.forbidden?(result), "#{label}: #{inspect(result)}"
    end

    assert state(p.call_id) == "pending"
    assert events(fx, "remote_call.expired_unclaimed", p.call_id) == 0
  end

  ## Item 11

  test "item 11: the settler is an Oban worker on a per-minute cron entry" do
    settler = F.loaded!(S.settler())
    behaviours = Keyword.get_values(settler.module_info(:attributes), :behaviour)
    assert Oban.Worker in List.flatten(behaviours), "RemoteSettler is not an Oban.Worker"

    {Oban.Plugins.Cron, opts} =
      :sdr_agent
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

    assert {"* * * * *", settler} in opts[:crontab],
           "crontab: #{inspect(opts[:crontab])}"
  end

  ## Item 12

  test "item 12: no transcript bytes in logs or AuditEvent payloads", %{fx: fx} do
    marker = S.marker()
    valid = S.valid_transcript()

    drift =
      S.stream([S.init_event(%{"model" => "drift"}), S.assistant_event(), S.result_event()])

    garbage = "not json " <> marker <> "\n"

    log =
      capture_log([level: :debug], fn ->
        for transcript <- [valid, drift, garbage] do
          S.completed!(fx, transcript)
          S.settle!(fx)
        end
      end)

    refute log =~ marker, "a log line carries transcript bytes"

    assert Enum.all?(F.payload_texts(fx), &(not String.contains?(&1, marker))),
           "an AuditEvent payload carries transcript bytes"
  end

  ## Item 13

  test "item 13: a valid JSON object failing the bound Zoi schema is validation invalid, never valid",
       %{fx: fx} do
    transcript = S.valid_transcript(%{"qualified" => "yes", "score" => 900})
    c = settled_completed!(fx, transcript)

    assert c.row["status"] == "failed"
    assert c.row["validation_status"] == "invalid"
    assert c.row["validation_errors"] != []
    assert c.row["error"]["kind"] == "validation_failed"
    assert events(fx, "model.invocation.completed", c.invocation.id) == 0
  end

  ## Item 14

  for {label, shape} <- [
        result_before_init: [:result, :init],
        two_results: [:init, :result, :result],
        missing_init: [:result]
      ] do
    test "item 14: malformed stream ordering (#{label}) fails closed", %{fx: fx} do
      lines =
        Enum.map(unquote(shape), fn
          :init -> S.init_event()
          :result -> S.result_event()
        end)

      c = settled_completed!(fx, S.stream(lines))

      assert c.row["status"] == "failed", "#{unquote(label)}: #{inspect(c.row["status"])}"
      assert c.row["validation_status"] != "valid"
      assert is_nil(c.row["parsed_output"]) or c.row["validation_status"] == "invalid"
      assert events(fx, "model.invocation.completed", c.invocation.id) == 0
    end
  end

  # Codex R1 (review ba7a3851): a result before the init must not be padding
  # that a later init and result make acceptable.
  test "item 14: a result before init then a valid init and result is unprocessable",
       %{fx: fx} do
    c = settled_completed!(fx, S.stream([S.result_event(), S.init_event(), S.result_event()]))

    assert_unprocessable!(fx, c.row, "result_init_result")

    assert is_nil(c.row["parsed_output"]),
           "parsed output kept: #{inspect(c.row["parsed_output"])}"
  end

  ## Item 15

  describe "item 15: schema drift fails remote_result_unprocessable" do
    test "a frozen sha256 that differs from the current ref", %{fx: fx} do
      overrides =
        S.schema_bound(:qualification, %{
          output_schema_sha256: :crypto.hash(:sha256, "sb3-drift")
        })

      c = settled_completed!(fx, S.valid_transcript(), overrides)
      assert_unprocessable!(fx, c.row, "sha256 drift")
    end

    test "a frozen schema that is not the purpose's (another purpose's ref)", %{fx: fx} do
      other = Schemas.ref(:outreach_proposal)

      overrides =
        S.schema_bound(:qualification, %{
          output_schema_id: other.id,
          output_schema_version: other.version,
          output_schema_sha256: other.sha256
        })

      c = settled_completed!(fx, S.valid_transcript(), overrides)
      assert_unprocessable!(fx, c.row, "foreign schema")
    end
  end

  ## Item 16

  test "item 16: invocation.request_sha256 different from the call's gives unprocessable",
       %{fx: fx} do
    c = S.completed!(fx, S.valid_transcript())
    other = F.other_digest(c.launch.request_sha256)
    :ok = S.plant!(F.table(F.call_resource()), c.call_id, "request_sha256", other)
    planted = F.call_row(c.call_id)["request_sha256"]
    refute planted == S.invocation_row(c.invocation.id)["request_sha256"]

    S.settle!(fx)
    assert_unprocessable!(fx, S.invocation_row(c.invocation.id), "request binding")
  end

  ## Item 17

  test "item 17: crash after complete and before release: the sweeper's gate decides, no rerun, no refund",
       %{fx: fx} do
    fx = S.swept!(fx)
    c = S.completed!(fx, S.valid_transcript())

    # The state a settler crash leaves between the invocation's completion
    # and its release: completed, no ModelResultRelease.
    {:ok, _done} =
      Agents.complete_model_invocation(
        F.invocation(c.invocation.id),
        SdrAgent.AgentsFixtures.completion(),
        actor: fx.agent
      )

    charge = charged(fx)
    before = S.invocation_row(c.invocation.id)

    S.settle!(fx)

    assert S.invocation_row(c.invocation.id) == before, "the settler re-settled"
    assert events(fx, "model.invocation.completed", c.invocation.id) == 1
    assert S.release_count(c.invocation.id) == 0, "the settler released (the sweeper owns it)"

    started = F.ts(S.run_row(fx.run.id)["started_at"])
    Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))
    sweep = StaleRunSweeper.sweep(fx.tenant.id)

    assert S.invocations_of_run(fx.run.id) == 1, "a model call was re-run"
    assert charged(fx) == charge, "the charge changed (refund)"
    assert S.invocation_row(c.invocation.id)["status"] == "completed"
    assert S.release_count(c.invocation.id) <= 1

    decided? =
      S.release_count(c.invocation.id) == 1 or S.run_row(fx.run.id)["status"] != "running"

    assert decided? or match?({:error, _}, sweep),
           "the sweeper's gate decided nothing: #{inspect(sweep)}"
  end

  ## Item 18

  for terminal <- [:unknown, :failed] do
    test "item 18: a completed call whose invocation is already #{terminal}: nothing applied",
         %{fx: fx} do
      c = S.completed!(fx, S.valid_transcript())
      sent = F.invocation(c.invocation.id)

      assert {:ok, _} = make_terminal(fx, sent, unquote(terminal))

      before = {S.invocation_row(c.invocation.id), F.event_count(fx)}
      # The settler must exist for this to say anything.
      S.settle!(fx)

      assert {S.invocation_row(c.invocation.id), F.event_count(fx)} == before
      assert S.release_count(c.invocation.id) == 0
    end
  end

  defp make_terminal(fx, sent, :unknown),
    do: Agents.mark_model_invocation_unknown(sent, actor: fx.agent)

  defp make_terminal(fx, sent, :failed) do
    Agents.fail_model_invocation(
      sent,
      %{error: %{"kind" => "provider_error", "reason" => "sb3_synthetic"}},
      actor: fx.agent
    )
  end

  ## Item 19: E1 denials and rebinding

  describe "item 19: the settler entry" do
    test "without the marker, as a user, as mac_worker or with no actor is Forbidden and writes nothing",
         %{fx: fx} do
      %{worker: worker} = S.worker!(fx)
      p = pending!(fx)
      Clock.freeze(p.deadline)
      marker = S.settler_context()
      kernel = Actor.system(:kernel, fx.tenant.id)

      for {label, opts} <- [
            kernel_no_context: [actor: kernel],
            kernel_without_settler_marker: [actor: kernel, context: KernelContext.context()],
            user: [actor: fx.admin, context: marker],
            mac_worker: [
              actor: %Actor{type: :mac_worker, id: worker.id, tenant_id: fx.tenant.id},
              context: marker
            ],
            no_actor: [context: marker]
          ] do
        result = S.settle_due(opts)
        assert S.forbidden?(result), "#{label}: #{inspect(result)}"
        unchanged_entry!(fx, p, result)
      end
    end

    test "under the local transport (trusted config re-read) writes nothing", %{fx: fx} do
      p = pending!(fx)
      Clock.freeze(p.deadline)
      F.remote!(:local)

      result = S.settle_due(S.settler_opts(fx))
      unchanged_entry!(fx, p, result)
    end

    test "a planted foreign-tenant call is skipped with no write", %{fx: fx} do
      p = pending!(fx)
      foreign = Ecto.UUID.generate()

      assert :ok ==
               F.copy_insert(
                 F.call_resource(),
                 "id = $1",
                 [F.dump(p.call_id)],
                 [
                   {"id", F.dump(foreign)},
                   {"tenant_id", F.dump(Ecto.UUID.generate())},
                   {"model_invocation_id", F.dump(Ecto.UUID.generate())}
                 ],
                 replica: true
               )

      Clock.freeze(p.deadline)
      S.settle!(fx)

      assert state(foreign) == "pending", "the foreign call was written"

      for type <- ~w(remote_call.expired_unclaimed remote_call.expired_unknown) do
        assert S.any_tenant_subject_count(type, foreign) == 0, "#{type} for the foreign call"
      end

      assert state(p.call_id) == "expired_unclaimed"
    end
  end

  ## Query capture (as run_recovery_test.exs)

  defp capture_queries(fun) do
    parent = self()
    handler = "sb3-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:query, IO.iodata_to_binary(metadata.query)})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_queries([])
  end

  defp collect_queries(acc) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
