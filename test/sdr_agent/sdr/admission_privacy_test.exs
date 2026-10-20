defmodule SdrAgent.SDR.AdmissionPrivacyTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 H (T-H1..T-H3): privacy canaries for
  `SDR.admit_lead/2` (packet C3-R10, section 7 "Executable proof", the
  section 9 privacy bullet, obligation O4; plan section 1.3 C3-R10).

  Every scenario carries its own unique synthetic name, email and domain
  canaries (`c302canary<n>n`, `c302canary<n>e`, `c302canary<n>d.test`):
  valid (admitted), invalid (company domain and email), conflicting
  (`:source_ref_conflict`), suppressed (by email and by company domain)
  and replayed input. With Logger at `:debug`, `otel_capture_content: true`
  (as in dev) and the ADR-0005 C4 amendment's controls attached
  (`QueryLog`, `RepoSpans`, the `:sdr_agent_exception_filter` primary
  filter), no canary reaches:

    * T-H1: the captured log output;
    * T-H2: any exported span's attributes, events or status;
    * T-H3: a returned error term, or `oban_jobs.errors` (and `args`) of the
      queued runs' jobs and of the whole `oban_jobs` table.

  Only the admission calls run inside the capture window; the suppression
  pre-state is written before it, and the span exporter is reset after it.

  RED form: `SDR.admit_lead/2` and `SDR.bootstrap_definitions/1` are
  guarded before any call and called through `apply/3`, so each test fails
  at a `C3-02:` presence assertion. Setup uses main's APIs only.

  Interface names chosen here for review:
    * refused-input shapes asserted loosely: `{:error, {:invalid, [_ | _]}}`
      for invalid input (the field list is T-F2's), `{:error,
      :source_ref_conflict}`, `{:ok, %{outcome: :suppressed}}`, `{:ok,
      %{replayed?: true}}`;
    * the queued run's job is found through `agent_runs.operation_id` and
      `operations.oban_job_id`; it is not executed (Oban `testing: :manual`),
      so its `errors` are empty by construction and asserted so: this is
      not coverage of errors an executor persists (a failing research
      attempt is not exercised here; the webhook job's executed, persisted
      error is T-K10's case), only of the job's persisted `args` and of the
      state the admission leaves.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  require Record

  alias SdrAgent.Outreach
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SettingsFixtures
  alias SdrAgent.Telemetry.InMemoryExporter

  @sdr SdrAgent.SDR
  @filter_id :sdr_agent_exception_filter

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    campaign = SalesFixtures.active_campaign!(tenant)
    SettingsFixtures.save_offering!(admin)

    level = Logger.level()
    capture = Application.fetch_env(:sdr_agent, :otel_capture_content)

    on_exit(fn ->
      Logger.configure(level: level)
      restore_capture(capture)
      InMemoryExporter.reset()
    end)

    Logger.configure(level: :debug)
    Application.put_env(:sdr_agent, :otel_capture_content, true)
    InMemoryExporter.reset()

    %{tenant: tenant, admin: admin, campaign: campaign}
  end

  describe "T-H1..T-H3 canaries over valid, invalid, conflicting, suppressed and replayed input" do
    test "T-H1 no canary reaches the logs at :debug", ctx do
      %{log: log, tokens: tokens} = run_scenarios(ctx)

      assert Logger.level() == :debug
      assert List.keymember?(:logger.get_primary_config().filters, @filter_id, 0)

      for {label, field, token} <- tokens do
        refute log =~ token, "C3-02: #{label}: the #{field} canary reached a log"
      end
    end

    test "T-H2 no canary reaches exported span attributes, events or status", ctx do
      %{tokens: tokens} = run_scenarios(ctx)

      assert Application.get_env(:sdr_agent, :otel_capture_content) == true
      parts = span_parts()
      assert parts != [], "C3-02: the admissions exported no spans"

      for part <- parts,
          section <- [:attributes, :events, :status],
          {label, field, token} <- tokens do
        refute Map.fetch!(part, section) =~ token,
               "C3-02: #{label}: the #{field} canary reached span #{inspect(part.name)} #{section}"
      end

      spans = inspect(InMemoryExporter.spans(), limit: :infinity, printable_limit: :infinity)

      for {label, field, token} <- tokens do
        refute spans =~ token, "C3-02: #{label}: the #{field} canary reached a span"
      end
    end

    test "T-H3 no canary reaches a returned error or oban_jobs.errors of the queued runs", ctx do
      %{results: results, tokens: tokens} = run_scenarios(ctx)

      errors =
        for {label, _expected, {:error, _} = result} <- results, do: {label, render(result)}

      assert length(errors) == 3,
             "C3-02: the two invalid and the conflicting inputs return errors"

      for {label, rendered} <- errors, {_scenario, field, token} <- tokens do
        refute rendered =~ token, "C3-02: #{label}: the #{field} canary reached the error term"
      end

      runs = for {_label, :admitted, {:ok, %{run: run}}} <- results, do: run
      assert length(runs) == 3, "C3-02: every admitted scenario returns its queued run"

      # The queued runs' jobs are not executed here (Oban `testing:
      # :manual`), so their persisted `errors` are empty by construction:
      # asserted as such, not counted as executor-sanitized error coverage
      # (that is T-K10's real-execution case for the webhook job).
      for run <- runs, do: assert(elem(run_job!(run), 0) == "[]")

      for run <- runs,
          {job_errors, job_args} <- [run_job!(run)],
          {label, field, token} <- tokens do
        refute job_errors =~ token,
               "C3-02: #{label}: the #{field} canary reached oban_jobs.errors"

        refute job_args =~ token, "C3-02: #{label}: the #{field} canary reached oban_jobs.args"
      end

      for {label, field, token} <- tokens do
        assert oban_rows_containing(token) == 0,
               "C3-02: #{label}: the #{field} canary reached an oban_jobs row"
      end
    end
  end

  ## Scenarios

  # Runs every scenario's admissions inside one capture window and checks
  # each returned the shape it exercises, so no canary check is vacuous.
  defp run_scenarios(ctx) do
    present!(@sdr, :bootstrap_definitions, 1)
    present!(@sdr, :admit_lead, 2)
    definitions!(ctx.tenant)

    {steps, tokens} = scenarios(ctx)
    InMemoryExporter.reset()

    {results, log} =
      with_log([level: :debug], fn ->
        for {label, expected, input} <- steps, do: {label, expected, attempt(ctx, input)}
      end)

    for {label, expected, result} <- results do
      assert expected?(expected, result),
             "C3-02: #{label}: expected #{inspect(expected)}, got #{inspect(result)}"
    end

    %{results: results, log: log, tokens: tokens}
  end

  defp scenarios(ctx) do
    valid = canaries()
    bad_domain = canaries()
    bad_email = canaries()
    first = canaries()
    conflicting = canaries()
    by_email = canaries()
    by_domain = canaries()
    replayed = canaries()

    suppress!(ctx, :email, email(by_email))
    suppress!(ctx, :domain, by_domain.domain)

    conflict_ref = "manual:#{Ecto.UUID.generate()}"
    replay_input = input(ctx, replayed)

    steps = [
      {"valid", :admitted, input(ctx, valid)},
      {"invalid domain", :invalid,
       input(ctx, bad_domain, %{domain: "www.www." <> bad_domain.domain})},
      {"invalid email", :invalid,
       input(ctx, bad_email, %{email: "#{bad_email.email}.at.#{bad_email.domain}"})},
      {"conflict, first", :admitted, input(ctx, first, %{source_ref: conflict_ref})},
      {"conflicting", :source_ref_conflict, input(ctx, conflicting, %{source_ref: conflict_ref})},
      {"suppressed by email", :suppressed, input(ctx, by_email)},
      {"suppressed by domain", :suppressed, input(ctx, by_domain)},
      {"replay, first", :admitted, replay_input},
      {"replayed", :replayed, replay_input}
    ]

    tokens =
      for {label, set} <- [
            {"valid", valid},
            {"invalid domain", bad_domain},
            {"invalid email", bad_email},
            {"conflict, first", first},
            {"conflicting", conflicting},
            {"suppressed by email", by_email},
            {"suppressed by domain", by_domain},
            {"replayed", replayed}
          ],
          {field, token} <- [name: set.name, email: set.email, domain: set.domain],
          do: {label, field, token}

    {steps, tokens}
  end

  defp expected?(:admitted, {:ok, %{outcome: :admitted, replayed?: false, run: %{id: _}}}),
    do: true

  defp expected?(:invalid, {:error, {:invalid, [_ | _]}}), do: true
  defp expected?(:source_ref_conflict, {:error, :source_ref_conflict}), do: true
  defp expected?(:suppressed, {:ok, %{outcome: :suppressed, replayed?: false}}), do: true
  defp expected?(:replayed, {:ok, %{outcome: :admitted, replayed?: true}}), do: true
  defp expected?(_expected, _result), do: false

  # Three distinct canaries; the suffixes keep one from being a prefix of another.
  defp canaries do
    %{
      name: "c302canary#{SalesFixtures.unique()}n",
      email: "c302canary#{SalesFixtures.unique()}e",
      domain: "c302canary#{SalesFixtures.unique()}d.test"
    }
  end

  defp email(set), do: "#{set.email}@#{set.domain}"

  defp input(ctx, set, overrides \\ %{}) do
    %{
      source_kind: :manual,
      source_ref: Map.get(overrides, :source_ref, "manual:#{Ecto.UUID.generate()}"),
      campaign_id: ctx.campaign.id,
      company: %{domain: Map.get(overrides, :domain, set.domain), name: "Co #{set.name}"},
      person: %{
        email: Map.get(overrides, :email, email(set)),
        first_name: set.name,
        last_name: "L#{set.name}",
        title: "VP Operations",
        timezone: "America/Denver"
      }
    }
  end

  defp suppress!(ctx, scope, value) do
    assert {:ok, _suppression} =
             Outreach.suppress(%{scope: scope, value: value}, actor: ctx.admin)
  end

  ## Guards and calls

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

  defp definitions!(tenant) do
    result = call(@sdr, :bootstrap_definitions, [tenant.id])

    assert match?({:ok, _definition}, result),
           "C3-02: bootstrap_definitions/1 must return the committed definition"
  end

  # A raise becomes `{:raised, module}`, which no expected shape matches.
  defp attempt(ctx, input) do
    call(@sdr, :admit_lead, [input, [actor: ctx.admin]])
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> {:raised, error.__struct__}
  end

  ## Capture

  defp restore_capture({:ok, value}),
    do: Application.put_env(:sdr_agent, :otel_capture_content, value)

  defp restore_capture(:error), do: Application.delete_env(:sdr_agent, :otel_capture_content)

  defp render(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  # Each exported span's attributes, events and status, rendered separately.
  defp span_parts do
    # The simple processor exports on span end; give it a moment.
    Process.sleep(50)

    for record <- InMemoryExporter.spans() do
      %{
        name: span(record, :name),
        attributes: render(span(record, :attributes)),
        events: render(span(record, :events)),
        status: render(span(record, :status))
      }
    end
  end

  ## oban_jobs

  # The queued run's job (run -> its Operation -> the Oban job), exactly one.
  defp run_job!(run) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT j.errors::text, j.args::text
        FROM agent_runs r
        JOIN operations o ON o.id = r.operation_id
        JOIN oban_jobs j ON j.id = o.oban_job_id
        WHERE r.id = $1
        """,
        [Ecto.UUID.dump!(run.id)]
      )

    assert [[errors, args]] = rows
    {errors, args}
  end

  defp oban_rows_containing(token) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM oban_jobs WHERE strpos(errors::text, $1) > 0 OR strpos(args::text, $1) > 0",
        [token]
      )

    count
  end
end
