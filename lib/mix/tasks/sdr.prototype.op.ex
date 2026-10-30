# Compiled only with the D-237 prototype authority; absent in production.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule Mix.Tasks.Sdr.Prototype.Op do
    @shortdoc "D-237 prototype operator commands (assign, review, approve, reject, revoke, seed, status)"

    @moduledoc """
    `mix sdr.prototype.op <command> --agent claude_code|codex_cli ...`: the
    D-237 operator's commands (interfaces r6 IF-2 task kind, IF-3, IF-5; plan
    r7 section 3 "Operator gates, UI and acceptance"). Each runs one operator
    action as the session's resolved prototype operator.

      * `assign --lead ID --campaign ID`
      * `review --draft ID`: the private bundle with the pending-revision view
        (with the recipient contact id and exact email) and the run view; it
        prints the bundle UUID and item count only;
      * `approve --revision ID --revision-sha256 HEX --recipient-email ADDR`:
        all three exactly as reviewed, each required; a missing one refuses
        before any action. The address is kept byte for byte and is never
        fetched, refilled or replaced from the current contact;
      * `reject --revision ID --revision-sha256 HEX --reason CODE` (`not_a_fit`,
        `content` or `recipient`);
      * `revoke --approval ID`
      * `seed --seed-dir D --seed-sha256 P,G,C,V` (the separate seed retry)
      * `status`

    `parse/1` validates the arguments with no I/O: a closed command set,
    `--agent` required (`claude_code` or `codex_cli`), exactly each command's
    switches once, canonical lowercase UUIDs, lowercase 64-hex digests, an
    absolute seed path and four seed digests; anything else is
    `{:error, :invalid_arguments}`.

    `execute/2` implements `assign` only (D-268 M7): the lead is read as the
    operator, then `SdrAgent.SDR.assign_lead/2` runs with the operator and
    the campaign and never an `owner_user_id`; it returns the new AgentRun's
    id. Its job is only inserted, inside the action's transaction; it runs
    only in serve. Every other command returns `{:error, :not_implemented}`.

    Mix loads app.config through the requirement before SafeLog attaches and
    the terminal launch (ADR-0022). The body starts only OpenTelemetry,
    parses argv, enters `SdrAgent.Prototype.Session` (with the insert-only
    Oban for `assign`), then checks the real op guard before the action.
    The one result line is SafeLog's closed `op_result` with the lead id.
    An invalid argument, an unimplemented command, a Session code outside
    the op reasons and every non-success guard result are returned tagged
    to TaskBoundary for its one fixed abort line; nothing else is printed.
    """
    use Mix.Task

    alias SdrAgent.Prototype.ContainmentGuard
    alias SdrAgent.Prototype.SafeLog
    alias SdrAgent.Prototype.Session
    alias SdrAgent.Prototype.TaskBoundary
    alias SdrAgent.Sales
    alias SdrAgent.SDR

    @requirements ["app.config"]

    @commands %{
      "assign" => :assign,
      "review" => :review,
      "approve" => :approve,
      "reject" => :reject,
      "revoke" => :revoke,
      "seed" => :seed,
      "status" => :status
    }

    @agents %{"claude_code" => :claude_code, "codex_cli" => :codex_cli}

    @options %{
      assign: [lead: :uuid, campaign: :uuid],
      review: [draft: :uuid],
      approve: [revision: :uuid, revision_sha256: :hex64, recipient_email: :email],
      reject: [revision: :uuid, revision_sha256: :hex64, reason: :reason],
      revoke: [approval: :uuid],
      seed: [seed_dir: :path, seed_sha256: :digests],
      status: []
    }

    @reasons ["not_a_fit", "content", "recipient"]

    # Session and action codes printed as themselves; every other code is
    # an outer abort, never relabelled.
    @passed_codes [:binding_mismatch, :not_prototype_runtime]

    @doc "Validates `argv`; `{:ok, parsed}` or `{:error, :invalid_arguments}`."
    @spec parse([String.t()]) :: {:ok, map()} | {:error, atom()}
    def parse([name | argv]) when is_map_key(@commands, name) do
      command = Map.fetch!(@commands, name)
      spec = Map.fetch!(@options, command)
      strict = [{:agent, :string} | Enum.map(spec, fn {key, _type} -> {key, :string} end)]

      with {opts, [], []} <- OptionParser.parse(argv, strict: strict),
           true <- unique_keys?(opts),
           {:ok, agent} <- Map.fetch(@agents, Keyword.get(opts, :agent, "")),
           {:ok, values} <- values(spec, opts) do
        {:ok, Map.merge(values, %{command: command, agent: agent})}
      else
        _ -> {:error, :invalid_arguments}
      end
    end

    def parse(_argv), do: {:error, :invalid_arguments}

    @doc """
    Runs one parsed command as the resolved operator `actor`: `assign`
    returns `{:ok, %{id: run_id}}` or `{:error, :forbidden | :not_found |
    :binding_mismatch | :not_prototype_runtime | :op_failed}`; every other
    command is `{:error, :not_implemented}`.
    """
    @spec execute(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
    def execute(%{command: :assign, lead: lead_id, campaign: campaign_id}, actor) do
      with {:ok, lead} <- Sales.fetch(Sales.Lead, lead_id, actor: actor),
           {:ok, %{run: run}} <- SDR.assign_lead(lead, actor: actor, campaign_id: campaign_id) do
        {:ok, %{id: run.id}}
      else
        {:error, error} -> {:error, reason(error)}
      end
    end

    def execute(_parsed, _actor), do: {:error, :not_implemented}

    @doc """
    Maps one `seed` stage result to `{:say, code, refs}` or
    `{:abort, {stage, value}}`. RED declaration: every value aborts.
    """
    @spec seed_outcome(atom(), term()) :: {:say, atom(), keyword()} | {:abort, term()}
    def seed_outcome(stage, _value), do: {:abort, {stage, :unexpected}}

    @impl Mix.Task
    def run(argv) do
      attached = SafeLog.attach(file: nil)
      TaskBoundary.launch(:op, attached, fn -> body(argv) end)
    end

    defp body(argv) do
      {:ok, _started} = Application.ensure_all_started(:opentelemetry)

      with {:ok, %{command: :assign} = parsed} <- parse(argv),
           correlation = System.get_env("SDR_PROTOTYPE_SESSION"),
           {:ok, %{actor: actor}} <- enter(parsed, correlation),
           {:guard, :ok} <- {:guard, ContainmentGuard.guard(:op)} do
        result(parsed, execute(parsed, actor))
      else
        {:guard, _result} = guard_refusal -> guard_refusal
        {:refuse, parsed, code} -> result(parsed, {:error, code})
        {:ok, _other_command} -> {:op, :not_implemented}
        {:error, :invalid_arguments} -> {:op, :invalid_arguments}
        {:session, _code} = session_refusal -> session_refusal
      end
    end

    defp enter(parsed, correlation) do
      case Session.enter(
             agent: Atom.to_string(parsed.agent),
             session_correlation: correlation,
             enqueue?: true
           ) do
        {:ok, entered} -> {:ok, entered}
        {:error, code} when code in @passed_codes -> {:refuse, parsed, code}
        {:error, code} -> {:session, code}
      end
    end

    defp result(parsed, {:ok, _value}) do
      :ok = SafeLog.say(:op_result, command: :assign, id: parsed.lead, result: :ok, reason: :none)
      :ok
    end

    defp result(parsed, {:error, code}) do
      :ok =
        SafeLog.say(:op_result, command: :assign, id: parsed.lead, result: :refused, reason: code)

      :refused
    end

    defp reason(%Ash.Error.Forbidden{}), do: :forbidden
    defp reason(%Ash.Error.Query.NotFound{}), do: :not_found

    defp reason(%Ash.Error.Invalid{errors: errors}) do
      if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
        do: :not_found,
        else: :op_failed
    end

    defp reason(code) when code in @passed_codes, do: code
    defp reason(_error), do: :op_failed

    defp unique_keys?(opts), do: length(opts) == length(Enum.uniq(Keyword.keys(opts)))

    defp values(spec, opts) do
      Enum.reduce_while(spec, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
        with {:ok, raw} <- Keyword.fetch(opts, key),
             {:ok, value} <- value(type, raw) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          _ -> {:halt, :error}
        end
      end)
    end

    defp value(:uuid, raw) do
      case Ecto.UUID.cast(raw) do
        {:ok, ^raw} -> {:ok, raw}
        _ -> :error
      end
    end

    defp value(:hex64, raw), do: if(hex64?(raw), do: {:ok, raw}, else: :error)

    # The reviewed address is kept byte for byte; only its shape is checked.
    defp value(:email, raw) do
      if byte_size(raw) in 3..320 and String.valid?(raw) and
           Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/u, raw),
         do: {:ok, raw},
         else: :error
    end

    defp value(:reason, raw), do: if(raw in @reasons, do: {:ok, raw}, else: :error)

    defp value(:path, raw),
      do: if(String.valid?(raw) and Path.type(raw) == :absolute, do: {:ok, raw}, else: :error)

    defp value(:digests, raw) do
      digests = String.split(raw, ",")

      if length(digests) == 4 and Enum.all?(digests, &hex64?/1),
        do: {:ok, digests},
        else: :error
    end

    defp hex64?(raw), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, raw)
  end
end
