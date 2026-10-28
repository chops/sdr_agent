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
    move the clock or suppress the recipient immediately before capture.
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

  @doc "Runs `fun.(operation)` in the delivering process at capture `phase`."
  def capture_hook!(phase, fun) when phase in [:before_capture, :after_capture] do
    OutreachFixtures.put_env!(:capture_faults, SdrAgent.PrototypeOutreachFixtures.CaptureHook)
    Process.put({SdrAgent.PrototypeOutreachFixtures.CaptureHook, phase}, fun)
    :ok
  end

  @doc """
  Runs `fun` (an inline delivery drain) and returns the full inspection of
  the exception it raised, or the string `"no exception raised"` (a binary,
  so `=~` fails as an assertion, never a crash). A refused capture fails
  closed on the existing failure path (the worker raises); the caller
  asserts the exact named refusal code inside it, never a crash alone.
  """
  def raised(fun) do
    fun.()
    "no exception raised"
  rescue
    error -> inspect(error, limit: :infinity, printable_limit: :infinity)
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
  Runs `drain` (the inline delivery drain) for `delivery`, which must fail
  closed at the capture (Codex f9a45a0c R3): the delivering process reached
  `:before_capture` (`CaptureHook`), the drain reports no success and at
  least one failure, and the delivery's own job (`DeliveryWorker`, this
  operation) holds only the worker error boundary's sanitized Ash error
  summary (`SdrAgent.Workers.ErrorBoundary`): no refusal code, recipient or
  SQL. Nothing is rescued: any exception, an ExUnit failure included,
  propagates.
  """
  def failed_closed!(delivery, drain) do
    OutreachFixtures.put_env!(:capture_faults, SdrAgent.PrototypeOutreachFixtures.CaptureHook)
    counts = drain.()

    assert match?(%{success: 0}, counts) and
             Map.get(counts, :failure, 0) + Map.get(counts, :discard, 0) > 0,
           "the delivery did not fail: #{inspect(counts)}"

    assert_received {SdrAgent.PrototypeOutreachFixtures.CaptureHook, :reached, :before_capture},
                    "the worker never reached the capture"

    %{rows: rows} =
      SdrAgent.Repo.query!(
        "SELECT state, errors::text FROM oban_jobs WHERE worker = $1 AND " <>
          "args->>'delivery_operation_id' = $2",
        ["SdrAgent.Outreach.DeliveryWorker", delivery.id]
      )

    assert [[state, errors]] = rows
    assert state in ["retryable", "discarded"], "the delivery job is #{state}"

    assert errors =~ ~r/Ash\.Error\.(Unknown|Invalid)/,
           "no sanitized Ash error summary in the job: #{errors}"

    for raw <- ["prototype_", "SELECT", "42P01", to_string(delivery.recipient_email)] do
      refute errors =~ raw, "the job error carries raw detail"
    end

    :ok
  end

  @doc """
  Runs `delivery` with its capture held by a retryable fault at
  `:before_capture`: the operation is claimed (its rendered message and
  digest stored) and nothing is captured. Returns the stored operation.
  """
  def hold_before_capture!(ctx, delivery) do
    capture_hook!(:before_capture, fn _operation -> {:error, {:retryable, :held_by_test}} end)
    OutreachFixtures.deliver!()
    Process.delete({SdrAgent.PrototypeOutreachFixtures.CaptureHook, :before_capture})
    operation = OutreachFixtures.outreach!(ctx, delivery)
    assert is_binary(operation.rendered_sha256), "the delivery was not claimed"
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
  The refusal text of a direct `captured` receipt record for `delivery`, as
  the delivery worker (DLV), with its stored operation fields: the full
  inspection of the raised or returned error, or `"recorded"` when the
  receipt was recorded.
  """
  def capture_refusal(ctx, delivery), do: refusal_of(fn -> record_captured(ctx, delivery) end)

  @doc "The refusal text of `record` (a direct receipt record): see `capture_refusal/2`."
  def refusal_of(record) do
    case record.() do
      {:ok, _receipt} -> "recorded"
      {:error, error} -> inspect(error, limit: :infinity, printable_limit: :infinity)
    end
  rescue
    error -> inspect(error, limit: :infinity, printable_limit: :infinity)
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
  tests: `fault/2` runs the function the test registered for the phase in
  the delivering process (Oban's inline drain runs in the test process),
  records that the phase was reached, and returns `:ok` or the function's
  own `{:error, {class, reason}}` fault. It can only change what the test
  controls (the clock, a suppression row) before the real capture runs, or
  make the delivery fail before it.
  """

  @doc """
  Runs the registered function for `phase`, if any, and records that the
  delivering process reached `phase` (a `{CaptureHook, :reached, phase}`
  message to itself). Returns `:ok`, or the function's own
  `{:error, {class, reason}}` fault, which can only make the delivery fail
  before the capture (`hold_before_capture!/2`).
  """
  def fault(phase, operation) do
    send(self(), {__MODULE__, :reached, phase})

    case Process.get({__MODULE__, phase}) do
      nil -> :ok
      fun -> fault_of(fun.(operation))
    end
  end

  defp fault_of({:error, {_class, _reason}} = fault), do: fault
  defp fault_of(_other), do: :ok
end
