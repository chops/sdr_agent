# Compiled only with the D-237 prototype authority; absent in production.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule Mix.Tasks.Sdr.Prototype.Provision do
    @shortdoc "D-237 prototype provisioning of the one d237-funding/1 model-call grant"

    @moduledoc """
    `mix sdr.prototype.provision --agent claude_code|codex_cli
    --budget-worksheet PATH --budget-worksheet-sha256 HEX`: the D-237
    provision task (interfaces r6 IF-2 "Provisioning"; D-268 M6b; Codex
    rulings a3f14552 and delta review f1bffa89). It provisions, or replays,
    the one grant as the session's resolved prototype operator. D-269 /
    ADR-0023 replaces its historical-count prerequisite with the closed
    `d237-owner-allowance/1` worksheet and the exact owner receipt for 100
    additional attempts. Replays never add capacity or reset charges.

    `parse/1` validates the arguments with no I/O: each of the three keys
    exactly once, `--agent` `claude_code` or `codex_cli`, a nonempty
    worksheet path (relative to the fixed evidence root; the private
    reader checks it) and a lowercase 64-hex digest; anything else is
    `{:error, :invalid_arguments}`.

    `outcome/2` maps one stage result to the task's one line, closed and
    stage-specific: `{:say, :provisioned | :provision_refused, refs}` or
    `{:abort, tagged}`. Only a returned Session code of the six listed ones
    is printed as itself, and only a returned `BootCheck.reasons/0` Session
    code becomes `:boot_refused`; a returned worksheet read error is
    `:worksheet_invalid`; the companion's actual branch is `provisioned`,
    and its known refusal atoms and `Forbidden` are refusals. Every other
    value is an outer abort, never a coerced reason.

    Mix loads app.config through the requirement before SafeLog attaches and
    the terminal launch (ADR-0022). The body starts only OpenTelemetry,
    parses argv, enters `SdrAgent.Prototype.Session` (no Oban), checks the
    real provision guard, reads the worksheet privately and hash-pinned from
    the fixed evidence root (never a flag), then calls
    `SdrAgent.Agents.provision_prototype_grant_result/2`. Every non-success
    guard result is returned whole and tagged to TaskBoundary for its one
    fixed abort line. Raised or thrown failures are TaskBoundary's. The
    task does not seed, enqueue, call a model or send outreach.
    """
    use Mix.Task

    alias SdrAgent.Agents
    alias SdrAgent.Prototype.BootCheck
    alias SdrAgent.Prototype.BoundedJson
    alias SdrAgent.Prototype.ContainmentGuard
    alias SdrAgent.Prototype.SafeLog
    alias SdrAgent.Prototype.Session
    alias SdrAgent.Prototype.TaskBoundary

    @requirements ["app.config"]

    # :keep preserves duplicates so the exact-key check refuses them.
    @switches [agent: :keep, budget_worksheet: :keep, budget_worksheet_sha256: :keep]
    @option_names @switches |> Keyword.keys() |> Enum.sort()
    @agents %{"claude_code" => :claude_code, "codex_cli" => :codex_cli}

    @evidence_root "/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp"
    @max_bytes 16_384

    # Session codes printed as themselves (ruling f1bffa89).
    @session_codes [
      :binding_mismatch,
      :not_prototype_runtime,
      :session_unset,
      :invalid_agent,
      :invalid_correlation,
      :delegation_not_found
    ]

    @provision_codes SafeLog.reasons(:provision) -- [:none]

    @doc "Validates `argv`; `{:ok, parsed}` or `{:error, :invalid_arguments}`."
    @spec parse([String.t()]) :: {:ok, map()} | {:error, :invalid_arguments}
    def parse(argv) do
      with {opts, [], []} <- OptionParser.parse(argv, strict: @switches),
           true <- Enum.sort(Keyword.keys(opts)) == @option_names,
           {:ok, agent} <- Map.fetch(@agents, Keyword.fetch!(opts, :agent)),
           path when is_binary(path) and path != "" <- Keyword.fetch!(opts, :budget_worksheet),
           digest = Keyword.fetch!(opts, :budget_worksheet_sha256),
           true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
        {:ok, %{agent: agent, worksheet: path, worksheet_sha256: digest}}
      else
        _ -> {:error, :invalid_arguments}
      end
    end

    @doc """
    Maps one stage result (`:arguments`, `:session`, `:read` or
    `:provision`) to `{:say, code, refs}` or `{:abort, {stage, value}}`;
    see the moduledoc.
    """
    @spec outcome(atom(), term()) :: {:say, atom(), keyword()} | {:abort, term()}
    def outcome(:arguments, {:error, :invalid_arguments}), do: refused(:invalid_arguments)

    def outcome(:session, {:error, code}) when code in @session_codes, do: refused(code)

    def outcome(:session, {:error, code}) when is_atom(code) do
      if code in BootCheck.reasons(),
        do: refused(:boot_refused),
        else: {:abort, {:session, code}}
    end

    def outcome(:read, {:error, _error}), do: refused(:worksheet_invalid)

    def outcome(:provision, {:ok, %{grant: %{id: id}, result: branch}})
        when branch in [:created, :replay],
        do: {:say, :provisioned, [grant_id: id, result: branch, reason: :none]}

    def outcome(:provision, {:error, %Ash.Error.Forbidden{}}), do: refused(:forbidden)
    def outcome(:provision, {:error, code}) when code in @provision_codes, do: refused(code)

    def outcome(stage, value), do: {:abort, {stage, abort_value(value)}}

    @impl Mix.Task
    def run(argv) do
      attached = SafeLog.attach(file: nil)
      TaskBoundary.launch(:provision, attached, fn -> body(argv) end)
    end

    defp body(argv) do
      {:ok, _started} = Application.ensure_all_started(:opentelemetry)

      with {:ok, parsed} <- at(:arguments, parse(argv)),
           correlation = System.get_env("SDR_PROTOTYPE_SESSION"),
           {:ok, %{actor: actor}} <-
             at(
               :session,
               Session.enter(
                 agent: Atom.to_string(parsed.agent),
                 session_correlation: correlation
               )
             ),
           {:guard, :ok} <- {:guard, ContainmentGuard.guard(:provision)},
           {:ok, bytes} <-
             at(
               :read,
               BoundedJson.read_private(
                 @evidence_root,
                 parsed.worksheet,
                 parsed.worksheet_sha256,
                 @max_bytes
               )
             ) do
        :provision
        |> outcome(
          Agents.provision_prototype_grant_result(
            %{worksheet: bytes, worksheet_sha256: parsed.worksheet_sha256},
            actor: actor,
            evidence_root: @evidence_root
          )
        )
        |> finish()
      else
        {:guard, _result} = guard_refusal -> guard_refusal
        {:stage, stage, error} -> finish(outcome(stage, error))
      end
    end

    defp at(_stage, {:ok, value}), do: {:ok, value}
    defp at(stage, error), do: {:stage, stage, error}

    defp finish({:say, :provisioned, refs}) do
      :ok = SafeLog.say(:provisioned, refs)
      :ok
    end

    defp finish({:say, :provision_refused, refs}) do
      :ok = SafeLog.say(:provision_refused, refs)
      :refused
    end

    defp finish({:abort, tagged}), do: tagged

    defp refused(reason), do: {:say, :provision_refused, [reason: reason]}

    # The abort keeps an atom code; any other value is not carried.
    defp abort_value({:error, code}) when is_atom(code), do: code
    defp abort_value(_value), do: :unexpected
  end
end
