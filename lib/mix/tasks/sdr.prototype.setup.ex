if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule Mix.Tasks.Sdr.Prototype.Setup do
    @moduledoc """
    Provisions a fresh, capture-only prototype through the existing setup
    phases, without starting the product application tree.

        mix sdr.prototype.setup --agent codex_cli --seed-dir D \
          --seed-sha256 P,G,C,V --mode fresh

    All four flags are required exactly once. Digests are lowercase SHA256
    in offering-profile, writing-guide, campaign, provenance order. No
    resume or auditor option is accepted. `parse/1` has no effects; the
    body alone reads SDR_PROTOTYPE_SESSION and builds Setup's six-key map.

    Mix loads app.config before SafeLog attaches and terminal launch. The
    body starts only OpenTelemetry, parses argv and checks the real setup
    guard before invoking Setup. Guard failures stay tagged and unchanged
    for TaskBoundary. Only closed setup_phase lines reach stdout; paths,
    values, identifiers and arbitrary errors are never printed. A phase-3
    refusal leaves the committed phase-2 binding, not a fully seeded setup.
    """
    use Mix.Task

    alias SdrAgent.Prototype.ContainmentGuard
    alias SdrAgent.Prototype.SafeLog
    alias SdrAgent.Prototype.Setup
    alias SdrAgent.Prototype.TaskBoundary

    @shortdoc "Fresh capture-only prototype setup"
    @requirements ["app.config"]
    @switches [agent: :keep, seed_dir: :keep, seed_sha256: :keep, mode: :keep]
    @option_names @switches |> Keyword.keys() |> Enum.sort()
    @pin_names [:offering_profile, :writing_guide, :campaign, :provenance]
    @digest ~r/\A[0-9a-f]{64}\z/

    @doc "Pure argv parser; returns five setup fields, without session correlation."
    @spec parse([String.t()]) :: {:ok, map()} | {:error, :invalid_arguments}
    def parse(args) do
      with {opts, [], []} <- OptionParser.parse(args, strict: @switches),
           true <- Enum.sort(Keyword.keys(opts)) == @option_names,
           true <- Enum.all?(opts, fn {_key, value} -> is_binary(value) and value != "" end),
           agent = Keyword.fetch!(opts, :agent),
           true <- agent in ["claude_code", "codex_cli"],
           "fresh" <- Keyword.fetch!(opts, :mode),
           dir = Keyword.fetch!(opts, :seed_dir),
           true <- String.valid?(dir) and Path.type(dir) == :absolute,
           pins = opts |> Keyword.fetch!(:seed_sha256) |> String.split(",", trim: false),
           true <- length(pins) == 4 and Enum.all?(pins, &Regex.match?(@digest, &1)) do
        {:ok,
         %{
           agent: agent,
           seed_dir: dir,
           seed_sha256s: Map.new(Enum.zip(@pin_names, pins)),
           mode: :fresh,
           auditor_credential_out: nil
         }}
      else
        _invalid -> {:error, :invalid_arguments}
      end
    end

    @impl Mix.Task
    def run(args) do
      attached = SafeLog.attach(file: nil)
      TaskBoundary.launch(:setup, attached, fn -> body(args) end)
    end

    defp body(args) do
      {:ok, _started} = Application.ensure_all_started(:opentelemetry)

      with {:ok, parsed} <- parse(args),
           correlation = System.get_env("SDR_PROTOTYPE_SESSION"),
           {:guard, :ok} <- {:guard, ContainmentGuard.guard(:setup)} do
        setup_args = Map.put(parsed, :session_correlation, correlation)
        finish(Setup.run(Setup.real_effects(setup_args), setup_args))
      else
        {:guard, _result} = guard_refusal -> guard_refusal
        {:error, :invalid_arguments} -> refuse(0, :invalid_arguments)
      end
    end

    defp finish({:ok, %{binding_id: binding, delegation_id: delegation} = result})
         when map_size(result) == 2 and is_binary(binding) and is_binary(delegation) do
      :ok = SafeLog.say(:setup_phase, phase: 3, result: :ok, reason: :none)
      :ok
    end

    defp finish({:error, %{phase: phase, result: :refused, reason: reason} = failure})
         when map_size(failure) == 3 and phase in 0..3 and is_atom(reason) do
      if reason in SafeLog.reasons(:setup),
        do: refuse(phase, reason),
        else: {:setup, :unexpected_result}
    end

    defp finish({:error, {:unexpected, phase}}) when phase in 0..3,
      do: refuse(phase, :unexpected)

    defp finish(_other), do: {:setup, :unexpected_result}

    defp refuse(phase, reason) do
      :ok = SafeLog.say(:setup_phase, phase: phase, result: :refused, reason: reason)
      :refused
    end
  end
end
