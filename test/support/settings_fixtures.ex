defmodule SdrAgent.SettingsFixtures do
  @moduledoc """
  Builders and presence-guarded calls for the C4 run settings tests
  (`docs/product/c4/readiness.md`, slice C4-01a): synthetic content for the
  five settings kinds, the built-in limit defaults and validation ranges of
  section 3.3, the section 3.7 hash recomputations, raw-SQL readers of the
  new tables, and result classifiers that turn a missing or wrong behaviour
  into an assertion failure instead of a crash.

  Every new module or function is reached through `call/3` (or a helper
  built on it), which first asserts that it exists, so on a tree without
  C4-01a each test fails on an explicit `C4-01a: ...` assertion after its
  fixtures. All content is synthetic (reserved `example.test` hosts only).
  """

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Repo

  @revision SdrAgent.Agents.SettingsRevision
  @snapshot SdrAgent.Agents.RunSettingsSnapshot
  @run_settings SdrAgent.Agents.RunSettings
  @code_defaults SdrAgent.Agents.RunSettings.CodeDefaults
  @safeguards SdrAgent.Agents.RunSettings.Safeguards

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]
  @int_max 2_147_483_647

  # Section 3.3: built-in default and minimum per field; every field has the
  # sanity maximum 2,147,483,647.
  @limits [
    run_max_model_calls: {20, 1},
    run_max_tool_calls: {60, 1},
    run_max_tokens: {100_000, 1},
    research_max_search_requests: {4, 0},
    research_max_page_fetches: {4, 0},
    research_max_sources: {6, 1},
    research_max_source_chars: {4_000, 500},
    research_max_total_source_chars: {24_000, 500},
    research_max_output_tokens: {2_500, 256},
    research_max_model_calls: {2, 1},
    research_target_seconds: {180, 30},
    research_job_limit_seconds: {600, 60}
  ]

  @doc "The settings revision resource module (C4-01a)."
  def revision_resource, do: @revision

  @doc "The run settings snapshot resource module (C4-01a)."
  def snapshot_resource, do: @snapshot

  @doc "The `SdrAgent.Agents.RunSettings` module (C4-01a)."
  def run_settings_module, do: @run_settings

  @doc "The built-in defaults registry module (C4-01a)."
  def code_defaults_module, do: @code_defaults

  @doc "The five settings kinds, in packet order."
  def kinds, do: @kinds

  @doc "The twelve operational limit field names, in packet order."
  def limit_fields, do: Keyword.keys(@limits)

  @doc "The built-in limit defaults of section 3.3."
  def limit_defaults, do: Map.new(@limits, fn {field, {default, _min}} -> {field, default} end)

  @doc "The validation minimum of each limit field (section 3.3)."
  def limit_minimums, do: Map.new(@limits, fn {field, {_default, min}} -> {field, min} end)

  @doc "The sanity maximum shared by every limit field (signed 32-bit)."
  def int_max, do: @int_max

  @doc "A canary string that must never leave the authorized seams (test 23)."
  def canary, do: "c4canary" <> "ZQXJ7"

  ## Presence-guarded calls

  @doc "Asserts that `module` is compiled and loadable."
  def require_module!(module) do
    assert Code.ensure_loaded?(module), "C4-01a: #{inspect(module)} missing"
    module
  end

  @doc "Asserts `module.fun/arity` exists, then applies it."
  def call(module, fun, args) do
    require_module!(module)

    assert function_exported?(module, fun, length(args)),
           "C4-01a: #{inspect(module)}.#{fun}/#{length(args)} is not implemented"

    apply(module, fun, args)
  end

  @doc "`SdrAgent.Agents.fun(args...)`, presence-guarded."
  def agents(fun, args), do: call(SdrAgent.Agents, fun, args)

  @doc "`Agents.create_settings_revision/2` with `attrs` as `actor`."
  def create_revision(attrs, actor),
    do: agents(:create_settings_revision, [Map.new(attrs), [actor: actor]])

  @doc """
  Saves `content` of `kind` as `actor` against the latest committed number
  (or `opts[:expected_number]`) and asserts success; returns the revision.
  Options: `:expected_number`, `:confirm_raised`, `:note`.
  """
  def save!(kind, content, actor, opts \\ []) do
    attrs = revision_attrs(kind, content, actor, opts)
    result = create_revision(attrs, actor)

    assert match?({:ok, _}, result),
           "C4-01a: saving #{kind} failed: #{inspect(result, limit: 8, printable_limit: 200)}"

    {:ok, revision} = result
    revision
  end

  @doc "The attributes `save!/4` sends."
  def revision_attrs(kind, content, actor, opts \\ []) do
    assert function_exported?(SdrAgent.Agents, :create_settings_revision, 2),
           "C4-01a: SdrAgent.Agents.create_settings_revision/2 is not implemented"

    expected =
      Keyword.get_lazy(opts, :expected_number, fn -> latest_number(actor.tenant_id, kind) end)

    %{
      kind: kind,
      content: content,
      expected_number: expected,
      note: Keyword.get(opts, :note),
      confirm_raised: Keyword.get(opts, :confirm_raised, [])
    }
  end

  @doc "Saves the synthetic offering profile of section 3.9 as `admin`."
  def save_offering!(admin, overrides \\ %{}),
    do: save!(:offering_profile, content(:offering_profile, overrides), admin)

  @doc "`run_settings/2` of `run` as `actor`."
  def run_settings(run, actor), do: agents(:run_settings, [run, [actor: actor]])

  @doc "`RunSettings.allowance/2`."
  def allowance(run, field), do: call(@run_settings, :allowance, [run, field])

  @doc "`RunSettings.booking_link_for_use/1`."
  def booking_link_for_use(run), do: call(@run_settings, :booking_link_for_use, [run])

  @doc "The released built-in defaults of `kind` (`CodeDefaults.released/1`)."
  def released_defaults(kind), do: call(@code_defaults, :released, [kind])

  @doc "The current built-in default of `kind` (`CodeDefaults.current/1`)."
  def current_default(kind), do: call(@code_defaults, :current, [kind])

  @doc "The safeguards registry version (`Safeguards.version/0`)."
  def safeguards_version, do: call(@safeguards, :version, [])

  ## Synthetic content

  @doc "Valid synthetic content of `kind`, merged with `overrides`."
  def content(kind, overrides \\ %{})

  def content(:offering_profile, overrides) do
    Map.merge(
      %{
        name: "Example Widgets Scheduler",
        summary: "A synthetic scheduling product used only in tests.",
        audience: "Operations teams at synthetic example companies.",
        items: [
          %{id: "calendar_sync", kind: :feature, text: "Syncs synthetic team calendars."},
          %{id: "fewer_no_shows", kind: :outcome, text: "Fewer missed synthetic meetings."},
          %{id: "no_payroll", kind: :limit, text: "Does not run payroll."}
        ]
      },
      Map.new(overrides)
    )
  end

  def content(:booking_link, overrides),
    do: Map.merge(%{url: "https://book.example.test/demo/intro"}, Map.new(overrides))

  def content(:writing_guide, overrides),
    do:
      Map.merge(
        %{text: "Write short, plain emails.\nAsk one clear question.\tNo hype."},
        Map.new(overrides)
      )

  def content(:research_brief, overrides),
    do:
      Map.merge(
        %{guidance: "Look for the synthetic company's scheduling needs.", depth: :standard},
        Map.new(overrides)
      )

  def content(:operational_limits, overrides),
    do: Map.merge(limit_defaults(), Map.new(overrides))

  @doc "The fields of `limits` raised above `previous`, sorted (the confirmation set)."
  def raised(limits, previous) do
    limit_fields()
    |> Enum.filter(fn field -> Map.fetch!(limits, field) > Map.fetch!(previous, field) end)
    |> Enum.sort()
  end

  ## Hash contracts (section 3.7)

  @doc "Lowercase hex."
  def to_hex(bin), do: Base.encode16(bin, case: :lower)

  @doc """
  `content_sha256` recomputed from a stored revision: the content attribute
  of its kind dumped with `Ash.Type.dump_to_embedded/3`, hashed in the
  `c4-settings-content/1` envelope.
  """
  def recompute_content_sha256(revision) do
    kind = Map.fetch!(revision, :kind)
    content_sha256(kind, Map.fetch!(revision, kind))
  end

  @doc "`content_sha256` of cast `value` of `kind` (section 3.7)."
  def content_sha256(kind, value) do
    attribute = Ash.Resource.Info.attribute(require_module!(@revision), kind)
    assert attribute, "C4-01a: SettingsRevision has no #{kind} attribute"
    {:ok, dumped} = Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints)

    %{"schema" => "c4-settings-content/1", "kind" => Atom.to_string(kind), "content" => dumped}
    |> Canonical.sha256()
    |> to_hex()
  end

  @doc "The hashed slot map of `kind` built from a stored snapshot's columns."
  def slot_of(snapshot, kind) do
    case Map.get(snapshot, :"#{kind}_source") do
      :revision ->
        %{
          "source" => "revision",
          "revision_id" => Map.get(snapshot, :"#{kind}_revision_id"),
          "content_sha256" => Map.get(snapshot, :"#{kind}_content_sha256")
        }

      :code_default ->
        %{
          "source" => "code_default",
          "version" => Map.get(snapshot, :"#{kind}_code_default_version"),
          "content_sha256" => Map.get(snapshot, :"#{kind}_content_sha256")
        }

      :absent ->
        %{"source" => "absent"}

      other ->
        flunk("C4-01a: snapshot #{kind}_source is #{inspect(other)}")
    end
  end

  @doc "The twelve limits of a snapshot as a string-keyed integer map."
  def limits_map(limits),
    do: Map.new(limit_fields(), fn field -> {Atom.to_string(field), Map.get(limits, field)} end)

  @doc "`snapshot_sha256` recomputed from the stored columns (section 3.7)."
  def recompute_snapshot_sha256(snapshot) do
    %{
      "schema" => "c4-run-settings-snapshot/1",
      "tenant_id" => snapshot.tenant_id,
      "safeguards_version" => snapshot.safeguards_version,
      "slots" => Map.new(@kinds, fn kind -> {Atom.to_string(kind), slot_of(snapshot, kind)} end),
      "limits" => limits_map(snapshot.limits)
    }
    |> Canonical.sha256()
    |> to_hex()
  end

  @doc "The stored snapshot of `run` (read as `actor`)."
  def snapshot_of!(run, actor) do
    require_module!(@snapshot)
    id = Map.get(run, :settings_snapshot_id)
    assert is_binary(id), "C4-01a: run #{run.id} has no settings_snapshot_id"
    {:ok, snapshot} = Ash.get(@snapshot, id, actor: actor)
    snapshot
  end

  @doc "A resolved slot of a `run_settings/2` result (nil when absent)."
  def slot(settings, kind) when is_map(settings), do: Map.get(settings, kind)
  def slot(_settings, _kind), do: nil

  @doc "`key` of the resolved slot of `kind` (`:missing` when there is no such slot)."
  def slot_value(settings, kind, key) do
    case slot(settings, kind) do
      %{} = resolved -> Map.get(resolved, key, :missing)
      _other -> :missing
    end
  end

  @doc "The sequence number of the one event of `type` about `subject_id`."
  def event_sequence(tenant_id, type, subject_id) do
    rows =
      SQL.query!(
        Repo,
        "SELECT sequence FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
          "AND subject_id = $3",
        [Ecto.UUID.dump!(tenant_id), type, subject_id]
      ).rows

    assert match?([[_]], rows), "C4-01a: expected one #{type} event for #{subject_id}"
    [[sequence]] = rows
    sequence
  end

  ## Raw SQL readers

  @doc "Whether `table` exists."
  def table_exists?(table),
    do: SQL.query!(Repo, "SELECT to_regclass($1) IS NOT NULL", [table]).rows == [[true]]

  @doc "Asserts that `table` exists."
  def require_table!(table), do: assert(table_exists?(table), "C4-01a: table #{table} missing")

  @doc "Whether `table.column` exists."
  def column_exists?(table, column) do
    SQL.query!(
      Repo,
      "SELECT count(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
      [table, column]
    ).rows == [[1]]
  end

  @doc "Asserts that `table.column` exists."
  def require_column!(table, column),
    do: assert(column_exists?(table, column), "C4-01a: column #{table}.#{column} missing")

  @doc "Row count of `table` (asserting it exists)."
  def count_rows(table) do
    require_table!(table)
    [[n]] = SQL.query!(Repo, "SELECT count(*) FROM #{table}", []).rows
    n
  end

  @doc "The latest committed revision number of `kind` in `tenant_id` (0 when none)."
  def latest_number(tenant_id, kind) do
    require_table!("settings_revisions")

    [[n]] =
      SQL.query!(
        Repo,
        "SELECT coalesce(max(number), 0) FROM settings_revisions WHERE tenant_id = $1 AND kind = $2",
        [Ecto.UUID.dump!(tenant_id), Atom.to_string(kind)]
      ).rows

    n
  end

  @doc "Revision rows of `kind`: `[[number, id]]` by number."
  def revision_numbers(tenant_id, kind) do
    require_table!("settings_revisions")

    SQL.query!(
      Repo,
      "SELECT number FROM settings_revisions WHERE tenant_id = $1 AND kind = $2 ORDER BY number",
      [Ecto.UUID.dump!(tenant_id), Atom.to_string(kind)]
    ).rows
    |> List.flatten()
  end

  @doc "Whether any row of `table` contains `text` (row rendered as text)."
  def table_contains?(table, text) do
    if table_exists?(table) do
      [[n]] =
        SQL.query!(
          Repo,
          "SELECT count(*) FROM #{table} t WHERE position($1 in t::text) > 0",
          [text]
        ).rows

      n > 0
    else
      false
    end
  end

  @doc "Whether any stored Payload's content contains `text`."
  def payloads_contain?(text) do
    [[n]] =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM payloads WHERE position($1::bytea in content) > 0",
        [text]
      ).rows

    n > 0
  end

  ## Result classifiers

  @doc """
  Runs `fun`, turning a raise or exit into `{:raised, exception}` /
  `{kind, reason}`. An `ExUnit.AssertionError` (a presence guard) is
  re-raised, so a missing C4-01a function still fails as that assertion.
  """
  def observe(fun) do
    fun.()
  rescue
    exception in ExUnit.AssertionError -> reraise exception, __STACKTRACE__
    exception -> {:raised, exception}
  catch
    kind, reason -> {kind, reason}
  end

  @doc "A refusal of an unauthorized actor (`:forbidden` or `Ash.Error.Forbidden`)."
  def forbidden?({:error, :forbidden}), do: true
  def forbidden?({:error, %Ash.Error.Forbidden{}}), do: true
  def forbidden?(_result), do: false

  @doc "The field errors of `{:error, {:invalid, errors}}`, else nil."
  def invalid_errors({:error, {:invalid, errors}}) when is_list(errors), do: errors
  def invalid_errors(_result), do: nil

  @doc """
  Whether `result` is the business-completeness refusal naming `kinds`:
  `{:error, {:settings_incomplete, kinds}}`, or an Ash error class whose
  message names `settings_incomplete` and each kind.
  """
  def settings_incomplete?({:error, {:settings_incomplete, kinds}}, kinds), do: true

  def settings_incomplete?({:error, %{__exception__: true} = error}, kinds) do
    message = Exception.message(error)

    message =~ "settings_incomplete" and
      Enum.all?(kinds, &(message =~ Atom.to_string(&1)))
  end

  def settings_incomplete?(_result, _kinds), do: false

  @doc """
  Whether a raw-SQL `result` (`SdrAgent.AuditCase.raw_error/2`) was refused
  by the database for a reason other than a missing table or column.
  """
  def refused_by_db?({:error, %Postgrex.Error{postgres: %{code: code}}}),
    do: code not in [:undefined_table, :undefined_column, :syntax_error]

  def refused_by_db?(_result), do: false

  ## Test doubles

  @doc "Booking-link guard override that refuses every host (test 22)."
  def deny_every_host(_host), do: false

  @doc "Booking-link guard override that refuses only `book2.example.test` (test 22)."
  def deny_book2(host), do: host != "book2.example.test"
end

defmodule SdrAgent.SettingsFixtures.RecordingBrain do
  @moduledoc """
  Fake model responder for the C4 booking-link tests: sends each structured
  model input to the pid configured under
  `config :sdr_agent, SdrAgent.SettingsFixtures.RecordingBrain`, then answers
  as the fixture brain (`SdrAgent.SDR.FakeBrain`).
  """

  alias SdrAgent.SDR.FakeBrain

  @doc "Records `{operation, input}` and delegates to `FakeBrain`."
  def respond(operation, input) do
    case Application.get_env(:sdr_agent, __MODULE__) do
      pid when is_pid(pid) -> send(pid, {:fake_model_input, operation, input})
      _ -> :ok
    end

    FakeBrain.respond(operation, input)
  end
end
