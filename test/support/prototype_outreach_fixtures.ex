defmodule SdrAgent.PrototypeOutreachFixtures do
  @moduledoc """
  D-237 slice S4 test builders (interfaces r6 IF-3 delegated approval, IF-5
  output, amendment items 8 and 9) on top of `SdrAgent.PrototypeCase` and
  `SdrAgent.PrototypeFixtures` (S1). Synthetic `.test` data only.

  - `prototype_drafted!/1` binds a prototype in the sandbox WITHOUT entering
    prototype runtime, seeds the deterministic demo data set into the bound
    tenant (the singleton), lets the existing fake agent draft fixture lead
    `key` in ORDINARY runtime, then enters prototype runtime for the test
    process (and its `$callers`) and freezes the clock inside the D-239
    window. It returns an `SdrAgent.SDRCase`-shaped context (`tenant`,
    `admin`, `agent`, `aud`, `campaign_id`) plus `fixture` (the S1 bind
    result), `operator` (the resolved operator actor), `anchor`, `draft`,
    `revision`, `lead`, `run` and `contact`.
  - `enter_window!/1,2` enters prototype runtime with the fixture's snapshot
    and freezes the clock inside the window (named apart from S1's
    `SdrAgent.PrototypeCase.enter!/1`, which enters runtime only).
  - `window_start/0`, `window_end/0` (exclusive) and `inside_window/0` are
    the `d237-funding/1` window instants (amendment item 4).
  - `operator_approve/2` approves the draft's current revision as reviewed
    (revision id, content digest and the recipient address as read now).
  - `capture_hook!/2` runs a function in the delivering process right
    before or after the capture (the capture adapter's fault seam), e.g. to
    move the clock or suppress the recipient immediately before capture. It
    returns a fresh ref, and every run of the phase is reported as
    attempt-tagged messages (`CaptureHook`).
  - The capture-boundary oracles (D-237 S4 proposal r3 sections 5.2-5.3,
    Codex 4c72c150 and 6b79bfb3): `refused_attempt!/4` for a typed business
    refusal and `propagated_attempt!/3` for a propagated failure. Each runs
    one inline drain with its hook and the boundary observer bound to this
    operation and attempt, and fails at a fixed step marker
    (`"S4-ORACLE ..."`). `rejected_at!/2` asserts that an oracle rejects at
    exactly one marker. `direct_refusal/2` and `outcome/1` keep struct
    names only, never an error value.
  """

  import ExUnit.Assertions

  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Outreach
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.PrototypeFixtures

  @capture SdrAgent.Outreach.Changes.PrototypeCapture
  @hook SdrAgent.PrototypeOutreachFixtures.CaptureHook
  # Proposed (proposal r3 section 3.1): named as an atom only, so the RED
  # head compiles without it.
  @refused SdrAgent.Outreach.Errors.CaptureRefused
  @worker "SdrAgent.Outreach.DeliveryWorker"
  # The synthetic raw-detail markers; the recipient and its domain are added
  # per context.
  @raw_markers [
    "SELECT",
    "42P01",
    "undefined_table",
    "suppressions",
    "Postgrex",
    "#Ash.Query<",
    "%Ash.Query{",
    "#Ash.Filter<",
    "%Ash.Filter{"
  ]

  @window_start ~U[2026-10-28 02:38:32.000000Z]
  @window_end ~U[2026-11-07 07:00:00.000000Z]
  # 11:00 in the demo campaign's America/Denver, outside its quiet hours.
  @inside ~U[2026-10-29 17:00:00.000000Z]

  @doc "The inclusive start of the `d237-funding/1` window."
  def window_start, do: @window_start

  @doc "The exclusive end of the `d237-funding/1` window."
  def window_end, do: @window_end

  @doc "A working-hours instant inside the window."
  def inside_window, do: @inside

  @doc "See the moduledoc."
  def prototype_drafted!(opts \\ []) do
    {key, opts} = Keyword.pop(opts, :key, "01")
    fixture = SdrAgent.PrototypeCase.bound!(Keyword.merge(opts, enter_runtime: false))
    ctx = demo!(fixture)
    drafted = OutreachFixtures.drafted!(ctx, key)
    contact = OutreachFixtures.contact!(ctx, drafted.lead)
    enter_window!(fixture)

    ctx
    |> Map.merge(drafted)
    |> Map.merge(%{
      fixture: fixture,
      operator: fixture.actor,
      anchor: fixture.anchor,
      contact: contact
    })
  end

  @doc """
  Seeds the demo data set into the singleton tenant (the bound one when a
  prototype is bound; with `nil`, ordinary data only, no binding); returns
  the SDRCase-shaped context.
  """
  def demo!(fixture_or_nil) do
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    ExUnit.Callbacks.on_exit(&Clock.unfreeze/0)
    assert match?({:ok, _}, Seed.run()), "the demo seed failed"
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()

    if fixture_or_nil,
      do: assert(fixture_or_nil.tenant.id == tenant_id, "the demo seed used another tenant")

    {:ok, tenant} =
      Ash.get(SdrAgent.Audit.Tenant, tenant_id, SdrAgent.Audit.Kernel.opts(tenant_id))

    seeder = Actor.system(:seeder, tenant_id, "test")
    [admin | _] = Fixtures.users()
    {:ok, admin} = Accounts.get_user(admin.id, actor: seeder)

    %{
      tenant: tenant,
      admin: admin,
      agent: Actor.system(:agent_runtime, tenant_id),
      aud: Actor.system(:auditor_cli, tenant_id),
      campaign_id: Fixtures.campaign().id
    }
  end

  @doc "Enters prototype runtime with the fixture's snapshot and freezes the clock inside the window."
  def enter_window!(fixture, at \\ @inside) do
    result = PrototypeFixtures.enter_runtime(fixture.snapshot)
    assert result == :ok, "entering prototype runtime failed: #{inspect(result)}"
    Clock.freeze(at)
    :ok
  end

  @doc "The reviewed approval input for the draft's current revision, read now."
  def reviewed(ctx, draft) do
    draft = OutreachFixtures.draft!(ctx, draft)
    revision = OutreachFixtures.revision!(ctx, draft.current_revision_id)
    {draft, OutreachFixtures.approval_input(revision)}
  end

  @doc "Approves `draft`'s current revision, exactly as reviewed now, as the operator."
  def operator_approve(ctx, draft) do
    {draft, input} = reviewed(ctx, draft)
    Outreach.approve(draft, input, actor: ctx.operator)
  end

  @doc """
  Runs `fun.(operation)` in the delivering process at capture `phase` and
  returns the registration's fresh ref. Each run of the phase sends
  attempt-tagged messages for that ref (`CaptureHook`).
  """
  def capture_hook!(phase, fun) when phase in [:before_capture, :after_capture] do
    OutreachFixtures.put_env!(:capture_faults, @hook)
    ref = make_ref()
    Process.put({@hook, phase}, {ref, fun})
    ref
  end

  @doc """
  Runs one inline delivery drain (`OutreachFixtures.deliver!/0`) with `fun`
  registered at `:before_capture` under a fresh ref.

  When the hook runs for an operation, it first arms, for exactly that
  operation and attempt:
  - the boundary observer (`{PrototypeCapture, :observer}` =
    `%{ref, op_id, attempt}`);
  - each `opts[:arm]` seam (`inject:` or `fault:`), as its spec merged
    with `%{op_id, attempt}`.

  Then it runs `fun`. Every registration is removed in the calling process
  on every exit, restoring any prior value.

  Returns `{ref, drained}`. `drained` is `{:ok, drain counts}`, or
  `{:raised, exception module}` when the drain itself raised; only the
  module is kept (Codex 1fabb2d3 R1). An ExUnit assertion inside a hook
  is re-raised unchanged.
  """
  def with_capture!(fun, opts \\ []) do
    arm = Keyword.get(opts, :arm, [])
    seams = Enum.map(arm, &{@capture, elem(&1, 0)})
    keys = [{@hook, :before_capture}, {@capture, :observer} | seams]
    prior = Map.new(keys, &{&1, Process.get(&1)})
    OutreachFixtures.put_env!(:capture_faults, @hook)
    ref = make_ref()

    armed = fn operation ->
      bound = %{op_id: operation.id, attempt: operation.attempt_count}
      Process.put({@capture, :observer}, Map.put(bound, :ref, ref))
      Enum.each(arm, fn {kind, spec} -> Process.put({@capture, kind}, Map.merge(spec, bound)) end)
      fun.(operation)
    end

    Process.put({@hook, :before_capture}, {ref, armed})

    try do
      {ref, drain()}
    after
      Enum.each(prior, fn {key, value} -> restore_key(key, value) end)
    end
  end

  defp drain do
    {:ok, OutreachFixtures.deliver!()}
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> {:raised, error.__struct__}
  end

  @doc """
  Runs `fun` with the test-build boundary seam `kind` (`:inject` or
  `:fault`; proposal r3 section 5.1) armed as `scope` for one operation and
  attempt, and removes it in the calling process on every exit, restoring
  any prior value.
  """
  def with_seam(kind, %{ref: _, op_id: _, attempt: _} = scope, fun)
      when kind in [:inject, :fault] do
    key = {@capture, kind}
    prior = Process.get(key)
    Process.put(key, scope)

    try do
      fun.()
    after
      restore_key(key, prior)
    end
  end

  defp restore_key(key, nil), do: Process.delete(key)
  defp restore_key(key, value), do: Process.put(key, value)

  @doc """
  Every message tagged with `ref` (and nothing else), in arrival order, as
  value-free tuples:
  - from `CaptureHook`: `{:entered, phase, op_id, attempt}` and
    `{:returned, phase, op_id, attempt, :ok | :fault}`;
  - from the boundary's test-build seams: `{:refused, op_id, attempt, code}`,
    `{:injected, op_id, attempt, stage}` and
    `{:fault_raised, op_id, attempt, point}`.
  """
  def messages(ref), do: collect(ref, [])

  defp collect(ref, acc) do
    receive do
      {@hook, ^ref, :entered, phase, id, attempt} ->
        collect(ref, [{:entered, phase, id, attempt} | acc])

      {@hook, ^ref, :returned, phase, id, attempt, tag} ->
        collect(ref, [{:returned, phase, id, attempt, tag} | acc])

      {@capture, ^ref, :refused, id, attempt, code} ->
        collect(ref, [{:refused, id, attempt, code} | acc])

      {@capture, ^ref, :injected, id, attempt, stage} ->
        collect(ref, [{:injected, id, attempt, stage} | acc])

      {@capture, ^ref, :fault_raised, id, attempt, point} ->
        collect(ref, [{:fault_raised, id, attempt, point} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Events of `type` in `tenant` (kernel read), oldest first."
  def events_of(tenant, type), do: SdrAgent.AuditCase.events_of_type(tenant, type)

  @doc """
  Asserts that a refused capture of `delivery` wrote nothing: no captured,
  accepted or delivered receipt, no such `outreach.delivery.receipt_recorded`
  event, and the delivery neither accepted nor delivered.
  """
  def no_capture!(ctx, delivery) do
    written = [:captured, :accepted, :delivered]
    kinds = ctx |> OutreachFixtures.receipts!(delivery) |> Enum.map(& &1.kind)

    refute Enum.any?(kinds, &(&1 in written)),
           "a refused capture recorded a receipt: #{inspect(kinds)}"

    recorded =
      ctx.tenant
      |> events_of("outreach.delivery.receipt_recorded")
      |> Enum.filter(&(&1.payload["changes"]["kind"] in Enum.map(written, fn k -> "#{k}" end)))

    assert recorded == [], "a refused capture recorded #{length(recorded)} receipt event(s)"

    state = OutreachFixtures.outreach!(ctx, delivery).state
    refute state in [:accepted, :delivered], "a refused capture left the delivery #{state}"
  end

  @doc """
  The typed business refusal oracle (proposal r3 section 5.3). It runs one
  inline drain of `delivery` with `fun` at `:before_capture`
  (`with_capture!/1`) and requires, in this order, each failing at its own
  fixed marker:

  1. `"S4-ORACLE refused: prerequisites"`: the operation is claimable and
     has a job;
  2. `"S4-ORACLE refused: reach"`: exactly one before_capture run for this
     operation and attempt, returning `:ok`;
  3. `"S4-ORACLE refused: protocol"`: the drain itself did not raise; the
     worker returned a supported outcome (Codex 1fabb2d3 R1);
  4. `"S4-ORACLE refused: no typed refusal"`: exactly one boundary
     observation `{:refused, op, attempt, code}`;
  5. `"S4-ORACLE refused: outcome"`: the operation's only job completed on
     attempt 1 with no error; the operation is failed_permanent with
     `last_error` `%{"reason" => code}`; the draft failed;
  6. `"S4-ORACLE refused: capture written"`: no captured, accepted or
     delivered receipt or receipt event.

  `opts[:arm]` is passed to `with_capture!/2`. `opts[:after_drain]` runs in
  the calling process right after the drain, before any check (for example,
  restoring a synthetic fault). Nothing is rescued except
  the drain's own raise, of which only the module is kept and asserted.
  """
  def refused_attempt!(ctx, delivery, code, fun \\ fn _operation -> :ok end, opts \\ []) do
    attempt = prerequisites!(ctx, delivery, "S4-ORACLE refused: prerequisites")
    {ref, drained} = with_capture!(fun, opts)
    Keyword.get(opts, :after_drain, fn -> :ok end).()
    seen = messages(ref)
    step!(reach(seen) == expected_reach(delivery, attempt, :ok), "S4-ORACLE refused: reach")
    step!(match?({:ok, _counts}, drained), "S4-ORACLE refused: protocol")

    step!(
      observed(seen) == [{:refused, delivery.id, attempt, code}],
      "S4-ORACLE refused: no typed refusal"
    )

    op = OutreachFixtures.outreach!(ctx, delivery)
    draft = OutreachFixtures.outreach!(ctx, %Outreach.Draft{id: op.draft_id})

    step!(
      jobs(delivery.id) == [{"completed", 1, 0}] and op.state == :failed_permanent and
        op.last_error == %{"reason" => Atom.to_string(code)} and draft.status == :failed,
      "S4-ORACLE refused: outcome"
    )

    step!(nothing_captured?(ctx, delivery), "S4-ORACLE refused: capture written")
  end

  @doc """
  The propagated-failure oracle (proposal r3 section 5.3). It has the same
  drain, prerequisites (`"S4-ORACLE propagated: prerequisites"`) and reach
  (`"S4-ORACLE propagated: reach"`) steps as `refused_attempt!/4`, then:

  - `"S4-ORACLE propagated: protocol"`: the drain itself did not raise; the
    worker returned a supported outcome (Codex 1fabb2d3 R1);
  - `"S4-ORACLE propagated: typed refusal observed"`: no boundary
    observation for this ref;
  - `"S4-ORACLE propagated: outcome"`: the operation's only job is
    retryable on attempt 1 with one error. Its rendered error's first line
    is exactly the worker boundary's sanitized line for `opts[:class]`
    (default `Ash.Error.Unknown`), and no marker (`@raw_markers`, the
    recipient and its domain) appears anywhere in it. The text is read,
    never printed. The operation stays attempting on this attempt;
  - `"S4-ORACLE propagated: capture written"`.

  `opts[:arm]` and `opts[:after_drain]` are as in `refused_attempt!/5`. It
  does not, and must not,
  tell a lossy database failure from a programming error.
  """
  def propagated_attempt!(ctx, delivery, fun, opts \\ []) do
    class = Keyword.get(opts, :class, Ash.Error.Unknown)
    attempt = prerequisites!(ctx, delivery, "S4-ORACLE propagated: prerequisites")
    {ref, drained} = with_capture!(fun, opts)
    Keyword.get(opts, :after_drain, fn -> :ok end).()
    seen = messages(ref)
    step!(reach(seen) == expected_reach(delivery, attempt, :ok), "S4-ORACLE propagated: reach")
    step!(match?({:ok, _counts}, drained), "S4-ORACLE propagated: protocol")
    step!(observed(seen) == [], "S4-ORACLE propagated: typed refusal observed")
    op = OutreachFixtures.outreach!(ctx, delivery)

    step!(
      jobs(delivery.id) == [{"retryable", 1, 1}] and job_error_clean?(ctx, delivery, class) and
        op.state == :attempting and op.attempt_count == attempt,
      "S4-ORACLE propagated: outcome"
    )

    step!(nothing_captured?(ctx, delivery), "S4-ORACLE propagated: capture written")
  end

  @doc """
  Asserts that `fun` (an oracle call) fails with exactly `marker`. A
  failure at any other step, an earlier fixture failure included, does not
  count (Codex 4c72c150 H2).
  """
  def rejected_at!(marker, fun) do
    error = assert_raise(ExUnit.AssertionError, fun)
    assert error.message == marker, "the oracle did not reject at the intended step"
  end

  defp prerequisites!(ctx, delivery, marker) do
    before = OutreachFixtures.outreach!(ctx, delivery)
    step!(before.state in [:pending, :failed_retryable] and jobs(delivery.id) != [], marker)
    before.attempt_count + 1
  end

  defp expected_reach(delivery, attempt, tag),
    do: [
      {:entered, :before_capture, delivery.id, attempt},
      {:returned, :before_capture, delivery.id, attempt, tag}
    ]

  defp reach(seen), do: Enum.filter(seen, &(elem(&1, 0) in [:entered, :returned]))
  defp observed(seen), do: Enum.filter(seen, &(elem(&1, 0) == :refused))

  defp step!(true, _marker), do: :ok
  defp step!(_false, marker), do: flunk(marker)

  # This operation's delivery jobs, oldest first: state, attempt, error count.
  defp jobs(operation_id) do
    %{rows: rows} =
      SdrAgent.Repo.query!(
        "SELECT state, attempt, cardinality(errors) FROM oban_jobs " <>
          "WHERE worker = $1 AND args->>'delivery_operation_id' = $2 ORDER BY id",
        [@worker, operation_id]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  # The complete rendered error of the job's first attempt: its exact first
  # line and no marker anywhere. Read, never printed.
  defp job_error_clean?(ctx, delivery, class) do
    recipient = OutreachFixtures.outreach!(ctx, delivery).recipient_email

    case SdrAgent.Repo.query!(
           "SELECT errors[1]->>'error' FROM oban_jobs " <>
             "WHERE worker = $1 AND args->>'delivery_operation_id' = $2 ORDER BY id",
           [@worker, delivery.id]
         ) do
      %{rows: [[text]]} when is_binary(text) ->
        hd(String.split(text, "\n")) == job_error_line(class) and
          not Enum.any?(recipient_markers(recipient), &String.contains?(text, &1))

      _other ->
        false
    end
  end

  @doc """
  The worker boundary's exact first job-error line for a propagated error
  of Ash class `class`: ErrorBoundary returns its SafeMetadata summary
  (error_boundary.ex:63-78), and Oban stores it as a PerformError
  (oban/lib/oban/job.ex:581-589).
  """
  def job_error_line(class),
    do:
      ~s|** (Oban.PerformError) SdrAgent.Outreach.DeliveryWorker failed with {:error, "| <>
        inspect(class) <> ~s|"}|

  @doc "The synthetic raw-detail markers for `ctx`: fixed markers plus the recipient and its domain."
  def markers(ctx), do: recipient_markers(ctx.contact.email)

  defp recipient_markers(email) do
    email = to_string(email)
    [_local, domain] = String.split(email, "@", parts: 2)
    @raw_markers ++ [email, domain]
  end

  defp nothing_captured?(ctx, delivery) do
    written = [:captured, :accepted, :delivered]
    kinds = ctx |> OutreachFixtures.receipts!(delivery) |> Enum.map(& &1.kind)

    events =
      ctx.tenant
      |> events_of("outreach.delivery.receipt_recorded")
      |> Enum.filter(&(&1.payload["changes"]["kind"] in Enum.map(written, fn k -> "#{k}" end)))

    not Enum.any?(kinds, &(&1 in written)) and events == [] and
      OutreachFixtures.outreach!(ctx, delivery).state not in [:accepted, :delivered]
  end

  @doc """
  Runs `delivery` with its capture held by a retryable fault at
  `:before_capture`: the operation is claimed (its rendered message and
  digest stored) and nothing is captured. The hold is bound to this
  operation and attempt (exactly one before_capture run returning the
  fault), and its registration is removed on every exit. Returns the
  stored operation.
  """
  def hold_before_capture!(ctx, delivery) do
    attempt = OutreachFixtures.outreach!(ctx, delivery).attempt_count + 1
    {ref, drained} = with_capture!(fn _operation -> {:error, {:retryable, :held_by_test}} end)
    assert match?({:ok, _counts}, drained), "the held drain raised"

    assert reach(messages(ref)) == expected_reach(delivery, attempt, :fault),
           "the hold did not reach this operation's capture exactly once"

    operation = OutreachFixtures.outreach!(ctx, delivery)

    assert is_binary(operation.rendered_sha256) and operation.state == :failed_retryable,
           "the delivery was not claimed and held"

    no_capture!(ctx, delivery)
    operation
  end

  @doc """
  Records a `captured` receipt for `delivery` directly, as the delivery
  worker (DLV), with its stored operation fields, exactly as the capture
  adapter does; returns the action result.
  """
  def record_captured(ctx, delivery) do
    record_operation(ctx, OutreachFixtures.outreach!(ctx, delivery))
  end

  @doc "As `record_captured/2`, for an operation already loaded (its fields as stored then)."
  def record_operation(ctx, operation) do
    Outreach.record_receipt(
      %{
        delivery_operation_id: operation.id,
        idempotency_key: operation.idempotency_key,
        kind: :captured,
        provider: :capture,
        provider_message_id:
          SdrAgent.Outreach.Delivery.CaptureAdapter.provider_message_id(operation.idempotency_key),
        rendered_sha256: operation.rendered_sha256
      },
      actor: Actor.system(:delivery_worker, ctx.tenant.id)
    )
  end

  @doc """
  The value-free outcome of a direct `captured` record of `operation` (its
  stored fields), as the delivery worker. See `outcome/1`.
  """
  def direct_refusal(ctx, operation), do: outcome(fn -> record_operation(ctx, operation) end)

  @doc """
  Runs `fun` (a receipt record) and keeps struct names only (Codex 99c249b0
  C1, 6d1ead6d):
  - `{:refused, code}` for exactly one typed capture refusal returned in an
    `Ash.Error.Invalid`;
  - `{:returned, :error, class}` for any other returned error;
  - `{:returned, :ok}`, `{:returned, :other}`;
  - `{:raised, module}` for a raise.

  Nothing of an error value is kept, so nothing can be printed.
  """
  def outcome(fun) do
    case fun.() do
      {:error, %Ash.Error.Invalid{errors: [%{__struct__: @refused, code: code}]}} ->
        {:refused, code}

      {:error, %{__struct__: class}} ->
        {:returned, :error, class}

      {:ok, _record} ->
        {:returned, :ok}

      _other ->
        {:returned, :other}
    end
  rescue
    exception -> {:raised, exception.__struct__}
  end

  @doc """
  A private scratch root owned by the calling test: a directory created
  exclusively (`File.mkdir/1`, mode 0700) under the system temp dir, named
  `<prefix>-<128 random bits>`. An existing path is never adopted (the
  test fails instead). On exit it removes only that exact directory, and
  only while it is still a real directory; a path replaced by a symlink or
  a file is left alone.
  """
  def exclusive_root!(prefix) do
    name = "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"
    path = Path.join(System.tmp_dir!(), name)

    case File.mkdir(path) do
      :ok -> :ok
      {:error, reason} -> raise "scratch root #{prefix} was not created exclusively: #{reason}"
    end

    {:ok, %File.Stat{type: :directory}} = File.lstat(path)
    File.chmod!(path, 0o700)
    ExUnit.Callbacks.on_exit(fn -> remove_owned_root(path) end)
    path
  end

  defp remove_owned_root(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> File.rm_rf!(path)
      _gone_or_replaced -> :ok
    end
  end
end

defmodule SdrAgent.PrototypeOutreachFixtures.CaptureHook do
  @moduledoc """
  Capture-adapter fault seam (`config :sdr_agent, :capture_faults`) for S4
  tests. `fault/2` runs the function the test registered for the phase
  (`{ref, fun}`) in the delivering process; Oban's inline drain runs in the
  test process. It returns `:ok` or the function's own
  `{:error, {class, reason}}` fault. It can only change what the test
  controls (the clock, a suppression row) before the real capture runs,
  make the delivery fail before it, or crash the adapter after it.
  """

  @doc """
  Runs the function registered for `phase`, if any, and reports the run to
  the delivering process, tagged with the registration's ref, this
  operation and its attempt:
  - `{CaptureHook, ref, :entered, phase, op_id, attempt}` before the function;
  - `{CaptureHook, ref, :returned, phase, op_id, attempt, :ok | :fault}`
    after it, so a hook that raised is never reported as returned.

  Returns `:ok`; or the function's own `{:error, {class, reason}}` fault,
  which can only make the delivery fail before the capture
  (`hold_before_capture!/2`); or `:crash`, which the adapter raises as a
  crash on that side of the capture (the after-capture crash of the
  lifecycle controls).
  """
  def fault(phase, operation) do
    case Process.get({__MODULE__, phase}) do
      {ref, fun} ->
        send(self(), {__MODULE__, ref, :entered, phase, operation.id, operation.attempt_count})
        fault = fault_of(fun.(operation))
        tag = if fault == :ok, do: :ok, else: :fault

        send(
          self(),
          {__MODULE__, ref, :returned, phase, operation.id, operation.attempt_count, tag}
        )

        fault

      nil ->
        :ok
    end
  end

  defp fault_of({:error, {_class, _reason}} = fault), do: fault
  defp fault_of(:crash), do: :crash
  defp fault_of(_other), do: :ok
end
