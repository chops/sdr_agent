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
    enter!(fixture)

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
  def enter!(fixture, at \\ @inside) do
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

  @doc "Events of `type` in `tenant` (kernel read), oldest first."
  def events_of(tenant, type), do: SdrAgent.AuditCase.events_of_type(tenant, type)
end

defmodule SdrAgent.PrototypeOutreachFixtures.CaptureHook do
  @moduledoc """
  Capture-adapter fault seam (`config :sdr_agent, :capture_faults`) for S4
  tests: `fault/2` runs the function the test registered for the phase in
  the delivering process (Oban's inline drain runs in the test process) and
  returns `:ok`. It can only change what the test controls (the clock, a
  suppression row) before the real capture runs.
  """

  @doc "Runs the registered function for `phase`, if any; always `:ok`."
  def fault(phase, operation) do
    case Process.get({__MODULE__, phase}) do
      nil ->
        :ok

      fun ->
        _ = fun.(operation)
        :ok
    end
  end
end
