defmodule SdrAgent.AI.ModelProvider.Runtime do
  @moduledoc """
  The runtime-selected model provider (ADR-0004 runtime-selection
  amendment, Q0.1).

  `config/runtime.exs` reads `SDR_MODEL_PROVIDER` into `config :sdr_agent,
  :model_provider`: the deterministic `Fake` unless the value is
  `claude_cli` in development (refused in test and prod, so tests stay
  hermetic and ClaudeCLI stays personal and local). This module turns that
  choice into:

    * `children/0` — the supervision children: when ClaudeCLI is
      selected, the C2-02b2α profile tree, whose coordinator runs exactly
      one `SdrAgent.AI.ModelProvider.ClaudeCLI` server, registered as
      `ClaudeCLI.server/0`, with the configured `:timeout` and the app's
      pinned CLI `:executable` (`SDR_CLAUDE_CLI_BIN`, R0-02;
      `server_options/1`), at the setting's desired profile or
      `desired_profile/0` (R0-03); none for the Fake. One server serialises
      every call (concurrency 1, ADR-0004 / ADR-0005 C8).
    * `resolve/1` — a run's model options (`:provider`,
      `:provider_options`) with the provider made explicit and, for
      ClaudeCLI, the named server injected — the one validated selection
      used by `SdrAgent.SDR.AgentWorker`, `SdrAgent.SDR.ReplyWorker` and
      the public `SdrAgent.AI.ModelProvider.complete/2`. An absent or
      unhealthy ClaudeCLI is a typed refusal before any reservation:
      `{:error, :provider_not_running}`, `:provider_held` (the coordinator
      holds the server's launches, C2-02b2α), `:provider_not_quiescent`
      (admission closed), `:llm_proxy_shim_not_found` or
      `:pinned_cli_unavailable` (no pin, or the pinned build is missing or
      is not the reviewed identity) or `:real_model_staged` (R0-02 staging:
      no ordinary real call until R0-03, C9 and R0-07 land; only a test
      build's injected launcher passes) — never a raise and never a silent
      fallback to the Fake or to `claude` on `PATH`. Per-call init attestation stays
      mandatory; this health check is in addition to it. Its checks are one
      pure function of a server view, shared with `status/0`.
    * `status/0` — what the Admin page shows (C2-02c,
      `docs/product/r0/c2-02c-interface.md` sections 2, 2a and 2b): the
      coordinator's **last confirmed ledger observations** (`desired_profile`,
      `switch`, `published_at`; `ledger_observation`) plus **one bracketed
      runtime sample** (`observed_profile`, `hold`, `stage`, the
      eligibility as `effective`, `refusal` and `effective_profile`,
      `server` and the attestation; `runtime_observation`). An attempt
      reads the coordinator's row (C1, `Coordinator.sample/0`), the bound
      server's status table once (S1, `ClaudeCLI.table_sample/1`),
      computes the eligibility from that view, pin file metadata and the
      staging configuration, then re-reads the server (S2) and the row
      (C2); it is consistent when C1 = C2, S1 = S2 and every owner matches
      its binding, and is retried at most three times. No positive value is
      ever taken from parts of different attempts; a missing server is
      `:none` only when the coordinator positively binds none and no
      process holds the name; `profile_id` and the model fields follow the
      known observed profile, then the confirmed desired one, else nil
      (never the registry default). It makes no database query, sends
      nothing to the coordinator or the server, writes nothing and never
      calls `resolve/1`. **Status is never authority:** admission stays
      with the reservation and launch fencing. Also the configured
      provider, the reviewed CLI version and the configured pinned CLI path
      (`cli_executable`). No secret is read and no CLI is run. Test builds
      only (`@test_seams`): each step of an attempt emits `[:sdr_agent,
      :runtime_status, :sample]` (`%{}`, `%{point: :c1 | :s1 | :eligibility
      | :s2 | :c2, attempt: 1..3}`) in the caller; other builds compile it
      out.
    * `desired_profile/0` — the coordinator's confirmed desired profile
      (`{:ok, %{profile_id, source, confirmed_at}}`), `{:error, :unknown}`,
      or `:not_applicable` for an in-process provider.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @attempts 3

  @doc "The selected provider module (`config :sdr_agent, :model_provider`)."
  def provider, do: Application.fetch_env!(:sdr_agent, :model_provider)

  @doc """
  The desired real profile, as the coordinator last confirmed it (C2-02c
  section 2b): `{:ok, %{profile_id, source: :setting | :default,
  confirmed_at}}` when its row validates (owner and binding, read twice
  and equal, at most three attempts) and holds a confirmed observation;
  otherwise `{:error, :unknown}` for ClaudeCLI, never the registry
  default. An in-process provider (the Fake) is `:not_applicable`: no real
  profile is configured, which says nothing about a stored setting. No
  database read and no coordinator call; the coordinator itself reads the
  setting (C2-02b2α).
  """
  def desired_profile do
    case provider() do
      ClaudeCLI ->
        case ledger_sample(1) do
          {:ok, %{public: %{desired: %{confirmed_at: %DateTime{}} = desired}}} -> {:ok, desired}
          _unknown -> {:error, :unknown}
        end

      _in_process ->
        :not_applicable
    end
  end

  # The coordinator's row, twice and equal (C1 = C2), at most three times.
  defp ledger_sample(attempt) do
    c1 = Coordinator.sample()

    cond do
      match?({:ok, _row}, c1) and Coordinator.sample() == c1 -> c1
      attempt < @attempts -> ledger_sample(attempt + 1)
      true -> :error
    end
  end

  @doc """
  Supervision children for the selected provider: none for the Fake; for
  ClaudeCLI, the C2-02b2α profile tree (`ProfileSupervisor`), whose
  coordinator starts the one named server through the allocator, held until
  a reconciled read releases it.
  """
  def children do
    case provider() do
      ClaudeCLI -> [{ProfileSupervisor, server: &server_options/1}]
      _other -> []
    end
  end

  @doc """
  The ClaudeCLI start options of the app's server at `profile_id` (C2-02b2α:
  the coordinator adds the name, the profile and its hold): the configured
  `:timeout` and pinned `:executable` only. The profile is never an
  environment knob: the coordinator runs the persisted setting's desired
  profile, or the registry default before any setting.
  """
  def server_options(_profile_id) do
    :sdr_agent
    |> Application.get_env(ClaudeCLI, [])
    |> Keyword.take([:timeout, :executable])
  end

  @doc """
  Makes `model`'s provider explicit (default: the selected one) and, for
  ClaudeCLI, injects the named server. Refused (`{:error, reason}`) when
  the ClaudeCLI server it would use is not running, does not admit calls,
  found no `llm-proxy-shim`, has no acceptable pin, or is staged — for a
  named or unnamed server, however it is referenced (name or pid).
  """
  def resolve(model) when is_list(model) do
    model = Keyword.put_new_lazy(model, :provider, &provider/0)

    case model[:provider] do
      ClaudeCLI ->
        options =
          model
          |> Keyword.get(:provider_options, [])
          |> Keyword.put_new(:server, ClaudeCLI.server())

        with :ok <- healthy(options[:server]),
             do: {:ok, Keyword.put(model, :provider_options, options)}

      _other ->
        {:ok, model}
    end
  end

  # Health is read from the server's published status, whatever reference
  # (name, pid, {:global, _}, {:via, _, _}) addresses it: a registered
  # server by its name, an unnamed one by its pid (the status it publishes
  # in its process dictionary). The same admission, launcher, pin and
  # staging checks apply to both; a process that publishes no ClaudeCLI
  # status is refused.
  defp healthy(server) do
    if ClaudeCLI.running?(server) do
      pid = GenServer.whereis(server)
      published_health(registered_name(pid) || pid)
    else
      {:error, :provider_not_running}
    end
  end

  defp published_health(server) do
    eligibility(%{
      admission: ClaudeCLI.admission(server).admission,
      held?: ClaudeCLI.held?(server),
      attestation: ClaudeCLI.attestation(server)
    })
  end

  # The admission, launcher, pin and staging checks, as one pure function
  # of a server view (`admission: :open | :blocked | :not_running`,
  # `held?`, the attestation) plus pin file metadata and the staging
  # configuration: `resolve/1` builds the view from the server's published
  # status; `status/0` from its bracketed sample (C2-02c 2a).
  defp eligibility(%{admission: admission, held?: held?, attestation: attestation}) do
    cond do
      admission == :not_running -> {:error, :provider_not_running}
      held? -> {:error, :provider_held}
      admission != :open -> {:error, :provider_not_quiescent}
      attestation[:command?] == false -> {:error, :llm_proxy_shim_not_found}
      not pinned_cli_present?(attestation) -> {:error, :pinned_cli_unavailable}
      not attestation[:test_launcher?] -> {:error, :real_model_staged}
      true -> :ok
    end
  end

  # Re-checked on every resolution (file metadata only), so a pinned build
  # collected after boot is refused before any reservation. Without a pin
  # only a test build's injected launcher passes.
  defp pinned_cli_present?(%{executable: path}) when is_binary(path),
    do: PinnedExecutable.check(path) == :ok

  defp pinned_cli_present?(attestation), do: attestation[:test_launcher?] == true

  defp registered_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _unnamed_or_gone -> nil
    end
  end

  defp registered_name(_pid), do: nil

  @doc """
  The run `failure_reason` recorded when a worker refuses to run because of
  `reason` (`:provider_not_running`, `:provider_held`, `:provider_not_quiescent`,
  `:llm_proxy_shim_not_found`, `:pinned_cli_unavailable`,
  `:real_model_staged` or `:unknown_model_provider`), or that status
  shows for ClaudeCLI (`:status_unavailable`, `:status_inconsistent`); no
  model call was made.
  """
  def refusal_message(:provider_not_running),
    do:
      "model provider claude_cli is not running: no supervised ClaudeCLI server " <>
        "(select it with SDR_MODEL_PROVIDER=claude_cli); no model call was made"

  def refusal_message(:unknown_model_provider),
    do: "unknown model provider named by the job (fake or claude_cli); no model call was made"

  def refusal_message(:provider_held),
    do:
      "model provider claude_cli is held while its server is started, adopted or switched " <>
        "(see Admin); no model call was made"

  def refusal_message(:provider_not_quiescent),
    do:
      "model provider claude_cli refuses calls until earlier CLI work is confirmed stopped " <>
        "(see Admin); no model call was made"

  def refusal_message(:llm_proxy_shim_not_found),
    do: "model provider claude_cli found no llm-proxy-shim on PATH; no model call was made"

  def refusal_message(:real_model_staged),
    do:
      "model provider claude_cli is staged: real model calls stay unavailable until the " <>
        "reviewed profiles, owner call grants and witness work land (R0-03, C9, R0-07); " <>
        "no model call was made"

  def refusal_message(:pinned_cli_unavailable),
    do:
      "model provider claude_cli refuses calls: the app's pinned Claude CLI is not configured, " <>
        "missing or not the reviewed build (bin/app-claude-cli-root); no model call was made"

  def refusal_message(:status_unavailable),
    do:
      "model provider claude_cli status is unavailable: no valid coordinator or bound server " <>
        "was observed (status is never authority); no model call was made"

  def refusal_message(:status_inconsistent),
    do:
      "model provider claude_cli status kept changing while it was read, so no eligibility " <>
        "is reported (status is never authority); no model call was made"

  @doc """
  The selected provider's status for operators (no secrets); see the
  moduledoc. Never authority: a later instant may differ.
  """
  def status do
    case provider() do
      ClaudeCLI -> claude_cli_status()
      configured -> in_process_status(configured)
    end
  end

  # An in-process provider (the Fake): its fixed provenance, its effective
  # provider from the pass-through `resolve/1`, and every ClaudeCLI field
  # not applicable.
  defp in_process_status(configured) do
    {effective, refusal} =
      case resolve([]) do
        {:ok, model} -> {model[:provider], nil}
        {:error, reason} -> {nil, reason}
      end

    prepared = prepared(configured)

    %{
      configured: configured,
      effective: effective,
      refusal: refusal,
      provider: configured,
      profile_id: prepared[:profile_id],
      model_alias: nil,
      model_id: prepared[:model_id],
      reviewed_version: nil,
      cli_executable: nil,
      server: :not_applicable,
      attestation: %{status: :not_applicable},
      ledger_observation: :not_applicable,
      runtime_observation: :not_applicable,
      desired_profile: :not_applicable,
      switch: :not_applicable,
      observed_profile: :not_applicable,
      hold: :not_applicable,
      stage: :not_applicable,
      effective_profile: nil,
      published_at: nil
    }
  end

  defp claude_cli_status do
    observation = 1 |> bracket() |> observation()
    profile = known_profile(observation.observed_profile, observation.desired_profile)

    model =
      if profile do
        provenance = ClaudeCLI.provenance(profile)

        %{
          model_alias: provenance.model_catalog_entry["alias"],
          model_id: provenance.model_id,
          reviewed_version: provenance.provider_version
        }
      else
        %{model_alias: nil, model_id: nil, reviewed_version: nil}
      end

    observation
    |> Map.merge(model)
    |> Map.merge(%{
      configured: ClaudeCLI,
      provider: ClaudeCLI,
      profile_id: profile,
      cli_executable: :sdr_agent |> Application.get_env(ClaudeCLI, []) |> Keyword.get(:executable)
    })
  end

  # The known observed profile, then the confirmed desired one, else nil.
  defp known_profile(observed, _desired)
       when is_atom(observed) and observed not in [nil, :none, :unknown],
       do: observed

  defp known_profile(_observed, %{profile_id: profile}), do: profile
  defp known_profile(_observed, _unknown), do: nil

  ## The bracket (C2-02c 2a)

  # At most three attempts; the first wholly consistent one is the sample,
  # else the last one (classified by `observation/1`).
  defp bracket(attempt) do
    sample = attempt(attempt)

    if consistent?(sample) or attempt == @attempts,
      do: sample,
      else: bracket(attempt + 1)
  end

  # C1 → S1 → eligibility → S2 → C2: read-only, and no process is called.
  defp attempt(n) do
    c1 = Coordinator.sample()
    point(:c1, n)
    s1 = server_sample(c1)
    point(:s1, n)
    verdict = sampled_eligibility(c1, s1)
    point(:eligibility, n)
    s2 = server_sample(c1)
    point(:s2, n)
    c2 = Coordinator.sample()
    point(:c2, n)
    %{c1: c1, s1: s1, verdict: verdict, s2: s2, c2: c2}
  end

  # The server C1's row binds: its table, owned by the pid registered as
  # the server's name and bound by the row; or positively none (the row
  # binds none, no table and no process holds the name). Anything else is
  # missing, never `:none`.
  defp server_sample({:ok, %{private: %{server: bound}}}) do
    name = ClaudeCLI.server()

    case {bound, ClaudeCLI.table_sample(name)} do
      {:none, :absent} ->
        if Process.whereis(name) == nil, do: {:ok, :none}, else: :missing

      {pid, {:ok, %{owner: pid, registered: pid} = sample}} when is_pid(pid) ->
        {:ok, sample}

      _missing_or_unbound ->
        :missing
    end
  end

  defp server_sample(_invalid_coordinator), do: :skipped

  # Eligibility inside the bracket, from C1 and S1 only: a published hold
  # other than `:released` (a pending hold included) counts as held.
  defp sampled_eligibility({:ok, _row}, {:ok, :none}), do: {:error, :provider_not_running}

  defp sampled_eligibility({:ok, %{public: %{hold: hold}}}, {:ok, %{values: values}}) do
    eligibility(%{
      admission: admission(values[:admission]),
      held?: values[:held] == true or hold != :released,
      attestation: values[:attestation] || %{status: :not_running}
    })
  end

  defp sampled_eligibility(_c1, _s1), do: nil

  defp admission(:open), do: :open
  defp admission({:blocked, _reason}), do: :blocked
  defp admission(_none), do: :not_running

  defp consistent?(%{c1: {:ok, _} = c1, c2: c2, s1: {:ok, _} = s1, s2: s2}),
    do: c1 == c2 and s1 == s2

  defp consistent?(_sample), do: false

  defp coordinator_valid?(%{c1: {:ok, _} = c1, c2: c2}), do: c1 == c2
  defp coordinator_valid?(_sample), do: false

  # The 2b shapes. Ledger fields need the final attempt's coordinator
  # validation (C1 = C2); runtime fields need a wholly consistent attempt.
  defp observation(sample) do
    cond do
      consistent?(sample) ->
        sample |> ledger(:valid) |> Map.merge(runtime(sample))

      coordinator_valid?(sample) ->
        {runtime, refusal} =
          if match?({:ok, _}, sample.s1) and match?({:ok, _}, sample.s2),
            do: {:inconsistent, :status_inconsistent},
            else: {:unavailable, :status_unavailable}

        sample |> ledger(:valid) |> Map.merge(unknown_runtime(runtime, refusal))

      true ->
        sample
        |> ledger(:unavailable)
        |> Map.merge(unknown_runtime(:unavailable, :status_unavailable))
    end
  end

  defp ledger(%{c1: {:ok, %{public: row}}}, :valid) do
    %{
      ledger_observation: :valid,
      desired_profile: row.desired,
      switch: row.switch,
      published_at: row.published_at
    }
  end

  defp ledger(_sample, :unavailable) do
    %{
      ledger_observation: :unavailable,
      desired_profile: :unknown,
      switch: :unknown,
      published_at: nil
    }
  end

  defp runtime(%{c1: {:ok, %{public: row}}, s1: {:ok, server}, verdict: verdict}) do
    {observed, server_state, attestation} =
      case server do
        :none ->
          {:none, :not_running, %{status: :not_running}}

        %{values: values} ->
          {values[:profile], server_state(admission(values[:admission])),
           values[:attestation] || %{status: :not_running}}
      end

    {effective, refusal, effective_profile} =
      case verdict do
        :ok -> {ClaudeCLI, nil, observed}
        {:error, reason} -> {nil, reason, nil}
      end

    %{
      runtime_observation: :consistent,
      observed_profile: observed,
      hold: row.hold,
      stage: row.stage,
      effective_profile: effective_profile,
      effective: effective,
      refusal: refusal,
      server: server_state,
      attestation: attestation
    }
  end

  defp unknown_runtime(runtime, refusal) do
    %{
      runtime_observation: runtime,
      observed_profile: :unknown,
      hold: :unknown,
      stage: :unknown,
      effective_profile: nil,
      effective: nil,
      refusal: refusal,
      server: :unknown,
      attestation: %{status: :unknown}
    }
  end

  # `:blocked` while the server refuses calls until earlier CLI work is
  # confirmed stopped (`ClaudeCLI.admission/1`).
  defp server_state(:open), do: :running
  defp server_state(:blocked), do: :blocked
  defp server_state(:not_running), do: :not_running

  # The test-build sample seam (see the moduledoc); compiled out elsewhere.
  if @test_seams do
    defp point(point, attempt),
      do:
        :telemetry.execute([:sdr_agent, :runtime_status, :sample], %{}, %{
          point: point,
          attempt: attempt
        })
  else
    defp point(_point, _attempt), do: :ok
  end

  # In-process providers record their fixed provenance without a request.
  defp prepared(module) do
    case module.prepare(%{}, []) do
      {:ok, provenance} when is_map(provenance) -> provenance
      _refused -> %{}
    end
  end
end
