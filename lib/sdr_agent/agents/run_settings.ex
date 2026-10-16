defmodule SdrAgent.Agents.RunSettings do
  @moduledoc """
  Run settings helpers for agents and their consumers (C4,
  `docs/product/c4/readiness.md` sections 3.3, 3.8 and 12). Agents read
  settings only from their run's snapshot, never from current revisions:

    * `allowance/2` — the snapshot value of one operational limit field
      (for the three `run_*` fields, the run's frozen budget), or
      `{:error, :no_settings_snapshot}`. Consumers combine it with their own
      independent budgets inside their guarded step;
    * `booking_link_for_use/1` — the run's booking link if its host passes
      the real-data guard now: `{:ok, url}`, `{:error,
      :booking_link_absent}` or `{:error, :booking_link_withheld}`. Nothing
      newer or older is ever substituted. Consumers call it when building
      model input and again before persisting a draft;
    * `completeness/0` — the business settings each usage origin requires
      (C4-R8);
    * `milliseconds/1` — exact, range-checked seconds to milliseconds;
    * `booking_host_usable?/1` — the real-data guard on a booking host
      (`SdrAgent.Sales.Synthetic.reserved_domain?/1`, widened only by
      C5-04).

  The resolved settings of a run are `SdrAgent.Agents.run_settings/2`.

  Test-seam builds only (`:claude_cli_test_seams`): `config :sdr_agent,
  :booking_link_guard, {module, function}` injects a guard *failure*; the
  host must pass both it and the real guard, so the seam can withhold a
  link but never admit one. Builds without the seam do not compile that
  branch and ignore the setting.
  """

  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Agents.RunSettingsSnapshot
  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Sales.Synthetic

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]
  @business [:assignment, :referral, :followup, :discovery, :channel]
  @exempt [:reply, :proof]
  @budget_fields %{
    run_max_model_calls: :max_model_calls,
    run_max_tool_calls: :max_tool_calls,
    run_max_tokens: :max_tokens
  }

  @doc "The five settings kinds, in packet order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The business-content completeness table (C4-R8): for every usage origin
  (`SdrAgent.Agents.UsageBucket.origins/0`), the settings kinds a run of
  that origin requires. `:reply` and `:proof` are exempt from this rule
  only; every limit and proof authority still applies to them.
  """
  @spec completeness() :: %{atom() => [atom()]}
  def completeness do
    @business
    |> Map.new(&{&1, [:offering_profile]})
    |> Map.merge(Map.new(@exempt, &{&1, []}))
  end

  @doc "Exact milliseconds of a stored seconds value (0..2,147,483,647), checked."
  @spec milliseconds(integer()) :: {:ok, non_neg_integer()} | {:error, :out_of_range}
  def milliseconds(seconds) when is_integer(seconds) and seconds >= 0 do
    if seconds <= Safeguards.int_max(), do: {:ok, seconds * 1000}, else: {:error, :out_of_range}
  end

  def milliseconds(_seconds), do: {:error, :out_of_range}

  @doc """
  The snapshot value of limit `field` for `run`: the frozen budget for the
  `run_*` fields, the snapshot's limit otherwise.
  """
  @spec allowance(map(), atom()) :: {:ok, integer()} | {:error, atom()}
  def allowance(%{settings_snapshot_id: nil}, _field), do: {:error, :no_settings_snapshot}

  def allowance(run, field) do
    cond do
      field not in Safeguards.limit_fields() ->
        {:error, :unknown_limit}

      budget = Map.get(@budget_fields, field) ->
        with {:ok, _snapshot} <- snapshot(run), do: {:ok, Map.fetch!(run.budget, budget)}

      true ->
        with {:ok, snapshot} <- snapshot(run), do: {:ok, Map.fetch!(snapshot.limits, field)}
    end
  end

  @doc """
  The booking link of `run`'s snapshot if its host passes the real-data
  guard now (C4-R13); see the moduledoc.
  """
  @spec booking_link_for_use(map()) :: {:ok, String.t()} | {:error, atom()}
  def booking_link_for_use(%{settings_snapshot_id: nil}), do: {:error, :no_settings_snapshot}

  def booking_link_for_use(run) do
    with {:ok, snapshot} <- snapshot(run) do
      case {snapshot.booking_link_source, snapshot.booking_link_revision_id} do
        {:revision, id} when is_binary(id) -> usable_link(run.tenant_id, id, snapshot)
        _absent -> {:error, :booking_link_absent}
      end
    end
  end

  defp usable_link(tenant_id, id, snapshot) do
    with {:ok, %SettingsRevision{booking_link: %{url: url}} = revision} <-
           Ash.get(SettingsRevision, id, Kernel.opts(tenant_id)),
         true <- revision.content_sha256 == snapshot.booking_link_content_sha256,
         {:ok, uri} <- URI.new(url),
         true <- booking_host_usable?(uri.host) do
      {:ok, url}
    else
      _ -> {:error, :booking_link_withheld}
    end
  end

  defp snapshot(%{settings_snapshot_id: id, tenant_id: tenant_id}) do
    case Ash.get(RunSettingsSnapshot, id, Kernel.opts(tenant_id)) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _error} -> {:error, :no_settings_snapshot}
    end
  end

  @doc "Whether the real-data guard accepts `host` as a booking link host now."
  @spec booking_host_usable?(term()) :: boolean()
  def booking_host_usable?(host) when is_binary(host),
    do: Synthetic.reserved_domain?(host) and seam_allows?(host)

  def booking_host_usable?(_host), do: false

  if @test_seams do
    # Test-seam builds only: an injected guard failure (see the moduledoc).
    defp seam_allows?(host) do
      case Application.get_env(:sdr_agent, :booking_link_guard) do
        {module, function} when is_atom(module) and is_atom(function) ->
          apply(module, function, [host]) == true

        _none ->
          true
      end
    end
  else
    defp seam_allows?(_host), do: true
  end
end
