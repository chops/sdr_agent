defmodule SdrAgent.Repo.ErrorPathPrivacyTest do
  @moduledoc """
  C4-01a error-path addendum (ADR-0005 C4 amendment, "metadata-only
  database logging and spans", accepted 2026-10-14; Codex 38fd09d MF3):
  the binding error-boundary controls and the amendment's test list
  (`docs/adr/0005-observability-wire-witness-anchoring.md` lines 224-251).

    * ADR 238-241 — a synthetic query event whose `%Postgrex.Error{}`
      message, DETAIL and HINT hold a canary;
    * ADR 242-244 — the same event from a Repo whose configured URL holds a
      credential canary: no canary and no `db.url`;
    * ADR 245 — an unknown error struct is reported as `"other"`;
    * ADR 246-249 — against the test database: a valid insert, a check and a
      unique violation with a canary value, a raised error that crashes a
      process, and an Oban job that hits a constraint error: the canary is
      absent from logs, spans and `oban_jobs.errors`;
    * ADR 227-231 — the primary `:logger` filter
      `SdrAgent.Logger.ExceptionFilter` rewrites any log event whose
      message, report or metadata holds a Postgrex, DBConnection or Ash
      error struct into the sanitized summary;
    * ADR 231-233 — Oban workers rescue database exceptions at their
      boundary (`SdrAgent.Workers.ErrorBoundary.run/1`) and return
      sanitized reasons; raised *and returned* raw Postgrex, DBConnection
      and Ash errors (nested too) become a summary inside the same
      disposition, and safe results (`:ok`, `{:ok, _}`, `{:snooze, _}`,
      `{:error, atom}`, `{:cancel, atom}`) pass unchanged. Every production
      worker's real `perform/1` is exercised through a test-build fault
      point (`config :sdr_agent, :worker_boundary_faults, %{worker =>
      fun}`, read by the boundary wrapper, compiled into test-seam builds
      only), so a worker carrying only the marker, without the wrapper,
      fails; the marker (`__sdr_error_boundary__/0`) is inventory only;
    * ADR 250-251 — the default Ecto logger and `OpentelemetryEcto` are not
      attached; `QueryLog` and `RepoSpans` are.

  Interface choices made here, for review: the filter id
  `:sdr_agent_exception_filter` holding a function of
  `SdrAgent.Logger.ExceptionFilter`; `SdrAgent.Workers.ErrorBoundary.run/1`
  (`fun` result passed through, a database exception becomes `{:error,
  summary}` naming only the error module, SQLSTATE condition and declared
  constraint); the worker marker `__sdr_error_boundary__/0`; the
  test-build fault point `:worker_boundary_faults`.

  RED: the filter, the boundary and the worker markers do not exist yet;
  each such test fails on an explicit `C4-01a:` assertion (presence guards
  or the canary checks). The synthetic-event, credential-URL, unknown-error,
  SQL and attachment tests cover controls already built by C4-01a GREEN
  (`SafeMetadata`, `QueryLog`, `RepoSpans`) and are expected to pass.
  Synthetic canaries only; every wait is bounded.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  require Logger
  require Record

  alias Ecto.Adapters.SQL
  alias SdrAgent.Repo
  alias SdrAgent.Repo.SafeMetadata
  alias SdrAgent.Telemetry.InMemoryExporter

  @moduletag :c4_01a

  @event [:sdr_agent, :repo, :query]
  @filter SdrAgent.Logger.ExceptionFilter
  @boundary SdrAgent.Workers.ErrorBoundary

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  defmodule CredentialRepo do
    @moduledoc "A synthetic repo whose configuration holds a credential-bearing URL (ADR 242-244)."
    def config,
      do: [
        url: "postgres://user:" <> canary() <> "@db.invalid/x?sslpassword=" <> canary(),
        hostname: "db.invalid",
        username: "user",
        password: canary(),
        database: "c4_synthetic_db"
      ]

    def __adapter__, do: Ecto.Adapters.Postgres
    defp canary, do: "c4urlcanary" <> "QX9"
  end

  defmodule UnknownError do
    @moduledoc "An error struct outside the allowlist (ADR 245)."
    defexception [:message, :secret]
  end

  defmodule BoundaryWorker do
    @moduledoc """
    Test worker: runs one fault mode (`SdrAgent.Repo.ErrorPathPrivacyTest.fault/2`)
    inside the boundary, looked up at run time so this module compiles
    before the boundary exists. `max_attempts` 2, so an error is retryable.
    """
    use Oban.Worker, queue: :default, max_attempts: 2

    @impl true
    def perform(%Oban.Job{args: %{"mode" => mode, "canary" => canary}}) do
      apply(SdrAgent.Workers.ErrorBoundary, :run, [
        fn -> SdrAgent.Repo.ErrorPathPrivacyTest.fault(mode, canary) end
      ])
    end
  end

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    InMemoryExporter.reset()

    on_exit(fn ->
      Logger.configure(level: level)
      InMemoryExporter.reset()
    end)

    :ok
  end

  # Raw error-bearing faults (raised or returned) and safe results, by mode.
  @raw_modes ~w(raise_db return_pg return_nested raise_dbconn raise_ash return_ash cancel_pg)
  @safe_results [
    {"ok", :ok},
    {"ok_value", {:ok, %{done: 1}}},
    {"snooze", {:snooze, 4321}},
    {"error_safe", {:error, :c4_safe_reason}},
    {"cancel_safe", {:cancel, :c4_safe_reason}}
  ]

  @doc false
  def fault("raise_db", text),
    do: Repo.transaction(fn -> SQL.query!(Repo, "SELECT $1::text::integer", [text]) end)

  def fault("return_pg", text), do: {:error, pg_error(text)}

  def fault("return_nested", text),
    do:
      {:error,
       {:wrapped,
        %{cause: DBConnection.ConnectionError.exception(message: "connection " <> text)}}}

  def fault("raise_dbconn", text),
    do: raise(DBConnection.ConnectionError, message: "connection " <> text)

  def fault("raise_ash", text), do: raise(ash_error(text))
  def fault("return_ash", text), do: {:error, ash_error(text)}
  def fault("cancel_pg", text), do: {:cancel, pg_error(text)}

  def fault(mode, _text) do
    {^mode, result} = List.keyfind(@safe_results, mode, 0)
    result
  end

  # The module a raw mode's sanitized summary must name.
  defp summary_module("raise_db"), do: "Postgrex.Error"
  defp summary_module("return_pg"), do: "Postgrex.Error"
  defp summary_module("cancel_pg"), do: "Postgrex.Error"
  defp summary_module("return_nested"), do: "DBConnection.ConnectionError"
  defp summary_module("raise_dbconn"), do: "DBConnection.ConnectionError"
  defp summary_module(ash) when ash in ["raise_ash", "return_ash"], do: "Ash.Error.Invalid"

  defp disposition?({tag, _reason}, tag), do: true
  defp disposition?(_result, _tag), do: false

  defp disposition("cancel_pg"), do: :cancel
  defp disposition(_raw), do: :error

  defp ash_error(text),
    do:
      Ash.Error.Invalid.exception(
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(field: :note, message: "bad", value: text)
        ]
      )

  defp render(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  # Runs `fun` in a bounded task (sandbox allowed through `$callers`).
  defp bounded(fun, ms \\ 15_000) do
    task = Task.async(fn -> observe(fun) end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      other -> {:timeout, other}
    end
  end

  defp put_faults!(faults) do
    previous = Application.fetch_env(:sdr_agent, :worker_boundary_faults)
    Application.put_env(:sdr_agent, :worker_boundary_faults, faults)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :worker_boundary_faults, value)
        :error -> Application.delete_env(:sdr_agent, :worker_boundary_faults)
      end
    end)
  end

  defp app_workers do
    {:ok, modules} = :application.get_key(:sdr_agent, :modules)
    workers = Enum.filter(modules, &app_worker?/1)
    assert length(workers) >= 12, "the worker inventory found #{length(workers)} workers"
    workers
  end

  defp probe_job(worker, n) do
    opts = worker.__opts__()

    %Oban.Job{
      id: nil,
      worker: inspect(worker),
      queue: to_string(Keyword.get(opts, :queue, :default)),
      args: %{"c4_boundary_probe" => n},
      attempt: 1,
      max_attempts: Keyword.get(opts, :max_attempts, 20)
    }
  end

  defp job_rows(ids) do
    SQL.query!(
      Repo,
      "SELECT id, state, errors::text FROM oban_jobs WHERE id = ANY($1)",
      [ids]
    ).rows
    |> Map.new(fn [id, state, errors] -> {id, {state, errors}} end)
  end

  defp canary, do: "c4errcanary" <> "ZQ7"
  defp url_canary, do: "c4urlcanary" <> "QX9"

  defp rendered_spans do
    Process.sleep(50)
    inspect(InMemoryExporter.spans(), limit: :infinity, printable_limit: :infinity)
  end

  defp span_parts do
    Process.sleep(50)
    render = &inspect(&1, limit: :infinity, printable_limit: :infinity)

    for record <- InMemoryExporter.spans() do
      %{
        name: span(record, :name),
        attributes: render.(span(record, :attributes)),
        events: render.(span(record, :events)),
        status: render.(span(record, :status))
      }
    end
  end

  defp assert_no_canary(log, text, label) do
    refute log =~ text, "C4-01a: #{label}: the canary reached a log"

    for part <- span_parts(), field <- [:attributes, :events, :status] do
      refute Map.fetch!(part, field) =~ text,
             "C4-01a: #{label}: the canary reached span #{inspect(part.name)} #{field}"
    end
  end

  # A raise or exit becomes `{:raised, exception}` / `{kind, reason}`, so a
  # missing boundary fails as an assertion, not a crash.
  defp observe(fun) do
    fun.()
  rescue
    exception in ExUnit.AssertionError -> reraise exception, __STACKTRACE__
    exception -> {:raised, exception}
  catch
    kind, reason -> {kind, reason}
  end

  defp require_module!(module) do
    assert Code.ensure_loaded?(module), "C4-01a: #{inspect(module)} missing"
    module
  end

  defp pg_error(text) do
    %Postgrex.Error{
      message: "message " <> text,
      postgres: %{
        code: :check_violation,
        pg_code: "23514",
        severity: "ERROR",
        message: "new row violates check constraint",
        detail: "Failing row contains (" <> text <> ")",
        hint: "hint " <> text,
        constraint: "settings_revisions_content_matches_kind",
        table: "settings_revisions"
      }
    }
  end

  defp measurements,
    do: %{
      total_time: System.convert_time_unit(900, :microsecond, :native),
      query_time: System.convert_time_unit(800, :microsecond, :native),
      queue_time: System.convert_time_unit(100, :microsecond, :native)
    }

  defp event_metadata(repo, result, text) do
    %{
      repo: repo,
      source: "settings_revisions",
      type: :ecto_sql_query,
      query: "INSERT INTO settings_revisions (note) VALUES ('" <> text <> "')",
      params: [text],
      cast_params: [text],
      options: [],
      result: result
    }
  end

  # A check-constrained and a unique temporary table (rolled back with the
  # sandbox): a violation's DETAIL then holds the inserted canary.
  defp temp_tables! do
    SQL.query!(
      Repo,
      "CREATE TEMP TABLE c4_error_path (v text CONSTRAINT c4_error_path_short " <>
        "CHECK (length(v) < 8))",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TEMP TABLE c4_error_unique (v text CONSTRAINT c4_error_unique_v UNIQUE)",
      []
    )
  end

  defp failing(sql, params) do
    Repo.transaction(fn ->
      case SQL.query(Repo, sql, params) do
        {:error, error} -> Repo.rollback(error)
        other -> other
      end
    end)
  end

  ## ADR 238-241: synthetic query event

  describe "ADR 238-241: a synthetic query event with a canary-bearing Postgrex error" do
    test "the canary is absent from every span part and from debug logs" do
      text = canary()

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            @event,
            measurements(),
            event_metadata(Repo, {:error, pg_error(text)}, text)
          )
        end)

      assert_no_canary(log, text, "synthetic Postgrex event")

      assert rendered_spans() =~
               "Postgrex.Error check_violation settings_revisions_content_matches_kind",
             "the span status keeps the allowlisted identifiers"

      assert log =~ "outcome=error"
    end

    test "an unknown SQLSTATE condition atom is reported as other" do
      error = %Postgrex.Error{postgres: %{code: :c4_unknown_condition_canary, pg_code: "23514"}}
      fields = SafeMetadata.fields(measurements(), %{repo: Repo, result: {:error, error}})
      assert fields.pg_code == "other"
    end
  end

  ## ADR 242-244: credential-bearing Repo URL

  describe "ADR 242-244: a Repo configured with a credential-bearing URL" do
    test "no credential canary and no db.url in any span or log" do
      text = url_canary()

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            @event,
            measurements(),
            event_metadata(CredentialRepo, {:error, pg_error(canary())}, canary())
          )

          :telemetry.execute(
            @event,
            measurements(),
            event_metadata(CredentialRepo, {:ok, %{num_rows: 1, command: :insert}}, canary())
          )
        end)

      assert_no_canary(log, text, "credential URL")
      assert_no_canary(log, canary(), "credential URL event values")
      refute rendered_spans() =~ "db.url", "a span carries db.url"
      refute log =~ "db.invalid", "the Repo host reached a log"
      refute rendered_spans() =~ "db.invalid", "the Repo host reached a span"
    end
  end

  ## ADR 245: unknown error struct

  describe "ADR 245: an unknown error struct" do
    test "is reported as other and never inspected" do
      text = canary()
      error = %UnknownError{message: text, secret: text}

      fields = SafeMetadata.fields(measurements(), %{repo: Repo, result: {:error, error}})

      assert {fields.error_module, fields.pg_code, fields.constraint} ==
               {"other", "other", "other"}

      refute inspect(fields, limit: :infinity) =~ text

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(@event, measurements(), event_metadata(Repo, {:error, error}, text))

          :telemetry.execute(
            @event,
            measurements(),
            event_metadata(Repo, {:error, {:raw, text}}, text)
          )
        end)

      assert_no_canary(log, text, "unknown error")
    end
  end

  ## ADR 246-249: against the test database

  describe "ADR 246-248: queries against the test database" do
    test "a valid insert, a check violation and a unique violation carry no canary" do
      text = canary()
      temp_tables!()

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = SQL.query(Repo, "INSERT INTO c4_error_path (v) VALUES ($1)", ["ok"])
          assert {:ok, _} = SQL.query(Repo, "INSERT INTO c4_error_unique (v) VALUES ($1)", [text])

          check = failing("INSERT INTO c4_error_path (v) VALUES ($1)", [text])

          assert match?({:error, %Postgrex.Error{postgres: %{code: :check_violation}}}, check),
                 "C4-01a setup: the check insert did not fail"

          unique = failing("INSERT INTO c4_error_unique (v) VALUES ($1)", [text])

          assert match?({:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}, unique),
                 "C4-01a setup: the unique insert did not fail"
        end)

      assert_no_canary(log, text, "SQL valid / check / unique")
    end

    test "a raised database error that crashes a process leaves no canary in the crash report" do
      text = canary()

      log =
        capture_log([level: :debug], fn ->
          {:ok, pid} =
            Task.start(fn ->
              Repo.transaction(fn -> SQL.query!(Repo, "SELECT $1::text::integer", [text]) end)
            end)

          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
          Process.sleep(100)
        end)

      assert log =~ "Postgrex.Error",
             "C4-01a: the crash report was dropped instead of summarized: #{String.slice(log, 0, 300)}"

      assert_no_canary(log, text, "process crash")
    end
  end

  describe "ADR 231-233, 248-249: Oban worker boundaries" do
    test "run/1 passes safe results through unchanged" do
      require_module!(@boundary)
      assert function_exported?(@boundary, :run, 1), "C4-01a: ErrorBoundary.run/1 missing"

      for {mode, expected} <- @safe_results do
        result = observe(fn -> apply(@boundary, :run, [fn -> fault(mode, canary()) end]) end)

        assert result == expected,
               "C4-01a: the safe result #{mode} was changed: #{inspect(result)}"
      end
    end

    test "run/1 summarizes raised and returned raw errors, keeping the disposition" do
      require_module!(@boundary)
      text = canary()

      for mode <- @raw_modes do
        result = observe(fn -> apply(@boundary, :run, [fn -> fault(mode, text) end]) end)

        refute match?({:raised, _}, result), "C4-01a: #{mode}: the boundary let the error raise"

        assert disposition?(result, disposition(mode)),
               "C4-01a: #{mode}: disposition #{disposition(mode)} not kept"

        refute render(result) =~ text, "C4-01a: #{mode}: the raw error passed through"
        assert render(result) =~ summary_module(mode), "C4-01a: #{mode}: no sanitized summary"
      end
    end

    test "persisted oban_jobs rows: raw errors are summaries; dispositions are kept" do
      require_module!(@boundary)
      text = canary()
      modes = @raw_modes ++ Enum.map(@safe_results, &elem(&1, 0))

      log =
        capture_log([level: :debug], fn ->
          ids =
            for mode <- modes, into: %{} do
              {:ok, job} =
                %{"mode" => mode, "canary" => text} |> BoundaryWorker.new() |> Oban.insert()

              {mode, job.id}
            end

          Process.put(:c4_job_ids, ids)
          Oban.drain_queue(queue: :default, with_safety: true)
        end)

      ids = Process.get(:c4_job_ids)
      rows = job_rows(Map.values(ids))

      for mode <- @raw_modes do
        {state, errors} = Map.fetch!(rows, Map.fetch!(ids, mode))
        refute errors =~ text, "C4-01a: #{mode}: the canary reached oban_jobs.errors"

        assert errors =~ summary_module(mode),
               "C4-01a: #{mode}: oban_jobs.errors holds no sanitized summary: #{errors}"

        expected = if mode == "cancel_pg", do: "cancelled", else: "retryable"
        assert state == expected, "C4-01a: #{mode}: state #{state}, expected #{expected}"
      end

      expected_states = %{
        "ok" => "completed",
        "ok_value" => "completed",
        "snooze" => "scheduled",
        "error_safe" => "retryable",
        "cancel_safe" => "cancelled"
      }

      for {mode, expected} <- expected_states do
        {state, _errors} = Map.fetch!(rows, Map.fetch!(ids, mode))
        assert state == expected, "C4-01a: safe #{mode}: state #{state}, expected #{expected}"
      end

      assert_no_canary(log, text, "Oban jobs")
    end

    test "every production worker's real perform path runs inside the boundary" do
      require_module!(@boundary)
      text = canary()

      for {worker, n} <- Enum.with_index(app_workers()), mode <- @raw_modes do
        put_faults!(%{worker => fn _job -> fault(mode, text) end})
        result = bounded(fn -> worker.perform(probe_job(worker, n)) end)

        assert disposition?(result, disposition(mode)) and
                 render(result) =~ summary_module(mode),
               "C4-01a: #{inspect(worker)} #{mode}: perform did not go through the boundary"

        refute render(result) =~ text, "C4-01a: #{inspect(worker)} #{mode}: raw error passed"
      end

      for {worker, n} <- Enum.with_index(app_workers()) do
        put_faults!(%{worker => fn _job -> {:snooze, 4321} end})

        assert bounded(fn -> worker.perform(probe_job(worker, n)) end) == {:snooze, 4321},
               "C4-01a: #{inspect(worker)}: a safe result did not pass through its boundary"
      end
    end

    test "every production worker's persisted job errors are summaries" do
      require_module!(@boundary)
      text = canary()
      workers = app_workers()
      put_faults!(Map.new(workers, &{&1, fn _job -> fault("return_pg", text) end}))

      log =
        capture_log([level: :debug], fn ->
          ids =
            for {worker, n} <- Enum.with_index(workers), into: %{} do
              {:ok, job} = %{"c4_boundary_probe" => n} |> worker.new() |> Oban.insert()
              {worker, job.id}
            end

          Process.put(:c4_job_ids, ids)

          queues =
            workers |> Enum.map(&Keyword.get(&1.__opts__(), :queue, :default)) |> Enum.uniq()

          for queue <- queues,
              do: bounded(fn -> Oban.drain_queue(queue: queue, with_safety: true) end, 30_000)
        end)

      ids = Process.get(:c4_job_ids)
      rows = job_rows(Map.values(ids))

      for {worker, id} <- ids do
        {_state, errors} = Map.fetch!(rows, id)
        refute errors =~ text, "C4-01a: #{inspect(worker)}: the canary reached oban_jobs.errors"

        assert errors =~ "Postgrex.Error",
               "C4-01a: #{inspect(worker)}: its job error is not the boundary summary: #{errors}"
      end

      assert_no_canary(log, text, "production workers")
    end

    test "every app Oban worker declares the error boundary (inventory)" do
      missing =
        Enum.reject(app_workers(), fn worker ->
          function_exported?(worker, :__sdr_error_boundary__, 0) and
            worker.__sdr_error_boundary__() == true
        end)

      assert missing == [], "C4-01a: workers without the error boundary: #{inspect(missing)}"
    end
  end

  defp app_worker?(module) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    source = to_string(module.module_info(:compile)[:source])
    Oban.Worker in behaviours and not String.contains?(source, "/test/")
  end

  # The attached primary filter function (presence-guarded).
  defp attached_filter! do
    require_module!(@filter)
    entry = List.keyfind(:logger.get_primary_config().filters, :sdr_agent_exception_filter, 0)

    assert match?({_, {fun, _}} when is_function(fun, 2), entry),
           "C4-01a: no :sdr_agent_exception_filter primary filter"

    {_, {fun, opts}} = entry
    {fun, opts}
  end

  ## ADR 227-231: the primary logger exception filter

  describe "ADR 227-231: the primary logger exception filter" do
    test "is attached as a primary filter of the running system" do
      {fun, _opts} = attached_filter!()
      assert Function.info(fun)[:module] == @filter
    end

    test "the attached filter rewrites error structs held in event metadata" do
      {fun, opts} = attached_filter!()
      text = canary()

      for meta <- [
            %{crash_reason: {pg_error(text), []}},
            %{reason: pg_error(text)},
            %{error: DBConnection.ConnectionError.exception(message: "connection " <> text)}
          ] do
        event = %{level: :error, msg: {:string, "c4 metadata case"}, meta: meta}
        result = fun.(event, opts)

        refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ text,
               "C4-01a: metadata #{inspect(Map.keys(meta))} kept the canary"

        assert is_map(result), "C4-01a: the event was dropped instead of rewritten"
      end
    end

    test "rewrites a Postgrex error in a report and in format arguments" do
      _ = attached_filter!()
      text = canary()
      error = pg_error(text)

      log =
        capture_log([level: :debug], fn ->
          :logger.error(%{label: {:c4, :report}, report: %{reason: error}})
          :logger.error(~c"c4 format case ~p", [error])
        end)

      assert log =~ "Postgrex.Error", "C4-01a: the events were dropped instead of summarized"
      assert_no_canary(log, text, "logger filter (Postgrex)")
    end

    test "rewrites DBConnection and Ash error structs" do
      _ = attached_filter!()
      text = canary()
      connection = DBConnection.ConnectionError.exception(message: "connection " <> text)

      ash =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :note,
              message: "bad",
              value: text
            )
          ]
        )

      log =
        capture_log([level: :debug], fn ->
          :logger.error(%{report: %{reason: connection}})
          :logger.error(%{report: %{error: ash}})
          :logger.error(~c"c4 ash format ~p", [ash])
        end)

      assert log =~ "DBConnection.ConnectionError"
      assert_no_canary(log, text, "logger filter (DBConnection, Ash)")
    end

    test "leaves an event without an error struct unchanged (positive control)" do
      {fun, opts} = attached_filter!()
      marker = "c4 plain marker " <> "unchanged"
      log = capture_log([level: :debug], fn -> Logger.error(marker) end)
      assert log =~ marker

      for event <- [
            %{level: :error, msg: {:string, marker}, meta: %{c4_safe: "kept", time: 1}},
            %{level: :warning, msg: {:report, %{c4: :report}}, meta: %{c4_safe: "kept"}},
            %{level: :info, msg: {~c"c4 ~p", [:safe]}, meta: %{}}
          ] do
        assert fun.(event, opts) == event,
               "C4-01a: a safe event was rewritten: #{inspect(fun.(event, opts))}"
      end
    end
  end

  ## ADR 250-251: handler attachment

  describe "ADR 250-251: handler attachment" do
    test "QueryLog and RepoSpans are attached; Ecto's logger and OpentelemetryEcto are not" do
      handlers = :telemetry.list_handlers(@event)
      ids = Enum.map(handlers, & &1.id)

      assert {SdrAgent.Repo.QueryLog, :query} in ids
      assert {SdrAgent.Telemetry.RepoSpans, :query} in ids

      refute Enum.any?(handlers, fn %{id: id, function: fun} ->
               inspect(id) =~ "OpentelemetryEcto" or
                 Function.info(fun)[:module] == OpentelemetryEcto
             end),
             "OpentelemetryEcto is attached"

      assert Repo.config()[:log] == false, "Ecto's default query logger is on"
    end
  end
end
