defmodule SdrAgent.RemoteCallFixtures do
  @moduledoc """
  S-B2 RED fixtures (entity/plan r2 6f0de674, Codex PASS ed0835d1): the
  remote ClaudeCLI call (`SdrAgent.Agents.RemoteModelCall`), its
  `ClaimNonce`, `RemoteCallResult` and `RemoteCallReceipt`, the
  `SdrAgent.Operations.MacWorker` and the domain contracts
  `SdrAgent.Agents.RemoteCalls.claim/3`, `complete/5` and `heartbeat/2`.

  Every row is built through the real APIs:

    * `world!/0` binds a prototype in ORDINARY runtime
      (`SdrAgent.PrototypeGateFixtures.bound!/1`), admits real tuples
      (`SdrAgent.AdmissionFixtures.admit_tuples!/1`), creates an ordinary
      grant as the human admin and starts a run with its Operation;
    * `remote!/1` sets the trusted transport
      (`Application.put_env(:sdr_agent, :model_transport, ...)`) and
      restores the exact previous value on exit;
    * `enrol!/2` enrols a MacWorker by the owner-run `:enrol` action (a
      kernel request carrying the `:mac_worker` kernel marker) and returns
      the worker and the one-time 32-byte token (read from the created
      record's `:token` metadata);
    * `reserve!/2` reserves a ClaudeCLI call through
      `SdrAgent.Agents.reserve_model_invocation/3` whose stored request
      body carries `prompt/0` and `schema/0`.

  Absent modules and functions are reached only through `invoke/3`
  (`Function.capture/3` after a loaded and exported assertion), so a
  missing contract is an assertion failure, never a compile warning.
  Rows are inspected with plain SQL on the resource's table (the new
  resources have no read policy outside the RemoteCalls scope).
  Synthetic data only; no model, no CLI, no network.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ecto.Adapters.SQL
  alias SdrAgent.Actor
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.Repo

  @worker SdrAgent.Operations.MacWorker
  @call SdrAgent.Agents.RemoteModelCall
  @nonce SdrAgent.Agents.ClaimNonce
  @result SdrAgent.Agents.RemoteCallResult
  @receipt SdrAgent.Agents.RemoteCallReceipt
  @remote_calls SdrAgent.Agents.RemoteCalls

  @prompt_marker "SB2PROMPTMARKER7f3a"
  @transcript_marker "SB2TRANSCRIPTMARKER91c2"

  ## Module names (absent before GREEN)

  @doc "The MacWorker resource module."
  def worker_resource, do: @worker
  @doc "The RemoteModelCall resource module."
  def call_resource, do: @call
  @doc "The ClaimNonce resource module."
  def nonce_resource, do: @nonce
  @doc "The RemoteCallResult resource module."
  def result_resource, do: @result
  @doc "The RemoteCallReceipt resource module."
  def receipt_resource, do: @receipt
  @doc "The four new Agents resources and MacWorker."
  def resources, do: [@worker, @call, @nonce, @result, @receipt]

  @doc "The synthetic prompt marker (never in an AuditEvent payload)."
  def prompt_marker, do: @prompt_marker
  @doc "The synthetic transcript marker (never in an AuditEvent payload)."
  def transcript_marker, do: @transcript_marker

  ## Guards

  @doc "Asserts that `module` exists; returns it."
  def loaded!(module) do
    assert Code.ensure_loaded?(module), "#{inspect(module)} does not exist"
    module
  end

  @doc "Calls `module.fun(args...)` after asserting it is loaded and exported."
  def invoke(module, fun, args) do
    loaded!(module)
    arity = length(args)

    assert function_exported?(module, fun, arity),
           "#{inspect(module)}.#{fun}/#{arity} is not exported"

    Kernel.apply(Function.capture(module, fun, arity), args)
  end

  @doc "Runs `fun`; a raise becomes `{:raised, exception}` (assertion failures propagate)."
  def safely(fun) do
    fun.()
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> {:raised, error}
  end

  @doc "The table of `resource` (asserted loaded)."
  def table(resource) do
    loaded!(resource)
    AshPostgres.DataLayer.Info.table(resource)
  end

  ## Transport

  @doc "Sets the trusted transport for this test; the exact previous value is restored on exit."
  def remote!(transport \\ :remote) do
    previous = Application.fetch_env(:sdr_agent, :model_transport)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :model_transport, value)
        :error -> Application.delete_env(:sdr_agent, :model_transport)
      end
    end)

    Application.put_env(:sdr_agent, :model_transport, transport)
  end

  ## World

  @doc """
  A bound prototype in ordinary runtime with an admitted ordinary grant and
  a running run: `G.bound!/1`'s map plus `grant:` and `run:`.
  """
  def world! do
    fx = G.bound!()
    AdmissionFixtures.admit_tuples!()
    grant = AgentsFixtures.grant!(fx.tenant, %{}, fx.admin)
    run = G.run!(fx)
    Map.merge(fx, %{grant: grant, run: run})
  end

  ## Worker

  @doc "The four enrolled pins of real profile `profile_id` (string keys)."
  def pins(profile_id \\ :claude_cli_opus) do
    {:ok, profile} = ModelProfiles.fetch_real(profile_id)

    %{
      "profile_id" => Atom.to_string(profile.id),
      "model_id" => profile.resolved_model,
      "cli_version" => profile.cli_version,
      "executable_sha256" => hex(:crypto.hash(:sha256, "sb2-synthetic-executable"))
    }
  end

  @doc "The kernel marker context of the owner-run MacWorker actions."
  def marker_context do
    KernelMarker.context(:mac_worker)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :mac_worker marker")
  end

  @doc "Owner-run options: the tenant's kernel actor with the `:mac_worker` marker."
  def owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: marker_context()]

  @doc "Enrols a MacWorker on `fx`'s binding; returns `%{worker:, token:}`."
  def enrol!(fx, pins \\ pins()) do
    result = enrol(fx, pins, owner(fx))
    assert match?({:ok, %{id: _}}, result), "prerequisite: MacWorker :enrol: #{inspect(result)}"
    {:ok, worker} = result
    token = Ash.Resource.get_metadata(worker, :token)

    assert is_binary(token) and byte_size(token) == 32,
           "prerequisite: :enrol returns the 32-byte token once (metadata :token): " <>
             inspect(token)

    %{worker: worker, token: token}
  end

  @doc "The `:enrol` create with `opts`."
  def enrol(fx, pins, opts) do
    loaded!(@worker)

    safely(fn ->
      @worker
      |> Ash.Changeset.for_create(:enrol, %{binding_id: fx.binding.id, profile_pins: pins}, opts)
      |> Ash.create()
    end)
  end

  @doc "Disables `worker` by the owner-run `:disable` action."
  def disable!(fx, worker), do: owner_update!(fx, worker, :disable, %{})

  @doc "Sets `worker`'s intake by the owner-run `:set_intake` action."
  def set_intake!(fx, worker, intake),
    do: owner_update!(fx, worker, :set_intake, %{intake: intake})

  defp owner_update!(fx, worker, action, input) do
    loaded!(@worker)
    current = Ash.get!(@worker, worker.id, authorize?: false)

    result =
      safely(fn ->
        current
        |> Ash.Changeset.for_update(action, input, owner(fx))
        |> Ash.update()
      end)

    assert match?({:ok, %{id: _}}, result),
           "prerequisite: MacWorker #{action}: #{inspect(result)}"

    {:ok, updated} = result
    updated
  end

  ## Reservation

  @doc "The synthetic prompt (carries `prompt_marker/0`)."
  def prompt, do: "Qualify the synthetic lead example.test. " <> @prompt_marker

  @doc "The synthetic output schema."
  def schema,
    do: %{"type" => "object", "properties" => %{"qualified" => %{"type" => "boolean"}}}

  @doc "A stored request body in `ModelProvider.request_body/1`'s shape."
  def request(prompt \\ prompt(), schema \\ schema()) do
    Jason.encode!(%{
      id: "sb2-#{System.unique_integer([:positive])}",
      operation: "qualify",
      prompt: prompt,
      schema: schema
    })
  end

  @doc "`Agents.reserve_model_invocation/3` of a ClaudeCLI call in `fx.run`."
  def reserve(fx, overrides \\ %{}) do
    attrs = G.call_attrs(Map.merge(%{request: request()}, Map.new(overrides)))
    safely(fn -> Agents.reserve_model_invocation(fx.run, attrs, actor: fx.agent) end)
  end

  @doc "A successful reservation; returns the invocation."
  def reserve!(fx, overrides \\ %{}) do
    result = reserve(fx, overrides)

    assert match?({:ok, %ModelInvocation{}}, result),
           "prerequisite: reservation: #{inspect(result)}"

    {:ok, invocation} = result
    invocation
  end

  @doc "The stored invocation (kernel read)."
  def invocation(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  ## Domain contracts

  @doc "`RemoteCalls.claim(token, nonce, pins)`."
  def claim(token, nonce, pins \\ pins()),
    do: safely(fn -> invoke(@remote_calls, :claim, [token, nonce, pins]) end)

  @doc "`RemoteCalls.complete(token, nonce, call_id, request_digest, transcript)`."
  def complete(token, nonce, call_id, digest, transcript),
    do:
      safely(fn ->
        invoke(@remote_calls, :complete, [token, nonce, call_id, digest, transcript])
      end)

  @doc "`RemoteCalls.heartbeat(token, pins)`."
  def heartbeat(token, pins \\ pins()),
    do: safely(fn -> invoke(@remote_calls, :heartbeat, [token, pins]) end)

  @doc "A claim that returns a launch; returns the launch map."
  def claim!(token, nonce, pins \\ pins()) do
    result = claim(token, nonce, pins)
    assert match?({:ok, %{call_id: _}}, result), "prerequisite: claim: #{inspect(result)}"
    {:ok, launch} = result
    launch
  end

  @doc "The receipt kind of a completion result (`{:ok, kind}`, `{:error, kind}` or a receipt)."
  def kind({tag, kind}) when tag in [:ok, :error] and is_atom(kind), do: kind
  def kind({tag, %{kind: kind}}) when tag in [:ok, :error], do: kind
  def kind(other), do: {:unexpected, other}

  @doc """
  Runs `fun.(context)` through the test-seam-only
  `SdrAgent.Agents.RemoteCalls.__with_scope_for_test__/1`: inside a
  transaction with the process-bound RemoteCalls scope set (no public
  grant; absent in prod builds). Returns `fun`'s value (a transaction
  `{:ok, value}` is unwrapped).
  """
  def with_scope(fun) when is_function(fun, 1) do
    case invoke(@remote_calls, :__with_scope_for_test__, [fun]) do
      {:ok, value} -> value
      other -> other
    end
  end

  @doc "`term` with every reference replaced by a fresh one (a forged copy)."
  def fresh_refs(ref) when is_reference(ref), do: make_ref()
  def fresh_refs(%_{} = struct), do: struct
  def fresh_refs(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, fresh_refs(v)} end)
  def fresh_refs(list) when is_list(list), do: Enum.map(list, &fresh_refs/1)

  def fresh_refs(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> fresh_refs() |> List.to_tuple()

  def fresh_refs(other), do: other

  @doc "Whether `term` contains a reference."
  def has_ref?(ref) when is_reference(ref), do: true
  def has_ref?(%_{}), do: false
  def has_ref?(map) when is_map(map), do: Enum.any?(map, fn {_k, v} -> has_ref?(v) end)
  def has_ref?(list) when is_list(list), do: Enum.any?(list, &has_ref?/1)
  def has_ref?(tuple) when is_tuple(tuple), do: has_ref?(Tuple.to_list(tuple))
  def has_ref?(_other), do: false

  @doc "A fresh claim nonce (16..128 chars of [A-Za-z0-9_-])."
  def nonce, do: "nonce_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc "A synthetic stream-json transcript carrying `transcript_marker/0`."
  def transcript(label \\ "a") do
    ~s({"type":"system","subtype":"init"}\n) <>
      ~s({"type":"result","result":"#{@transcript_marker}-#{label}"}\n)
  end

  @doc "A digest in the same form as `digest` (32 raw bytes or lowercase hex) that differs."
  def other_digest(digest) when is_binary(digest) and byte_size(digest) == 32,
    do: :crypto.hash(:sha256, "sb2-other-" <> digest)

  def other_digest(digest) when is_binary(digest),
    do: hex(:crypto.hash(:sha256, "sb2-other-" <> digest))

  ## Rows

  @doc "Rows of `resource` matching `where` (SQL with $n params) as string-keyed maps."
  def rows(resource, where \\ "TRUE", params \\ []) do
    %{columns: columns, rows: rows} =
      Repo.query!(~s[SELECT * FROM "#{table(resource)}" WHERE #{where}], params)

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  @doc "Count of `resource` rows matching `where`."
  def count(resource, where \\ "TRUE", params \\ []) do
    %{rows: [[n]]} =
      Repo.query!(~s[SELECT count(*) FROM "#{table(resource)}" WHERE #{where}], params)

    n
  end

  @doc "The one RemoteModelCall row of `invocation_id`, or nil."
  def call_of(invocation_id) do
    case rows(@call, "model_invocation_id = $1", [dump(invocation_id)]) do
      [row] -> row
      [] -> nil
      many -> flunk("more than one RemoteModelCall for one invocation: #{inspect(many)}")
    end
  end

  @doc "Ids of the calls in `state` (a string)."
  def call_ids_in(state),
    do: Enum.map(rows(@call, "state = $1", [state]), &load(&1["id"]))

  @doc "The RemoteModelCall row `id`."
  def call_row(id) do
    assert [row] = rows(@call, "id = $1", [dump(id)]), "no RemoteModelCall #{id}"
    row
  end

  @doc "Receipts of call `id` ordered by position."
  def receipts(call_id),
    do: Enum.sort_by(rows(@receipt, "call_id = $1", [dump(call_id)]), & &1["position"])

  @doc "The xmax of row `id` of `resource` (changes when the row is locked or updated)."
  def xmax(resource, id) do
    %{rows: [[x]]} =
      Repo.query!(~s[SELECT xmax::text FROM "#{table(resource)}" WHERE id = $1], [dump(id)])

    x
  end

  @doc "AuditEvents of `fx`'s tenant of `type` whose subject is `subject_id`."
  def subject_count(fx, type, subject_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
          "AND subject_id = $3",
        [dump(fx.tenant.id), type, to_string(subject_id)]
      )

    n
  end

  @doc "Every AuditEvent payload of `fx`'s tenant as JSON text."
  def payload_texts(fx) do
    %{rows: rows} =
      Repo.query!("SELECT payload::text FROM audit_events WHERE tenant_id = $1", [
        dump(fx.tenant.id)
      ])

    List.flatten(rows)
  end

  @doc "Count of AuditEvents of the tenant."
  def event_count(fx) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM audit_events WHERE tenant_id = $1", [dump(fx.tenant.id)])

    n
  end

  @doc """
  Copies the row(s) of `resource` matching `where` into a temporary table,
  sets `set` (`[{column, value}]`) on the copy and inserts it back.
  `replica: true` disables triggers and foreign keys (a planted row, as an
  administrator would). Returns `:ok` or `{:error, %Postgrex.Error{}}`.
  """
  def copy_insert(resource, where, params, set, opts \\ []) do
    t = table(resource)
    tmp = "sb2_copy_#{System.unique_integer([:positive])}"

    replica? = Keyword.get(opts, :replica, false)

    result =
      Repo.transaction(fn ->
        if replica?, do: q!("SET LOCAL session_replication_role = replica")
        q!(~s[CREATE TEMP TABLE #{tmp} AS SELECT * FROM "#{t}" WHERE #{where}], params)
        Enum.each(set, fn {col, value} -> q!(~s[UPDATE #{tmp} SET "#{col}" = $1], [value]) end)
        insert_copy(t, tmp, replica?)
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp insert_copy(t, tmp, replica?) do
    case SQL.query(Repo, ~s[INSERT INTO "#{t}" SELECT * FROM #{tmp}], []) do
      {:ok, _} ->
        q!("DROP TABLE #{tmp}")
        if replica?, do: q!("SET LOCAL session_replication_role = origin")
        :ok

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  @doc "Runs `sql` with triggers disabled in a savepoint that is rolled back; returns the error."
  def replica_error(sql, params \\ []) do
    Repo.transaction(fn ->
      q!("SET LOCAL session_replication_role = replica")

      case SQL.query(Repo, sql, params) do
        {:ok, result} -> Repo.rollback({:unexpected_success, result})
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc "Asserts a Postgres error with `code` (and returns the error)."
  def assert_pg!(result, code, label) do
    assert match?({:error, %Postgrex.Error{postgres: %{code: ^code}}}, result),
           "#{label}: expected #{code}, got #{inspect(result)}"

    {:error, error} = result
    error
  end

  @doc "Column names of constraint `name` (by pg_constraint) of `table`."
  def constraint_columns(table, name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT a.attname FROM pg_constraint c " <>
          "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey) " <>
          "WHERE c.conrelid = $1::regclass AND c.conname = $2",
        [table, name]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  @doc "Foreign keys of `table`: `[{sorted columns, referenced table, sorted referenced columns}]`."
  def foreign_keys(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.conname, " <>
          "(SELECT array_agg(a.attname ORDER BY a.attname) FROM pg_attribute a " <>
          " WHERE a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)), " <>
          "c.confrelid::regclass::text, " <>
          "(SELECT array_agg(a.attname ORDER BY a.attname) FROM pg_attribute a " <>
          " WHERE a.attrelid = c.confrelid AND a.attnum = ANY(c.confkey)) " <>
          "FROM pg_constraint c WHERE c.conrelid = $1::regclass AND c.contype = 'f'",
        [table]
      )

    Enum.map(rows, fn [_name, cols, ref, ref_cols] -> {cols, String.trim(ref, "\""), ref_cols} end)
  end

  @doc "Unique indexes of `table`: `[{sorted columns, predicate or nil}]`."
  def unique_indexes(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT (SELECT array_agg(a.attname ORDER BY a.attname) FROM pg_attribute a " <>
          " WHERE a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)), " <>
          "pg_get_expr(i.indpred, i.indrelid) " <>
          "FROM pg_index i WHERE i.indrelid = $1::regclass AND i.indisunique",
        [table]
      )

    Enum.map(rows, fn [cols, pred] -> {cols, pred} end)
  end

  ## Values

  @doc "Binary UUID."
  def dump(id), do: Ecto.UUID.dump!(id)

  @doc "String UUID of a raw column value."
  def load(nil), do: nil
  def load(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  def load(id) when is_binary(id), do: id

  @doc "A raw timestamp column value as a UTC DateTime."
  def ts(%DateTime{} = at), do: at
  def ts(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  def ts(other), do: other

  @doc "Lowercase hex."
  def hex(bin), do: Base.encode16(bin, case: :lower)

  @doc "A fixed UTC instant with microsecond precision, `offset` seconds from now (truncated)."
  def instant(offset \\ 0) do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.add(offset, :second)
    |> Map.put(:microsecond, {0, 6})
  end

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)
end
