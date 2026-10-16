defmodule SdrAgentWeb.AdminLive.ModelComponents do
  @moduledoc """
  Function components of the admin page's model provider card (R0-05,
  `docs/product/r0/r0-05-interface.md`): the C2-02c status lines (desired,
  running and accepting profile, hold and stage, the open switch, the
  publication time, the recorded switch), the provider build lines, the
  `:cleanup_unprovable` banner, the staged switch request and the
  blocked-switch resolver. Rendering only: `SdrAgentWeb.AdminLive` holds
  the status sample, the switch panel and the resolution review these
  components show, and handles every event.

  No guessed values: an `:unknown` field shows "unknown", never the
  registry default, and a held or pending hold never reads as accepting
  calls. Machine values are carried in `data-*` attributes for tests; they
  are observations, never authority.
  """
  use SdrAgentWeb, :html

  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgentWeb.AdminLive.Resolution

  @input "w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm placeholder:text-zinc-400 focus:border-teal-600 focus:outline-none focus:ring-2 focus:ring-teal-600/20 disabled:bg-zinc-50 disabled:text-zinc-400"

  @doc """
  The "Model provider" card: `provider` is one `Runtime.status/0` sample;
  `switch` the open switch-request panel (or nil), `switch_notice` its
  last result, `resolution` the resolver review (or nil) and `switches`
  the stored switches read as the admin (`{:ok, newest_first}` or
  `:unknown`; see `recorded_switch/2`).
  """
  attr :provider, :map, required: true
  attr :switch, :map, default: nil
  attr :switch_notice, :map, default: nil
  attr :resolution, :map, default: nil
  attr :switches, :any, required: true

  def model_card(assigns) do
    target = assigns.resolution && assigns.resolution.switch_id

    assigns =
      assign(assigns,
        target: target,
        recorded: recorded_switch(assigns.switches, target),
        newest: recorded_switch(assigns.switches, nil),
        in_process?: assigns.provider.ledger_observation == :not_applicable,
        blocked_switch: blocked_switch(assigns.provider)
      )

    ~H"""
    <.card id="model-card" title="Model provider">
      <:subtitle>
        The coordinator's last confirmed observations and one sampled reading of the server.
        Status is never authority, and reading it makes no model call.
      </:subtitle>
      <:actions>
        <.ui_button id="refresh-status" size="sm" phx-click="refresh_status">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh status
        </.ui_button>
      </:actions>

      <div
        :if={@provider.stage == :cleanup_unprovable}
        id="cleanup-unprovable"
        role="alert"
        class="mb-4 flex gap-3 rounded-lg border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900"
      >
        <.icon name="hero-shield-exclamation" class="mt-0.5 size-5 shrink-0 text-rose-600" />
        <p>
          A model server's cleanup can't be confirmed. Calls stay paused.
          An operator must check the machine and release the old reaper's lease from a console.
          Normal reconciliation then checks readiness again.
        </p>
      </div>

      <div class="grid gap-x-10 gap-y-4 lg:grid-cols-2">
        <section aria-labelledby="model-profile-heading">
          <h3
            id="model-profile-heading"
            class="text-xs font-medium uppercase tracking-wider text-zinc-500"
          >
            Profile
          </h3>
          <dl class="mt-1 divide-y divide-zinc-100">
            <.field :if={!@in_process?} label="Desired profile">
              <.desired desired={@provider.desired_profile} />
            </.field>
            <.field label="Running profile">
              <.running provider={@provider} in_process?={@in_process?} />
            </.field>
            <.field label="Accepting calls">
              <.accepting provider={@provider} />
            </.field>
            <.field label="Hold">
              <.hold provider={@provider} />
            </.field>
            <.field label="Open switch">
              <.open_switch switch={@provider.switch} />
            </.field>
            <.field label={if @target, do: "Reviewed switch (stored)", else: "Newest stored switch"}>
              <.stored_switch id="stored-switch" recorded={@recorded} target={@target} />
            </.field>
            <.field
              :if={@target && newer?(@newest, @target)}
              label="Newest stored switch"
            >
              <.stored_switch id="latest-switch" recorded={@newest} />
            </.field>
            <.field label="As of">
              <span
                id="status-published-at"
                data-published-at={
                  @provider.published_at && DateTime.to_iso8601(@provider.published_at)
                }
                class="text-xs text-zinc-700"
              >
                <span :if={@provider.published_at}>
                  coordinator published <.timestamp at={@provider.published_at} />
                </span>
                <span :if={is_nil(@provider.published_at) and @in_process?}>
                  not applicable (in-process provider)
                </span>
                <span :if={is_nil(@provider.published_at) and !@in_process?}>unknown</span>
              </span>
            </.field>
          </dl>
          <p class="mt-2 text-xs leading-relaxed text-zinc-500">
            "As of" is when the coordinator last published its ledger and runtime row, not the
            sampling instant; each ledger line shows its own confirmation time. The card follows
            audit events and Refresh status, so it can lag the coordinator until you refresh.
          </p>
        </section>

        <section aria-labelledby="model-build-heading">
          <h3
            id="model-build-heading"
            class="text-xs font-medium uppercase tracking-wider text-zinc-500"
          >
            Provider
          </h3>
          <.provider_lines provider={@provider} />
        </section>
      </div>

      <.switch_section
        :if={!@in_process?}
        provider={@provider}
        switch={@switch}
        notice={@switch_notice}
      />

      <.resolver
        :if={@blocked_switch || @resolution}
        blocked_switch={@blocked_switch}
        review={@resolution}
      />

      <p class="mt-4 text-xs text-zinc-500">
        The deterministic fake is the default; <code>SDR_MODEL_PROVIDER=claude_cli</code>
        selects ClaudeCLI in development only (ADR-0004). Attestation drift on a real
        provider opens a critical attention failure.
      </p>
    </.card>
    """
  end

  @doc "The open switch the status shows as blocked, or nil."
  def blocked_switch(%{switch: %{state: :open, status: :blocked} = switch}), do: switch
  def blocked_switch(_provider), do: nil

  @doc """
  Whether the status allows a switch request: ClaudeCLI, a confirmed
  desired profile and no open switch (section 2).
  """
  def switch_allowed?(%{
        ledger_observation: :valid,
        desired_profile: %{},
        switch: %{state: :none}
      }),
      do: true

  def switch_allowed?(_provider), do: false

  ## The status lines

  attr :desired, :any, required: true

  defp desired(%{desired: %{profile_id: _}} = assigns) do
    ~H"""
    <span
      id="desired-profile"
      data-profile={@desired.profile_id}
      data-source={@desired.source}
      class="text-xs"
    >
      <span class="font-mono text-zinc-900">{@desired.profile_id}</span>
      <span class="text-zinc-500">
        {if @desired.source == :setting, do: "(saved setting)", else: "(default)"}
      </span>
      <span class="block text-zinc-400">
        confirmed <.timestamp at={@desired.confirmed_at} />
      </span>
    </span>
    """
  end

  defp desired(assigns) do
    ~H"""
    <span id="desired-profile" data-profile="unknown" class="text-xs font-medium text-amber-700">
      unknown (no confirmed observation)
    </span>
    """
  end

  attr :provider, :map, required: true
  attr :in_process?, :boolean, required: true

  defp running(assigns) do
    assigns = assign(assigns, :shown, running_profile(assigns.provider, assigns.in_process?))

    ~H"""
    <span id="running-profile" data-profile={@shown} class="text-xs">
      <span class={[
        "font-mono",
        if(@shown in ["unknown", "none"], do: "text-amber-700", else: "text-zinc-900")
      ]}>
        {@shown}
      </span>
      <span class="text-zinc-400">
        {running_note(@provider, @in_process?)}
      </span>
    </span>
    """
  end

  defp running_profile(provider, true), do: to_string(provider.profile_id || "none")
  defp running_profile(%{observed_profile: observed}, false), do: to_string(observed)

  defp running_note(_provider, true), do: "(in-process; not sampled)"
  defp running_note(%{observed_profile: :unknown}, false), do: "(sampled; no consistent reading)"
  defp running_note(%{observed_profile: :none}, false), do: "(sampled; no bound server)"
  defp running_note(_provider, false), do: "(sampled)"

  attr :provider, :map, required: true

  defp accepting(assigns) do
    assigns =
      assign(assigns, :on, assigns.provider.effective_profile || assigns.provider.profile_id)

    ~H"""
    <span
      id="accepting-calls"
      data-accepting={if @provider.effective, do: "yes", else: "no"}
      data-refusal={@provider.refusal}
      class={[
        "block max-w-xs text-xs",
        if(@provider.effective, do: "font-medium text-emerald-700", else: "text-rose-700")
      ]}
    >
      <span :if={@provider.effective}>yes, on {@on}</span>
      <span :if={is_nil(@provider.effective)}>
        <span class="font-medium">no</span>: {Runtime.refusal_message(@provider.refusal)}
      </span>
    </span>
    """
  end

  attr :provider, :map, required: true

  defp hold(assigns) do
    ~H"""
    <span
      id="provider-hold"
      data-hold={@provider.hold}
      data-stage={@provider.stage}
      class={[
        "text-xs",
        if(@provider.hold == :released, do: "text-zinc-700", else: "font-medium text-amber-700")
      ]}
    >
      {hold_words(@provider.hold)}
      <span :if={@provider.stage} class="block font-normal text-zinc-500">
        stage: {stage_words(@provider.stage)}
      </span>
    </span>
    """
  end

  defp hold_words(:held), do: "held: new calls are paused"
  defp hold_words(:pending), do: "pending: the hold is not yet acknowledged; counts as held"
  defp hold_words(:released), do: "released"
  defp hold_words(:not_applicable), do: "not applicable (in-process provider)"
  defp hold_words(_unknown), do: "unknown"

  defp stage_words(:draining), do: "draining calls in progress"
  defp stage_words(:old_stopping), do: "stopping the old server"
  defp stage_words(:candidate_preflight), do: "checking the new profile without a model call"
  defp stage_words(:rollback_preflight), do: "checking the rollback without a model call"
  defp stage_words(:finalizing), do: "finalizing the switch (outcome not yet definite)"
  defp stage_words(:settling), do: "settling a resolution (outcome not yet definite)"
  defp stage_words(:cleanup_unprovable), do: "cleanup can't be confirmed"
  defp stage_words(:not_applicable), do: "not applicable"
  defp stage_words(stage), do: humanize(stage)

  attr :switch, :any, required: true

  defp open_switch(%{switch: %{state: :none}} = assigns) do
    ~H"""
    <span id="open-switch" data-state="none" class="text-xs text-zinc-700">
      none (confirmed <.timestamp at={@switch.confirmed_at} />)
    </span>
    """
  end

  defp open_switch(%{switch: %{state: :open}} = assigns) do
    ~H"""
    <span
      id="open-switch"
      data-state={@switch.status}
      data-switch-id={@switch.id}
      class="block max-w-xs text-xs font-medium text-amber-700"
    >
      {open_words(@switch)}
      <span class="block font-normal text-zinc-400">
        confirmed <.timestamp at={@switch.confirmed_at} />
      </span>
    </span>
    """
  end

  defp open_switch(%{switch: :not_applicable} = assigns) do
    ~H"""
    <span id="open-switch" data-state="not_applicable" class="text-xs text-zinc-500">
      not applicable (in-process provider)
    </span>
    """
  end

  defp open_switch(assigns) do
    ~H"""
    <span id="open-switch" data-state="unknown" class="text-xs font-medium text-amber-700">
      unknown (no confirmed observation)
    </span>
    """
  end

  defp open_words(%{status: :blocked} = switch),
    do:
      "#{switch.from_profile_id} → #{switch.to_profile_id}, blocked: " <>
        failure_words(switch.failure_reason)

  defp open_words(switch),
    do: "#{switch.from_profile_id} → #{switch.to_profile_id}, #{switch.status}"

  @doc "A switch's recorded failure reason in words."
  def failure_words(nil), do: "reason not recorded"
  def failure_words("coordinator_restarted"), do: "the coordinator restarted during the switch"
  def failure_words("operation_died"), do: "the switch worker stopped unexpectedly"
  def failure_words("finalization_uncertain"), do: "the switch's finalization is uncertain"
  def failure_words("old_cli_not_quiescent"), do: "earlier CLI work was not confirmed stopped"
  def failure_words("drain_failed"), do: "calls in progress could not be drained"
  def failure_words("candidate_not_ready"), do: "the new profile did not start cleanly"
  def failure_words("rollback_not_ready"), do: "the rollback did not start cleanly"
  def failure_words("rollback_preflight_failed"), do: "the rollback's check failed"
  def failure_words("old_cleanup_unconfirmed"), do: "the old server's cleanup is unconfirmed"
  def failure_words(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  def failure_words(_reason), do: "reason not recorded"

  @doc """
  The stored switch the card shows from `switches` (the actor-authorized
  read, newest first, or `:unknown`): with a `target` (the reviewed
  switch's id) exactly that row, else `:unknown` (a missing target or a
  failed read is never replaced by another row); with no target the newest
  row, `{:ok, nil}` when there is none.
  """
  def recorded_switch(:unknown, _target), do: :unknown
  def recorded_switch({:ok, [newest | _older]}, nil), do: {:ok, newest}
  def recorded_switch({:ok, []}, nil), do: {:ok, nil}

  def recorded_switch({:ok, switches}, target) when is_binary(target) do
    case Enum.find(switches, &(&1.id == target)) do
      nil -> :unknown
      switch -> {:ok, switch}
    end
  end

  def recorded_switch(_unreadable, _target), do: :unknown

  defp newer?({:ok, %{id: id}}, target), do: id != target
  defp newer?(_newest, _target), do: false

  attr :id, :string, required: true
  attr :recorded, :any, required: true
  attr :target, :string, default: nil

  defp stored_switch(%{recorded: {:ok, %{} = switch}} = assigns) do
    assigns = assign(assigns, :switch, switch)

    ~H"""
    <span
      id={@id}
      data-status={@switch.status}
      data-switch-id={@switch.id}
      class="block text-xs text-zinc-700"
    >
      <span class="font-mono">{@switch.from_profile_id} → {@switch.to_profile_id}</span>, {@switch.status}
      <span class="block break-all font-mono text-zinc-500">{@switch.id}</span>
      <span class="block text-zinc-400">
        requested <.timestamp at={@switch.requested_at} /> (the stored record)
      </span>
    </span>
    """
  end

  defp stored_switch(%{recorded: {:ok, nil}} = assigns) do
    ~H"""
    <span id={@id} data-status="none" class="text-xs text-zinc-500">
      none recorded
    </span>
    """
  end

  defp stored_switch(assigns) do
    ~H"""
    <span
      id={@id}
      data-status="unknown"
      data-switch-id={@target}
      class="block text-xs font-medium text-amber-700"
    >
      unknown (the stored switch can't be read)
      <span :if={@target} class="block break-all font-mono font-normal text-zinc-500">
        {@target}
      </span>
    </span>
    """
  end

  ## The provider build lines (unchanged from S10b, R0-02 and C2-02c)

  attr :provider, :map, required: true

  defp provider_lines(assigns) do
    ~H"""
    <dl class="mt-1 divide-y divide-zinc-100">
      <.field label="Configured">
        <span id="model-provider" class="font-medium">{short(@provider.configured)}</span>
      </.field>
      <.field label="Effective">
        <span
          id="effective-provider"
          data-effective={if @provider.effective, do: short(@provider.effective), else: "none"}
          class={[
            "text-xs font-medium",
            if(@provider.effective, do: "text-emerald-700", else: "text-rose-700")
          ]}
        >
          <span :if={@provider.effective}>{short(@provider.effective)}</span>
          <span :if={is_nil(@provider.effective)}>
            none: calls refused ({@provider.refusal})
          </span>
        </span>
      </.field>
      <.field :if={@provider.refusal} label="Refused because">
        <span
          id="provider-refusal"
          data-refusal={@provider.refusal}
          class="block max-w-xs text-xs text-rose-700"
        >
          {Runtime.refusal_message(@provider.refusal)}
        </span>
      </.field>
      <.field label="Module">
        <span class="break-all font-mono text-xs">{inspect(@provider.provider)}</span>
      </.field>
      <.field label="Model">
        <span class="font-mono text-xs">
          <span :if={@provider.model_alias} id="model-alias">{@provider.model_alias}</span>
          <span :if={@provider.model_alias} class="text-zinc-400">→</span>
          <span id="model-id">{@provider.model_id || "—"}</span>
        </span>
      </.field>
      <.field :if={@provider.reviewed_version} label="Reviewed CLI">
        <span id="reviewed-cli-version" class="font-mono text-xs">
          Claude Code {@provider.reviewed_version}
        </span>
      </.field>
      <.field :if={@provider.cli_executable} label="Pinned CLI">
        <span id="pinned-cli-path" class="break-all font-mono text-xs">
          {@provider.cli_executable}
        </span>
        <span
          :if={@provider.reviewed_version}
          id="pinned-cli-version"
          class="block text-xs text-zinc-500"
        >
          Claude Code {@provider.reviewed_version} (the reviewed build)
        </span>
      </.field>
      <.field label="Server">
        <span
          id="provider-server"
          data-status={@provider.server}
          class={[
            "text-xs font-medium",
            if(@provider.server in [:not_running, :blocked],
              do: "text-rose-700",
              else: "text-zinc-700"
            )
          ]}
        >
          {server_label(@provider.server)}
        </span>
      </.field>
      <.field label="Last check">
        <span
          id="model-attestation"
          data-status={@provider.attestation.status}
          class={[
            "text-xs",
            if(@provider.attestation.status == :drift,
              do: "font-medium text-rose-700",
              else: "text-zinc-700"
            )
          ]}
        >
          {attestation_label(@provider.attestation)}
          <span :if={@provider.attestation[:at]} class="block text-zinc-400">
            <.timestamp at={@provider.attestation.at} />
          </span>
        </span>
      </.field>
    </dl>
    """
  end

  defp server_label(:running), do: "running"
  defp server_label(:not_running), do: "not running"

  defp server_label(:blocked),
    do: "blocked: earlier CLI work is not confirmed stopped; calls are refused"

  defp server_label(:not_applicable), do: "in-process (no server)"

  # C2-02c: no consistent sample of the coordinator and its bound server.
  defp server_label(:unknown), do: "unknown: no consistent status sample"

  defp attestation_label(%{status: :not_applicable}), do: "not applicable (deterministic)"
  defp attestation_label(%{status: :not_running}), do: "none (server not running)"
  defp attestation_label(%{status: :unknown}), do: "unknown (no consistent status sample)"

  defp attestation_label(%{status: :pending} = attestation),
    do: "pending: checked at the first call" <> launcher_note(attestation)

  defp attestation_label(%{status: :attested} = attestation),
    do: "attested #{attestation.model} on Claude Code #{attestation.version}"

  defp attestation_label(%{status: :drift} = attestation),
    do:
      "drift: #{attestation.reason}; calls are refused until the reviewed configuration is restored"

  defp launcher_note(%{command?: false}), do: " (llm-proxy-shim not found)"
  defp launcher_note(_attestation), do: ""

  @doc "A module's last segment, or \"not configured\"."
  def short(nil), do: "not configured"
  def short(module) when is_atom(module), do: module |> Module.split() |> List.last()

  ## Requesting a switch (section 2)

  attr :provider, :map, required: true
  attr :switch, :map, default: nil
  attr :notice, :map, default: nil

  defp switch_section(assigns) do
    assigns = assign(assigns, :allowed?, switch_allowed?(assigns.provider))

    ~H"""
    <section
      id="switch-section"
      aria-labelledby="switch-heading"
      class="mt-5 border-t border-zinc-100 pt-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 id="switch-heading" class="text-sm font-semibold text-zinc-900">Model profile</h3>
          <p class="text-xs text-zinc-500">
            Switching makes no model call. It is staged here and sent only when you confirm.
          </p>
        </div>
        <.ui_button
          :if={@allowed? and is_nil(@switch)}
          id="change-profile"
          size="sm"
          variant="primary"
          phx-click="open_switch"
        >
          <.icon name="hero-arrows-right-left" class="size-4" /> Change model profile
        </.ui_button>
        <span
          :if={unknown_status?(@provider)}
          id="switch-status-unknown"
          class="inline-flex items-center gap-1.5 text-xs font-medium text-amber-700"
        >
          <.icon name="hero-question-mark-circle" class="size-4" /> status unknown; refresh
        </span>
      </div>

      <p
        :if={@notice && @notice.kind == :ok}
        id="switch-result"
        role="status"
        class="mt-3 flex items-start gap-2 rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900"
      >
        <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0" />
        <span>{@notice.text}</span>
      </p>
      <p
        :if={@notice && @notice.kind == :error}
        id="switch-error"
        role="alert"
        class="mt-3 flex items-start gap-2 rounded-lg border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
        <span>{@notice.text}</span>
      </p>

      <.switch_panel :if={@switch} switch={@switch} />
    </section>
    """
  end

  defp unknown_status?(%{desired_profile: :unknown}), do: true
  defp unknown_status?(%{switch: :unknown}), do: true
  defp unknown_status?(_provider), do: false

  attr :switch, :map, required: true

  defp switch_panel(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <div
      id="switch-panel"
      class="mt-3 rounded-xl border border-zinc-200 bg-zinc-50/60 p-4 transition sm:p-5"
    >
      <div
        :if={@switch.stale}
        id="switch-stale"
        role="alert"
        class="mb-3 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-rose-200 bg-rose-50 p-3"
      >
        <p class="text-sm text-rose-800">
          <.icon name="hero-exclamation-triangle" class="size-4" /> {@switch.stale}
        </p>
        <.ui_button id="reload-switch" size="sm" phx-click="reload_switch">
          <.icon name="hero-arrow-path" class="size-4" /> Reload
        </.ui_button>
      </div>

      <.form
        :if={@switch.step == :choose}
        for={%{}}
        as={:switch}
        id="switch-form"
        phx-submit="review_switch"
        class="space-y-3"
      >
        <p class="text-sm text-zinc-700">
          Currently <span class="font-mono">{@switch.from}</span>
          (setting revision {@switch.revision}). Choose the profile to switch to.
        </p>
        <p :if={@switch.choice_error} id="switch-choice-error" class="text-sm text-rose-700">
          {@switch.choice_error}
        </p>
        <div class="max-w-xs">
          <.input
            type="select"
            id="switch-target"
            name="switch[to_profile_id]"
            label="Switch to"
            value={nil}
            options={Enum.map(@switch.choices, &{to_string(&1), to_string(&1)})}
            class={@input}
          />
        </div>
        <div class="flex flex-wrap gap-2">
          <.ui_button type="submit" size="sm" variant="primary">Review the switch</.ui_button>
          <.ui_button
            id="cancel-switch"
            type="button"
            size="sm"
            variant="ghost"
            phx-click="cancel_switch"
          >
            Cancel
          </.ui_button>
        </div>
      </.form>

      <div
        :if={@switch.step == :review}
        id="switch-review"
        role="alertdialog"
        aria-labelledby="switch-review-title"
        data-from={@switch.review.from}
        data-to={@switch.review.to_profile_id}
        data-revision={@switch.review.expected_revision}
        class="space-y-2"
      >
        <p id="switch-review-title" class="text-sm font-semibold text-zinc-900">
          Switch from {@switch.review.from} to {@switch.review.to_profile_id}.
        </p>
        <p class="text-sm text-zinc-700">
          Calls in progress finish first. While the switch runs, new calls are paused.
          The new profile is checked without a model call. If it can't start cleanly, the app
          returns to {@switch.review.from}, or blocks the switch for you to resolve.
        </p>
        <p class="text-xs text-zinc-500">
          Applies to setting revision {@switch.review.expected_revision}.
        </p>
        <div class="flex flex-wrap gap-2 pt-1">
          <.ui_button
            id="confirm-switch"
            size="sm"
            variant="primary"
            phx-click="confirm_switch"
            phx-disable-with="Requesting…"
          >
            Request the switch
          </.ui_button>
          <.ui_button id="cancel-switch" size="sm" variant="ghost" phx-click="cancel_switch">
            Cancel
          </.ui_button>
        </div>
      </div>
    </div>
    """
  end

  ## Resolving a blocked switch (section 3)

  attr :blocked_switch, :map, default: nil
  attr :review, :map, default: nil

  defp resolver(assigns) do
    assigns =
      assign(assigns,
        can_open?:
          not is_nil(assigns.blocked_switch) and
            (is_nil(assigns.review) or assigns.review.state in [:facts, :terminal])
      )

    ~H"""
    <section
      id="resolver"
      aria-labelledby="resolver-heading"
      class="mt-5 border-t border-zinc-100 pt-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 id="resolver-heading" class="text-sm font-semibold text-zinc-900">
            Blocked switch
          </h3>
          <p class="text-xs text-zinc-500">
            A blocked switch needs your attested resolution. It releases no lease and no hold.
          </p>
        </div>
        <.ui_button
          :if={@can_open?}
          id="resolve-blocked"
          size="sm"
          variant="danger"
          phx-click="open_resolution"
        >
          <.icon name="hero-wrench-screwdriver" class="size-4" /> Resolve blocked switch
        </.ui_button>
      </div>

      <.review :if={@review} review={@review} />
    </section>
    """
  end

  attr :review, :map, required: true

  defp review(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <div
      id="resolution-review"
      data-state={@review.state}
      data-attestation-id={@review.attestation_id}
      aria-busy={to_string(@review.state == :submitting)}
      class="mt-3 rounded-xl border border-zinc-200 bg-zinc-50/60 p-4 sm:p-5"
    >
      <p
        :if={@review.facts_changed?}
        id="resolution-facts-changed"
        role="alert"
        class="mb-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm font-medium text-amber-900"
      >
        <.icon name="hero-exclamation-triangle" class="size-4" /> the facts changed; review again
      </p>
      <p
        :if={@review.error}
        id="resolution-error"
        role="alert"
        class="mb-3 rounded-lg border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800"
      >
        {@review.error}
      </p>

      <.facts :if={@review.facts} facts={@review.facts} />

      <div :if={@review.state in [:editing, :submitting, :uncertain]} class="mt-4">
        <p class="text-xs font-medium uppercase tracking-wider text-zinc-500">The statement</p>
        <blockquote
          id="resolution-statement"
          class="mt-1 border-l-2 border-amber-400 pl-3 text-sm text-zinc-800"
        >
          {Resolution.statement()}
        </blockquote>
      </div>

      <.form
        :if={@review.state in [:editing, :submitting]}
        for={%{}}
        id="resolution-form"
        phx-change="change_resolution"
        phx-submit="confirm_resolution"
        class="mt-4 space-y-2"
      >
        <.input
          id="resolution-confirmation"
          name="resolution_confirmation"
          value={nil}
          label="To confirm, type the word STOPPED, one space and the switch id"
          autocomplete="off"
          spellcheck="false"
          disabled={@review.state != :editing}
          class={[@input, "font-mono"]}
        />
        <div class="flex flex-wrap items-center gap-3">
          <.ui_button
            id="confirm-resolution"
            type="submit"
            size="sm"
            variant="danger"
            disabled={@review.state != :editing or not @review.exact?}
          >
            Record the resolution
          </.ui_button>
          <span
            :if={@review.state == :submitting}
            id="resolution-progress"
            role="status"
            class="inline-flex items-center gap-1.5 text-xs text-zinc-600"
          >
            <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Submitting…
          </span>
        </div>
      </.form>

      <div
        :if={@review.result && @review.state in [:uncertain, :terminal]}
        id="resolution-result"
        data-outcome={@review.result.outcome}
        role="status"
        class={[
          "mt-4 rounded-lg border p-3 text-sm",
          result_tone(@review.result.outcome)
        ]}
      >
        {@review.result.message}
      </div>

      <div :if={@review.state == :uncertain} class="mt-3">
        <.ui_button id="check-again" size="sm" variant="primary" phx-click="check_again">
          <.icon name="hero-arrow-path" class="size-4" /> Check again
        </.ui_button>
      </div>
    </div>
    """
  end

  defp result_tone("recorded"), do: "border-emerald-200 bg-emerald-50 text-emerald-900"
  defp result_tone("uncertain"), do: "border-amber-200 bg-amber-50 text-amber-900"
  defp result_tone(_refused), do: "border-rose-200 bg-rose-50 text-rose-800"

  attr :facts, :map, required: true

  defp facts(assigns) do
    ~H"""
    <div id="resolution-facts" class="space-y-3">
      <div id="resolution-switch" data-switch-id={@facts.switch.id} class="text-sm text-zinc-800">
        <p>
          Switch <span class="font-mono text-xs">{@facts.switch.id}</span>: <span class="font-mono">{@facts.switch.from} → {@facts.switch.to}</span>,
          blocked: {failure_words(@facts.switch.reason)}.
        </p>
        <p class="text-xs text-zinc-500">
          Requested <.timestamp at={@facts.switch.requested_at} /> by {@facts.switch.requested_by}.
        </p>
      </div>

      <div>
        <p class="text-xs font-medium uppercase tracking-wider text-zinc-500">
          Covered starts (every start in this range)
        </p>
        <div class="mt-1 overflow-x-auto">
          <table class="w-full min-w-[40rem] text-left text-xs">
            <thead class="uppercase tracking-wider text-zinc-500">
              <tr>
                <th scope="col" class="py-1.5 pr-3 font-medium">Generation</th>
                <th scope="col" class="py-1.5 pr-3 font-medium">Reason</th>
                <th scope="col" class="py-1.5 pr-3 font-medium">Profile</th>
                <th scope="col" class="py-1.5 pr-3 font-medium">Status</th>
                <th scope="col" class="py-1.5 pr-3 font-medium">Pid</th>
                <th scope="col" class="py-1.5 pr-3 font-medium">Node</th>
                <th scope="col" class="py-1.5 font-medium">Reaper</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100 font-mono text-zinc-800">
              <tr
                :for={start <- @facts.starts}
                id={"covered-start-#{start.generation}"}
                data-start-id={start.id}
              >
                <td class="py-1.5 pr-3 tabular-nums">{start.generation}</td>
                <td class="py-1.5 pr-3">{start.reason}</td>
                <td class="py-1.5 pr-3">{start.profile_id}</td>
                <td class="py-1.5 pr-3">{start.status}</td>
                <td class="py-1.5 pr-3"><.recorded value={start.pid} /></td>
                <td class="py-1.5 pr-3 break-all"><.recorded value={start.node} /></td>
                <td class="py-1.5"><.recorded value={start.reaper_pid} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <p class="text-sm text-zinc-800">
        Lease:
        <span id="resolution-lease-kind" data-kind={@facts.lease_kind} class="font-medium">
          {Resolution.lease_kind_words(@facts.lease_kind)}
        </span>
      </p>
    </div>
    """
  end

  attr :value, :any, required: true

  defp recorded(assigns) do
    ~H"""
    <span :if={@value}>{@value}</span>
    <span :if={is_nil(@value)} class="font-sans text-zinc-400">not recorded</span>
    """
  end
end
