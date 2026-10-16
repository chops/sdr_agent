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
      sanitized reasons; every app worker declares the boundary
      (`__sdr_error_boundary__/0`);
    * ADR 250-251 — the default Ecto logger and `OpentelemetryEcto` are not
      attached; `QueryLog` and `RepoSpans` are.

  Interface choices made here, for review: the filter id
  `:sdr_agent_exception_filter` holding a function of
  `SdrAgent.Logger.ExceptionFilter`; `SdrAgent.Workers.ErrorBoundary.run/1`
  (`fun` result passed through, a database exception becomes `{:error,
  summary}` naming only the error module, SQLSTATE condition and declared
  constraint); the worker marker `__sdr_error_boundary__/0`.

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
    Test worker: runs a query that fails with a constraint error carrying
    the canary, inside the boundary (looked up at run time, so this module
    compiles before the boundary exists).
    """
    use Oban.Worker, queue: :default, max_attempts: 1

    @impl true
    def perform(%Oban.Job{args: %{"canary" => canary}}) do
      apply(SdrAgent.Workers.ErrorBoundary, :run, [
        fn ->
          SdrAgent.Repo.transaction(fn ->
            SQL.query!(
              SdrAgent.Repo,
              "INSERT INTO c4_error_path (v) VALUES ($1)",
              [canary]
            )
          end)
        end
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
    test "the boundary passes results through and summarizes a database exception" do
      require_module!(@boundary)
      assert function_exported?(@boundary, :run, 1), "C4-01a: ErrorBoundary.run/1 missing"
      text = canary()

      assert observe(fn -> apply(@boundary, :run, [fn -> {:ok, :done} end]) end) == {:ok, :done}

      result =
        observe(fn ->
          apply(@boundary, :run, [
            fn ->
              Repo.transaction(fn -> SQL.query!(Repo, "SELECT $1::text::integer", [text]) end)
            end
          ])
        end)

      refute match?({:raised, _}, result), "C4-01a: the boundary let the database exception raise"
      assert match?({:error, _}, result), "C4-01a: the boundary did not return {:error, _}"
      refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ text
      assert inspect(result) =~ "Postgrex.Error"
    end

    test "an Oban job that hits a constraint error leaves no canary in oban_jobs.errors" do
      require_module!(@boundary)
      text = canary()
      temp_tables!()

      log =
        capture_log([level: :debug], fn ->
          {:ok, _job} = %{"canary" => text} |> BoundaryWorker.new() |> Oban.insert()
          Oban.drain_queue(queue: :default, with_safety: true)
        end)

      errors =
        SQL.query!(
          Repo,
          "SELECT errors::text FROM oban_jobs WHERE worker = $1",
          [inspect(BoundaryWorker)]
        ).rows
        |> List.flatten()

      assert errors != [] and Enum.all?(errors, &(&1 =~ "Postgrex.Error")),
             "C4-01a: the job's error was not recorded as a summary: #{inspect(errors)}"

      refute Enum.any?(errors, &(&1 =~ text)), "C4-01a: the canary reached oban_jobs.errors"
      assert_no_canary(log, text, "Oban job")
    end

    test "every app Oban worker declares the error boundary" do
      {:ok, modules} = :application.get_key(:sdr_agent, :modules)

      workers = Enum.filter(modules, &app_worker?/1)

      assert length(workers) >= 12, "the worker inventory found #{length(workers)} workers"

      missing =
        Enum.reject(workers, fn worker ->
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
      _ = attached_filter!()
      marker = "c4 plain marker " <> "unchanged"
      log = capture_log([level: :debug], fn -> Logger.error(marker) end)
      assert log =~ marker
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
