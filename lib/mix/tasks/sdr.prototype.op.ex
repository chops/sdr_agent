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

  Bounded stage (D-237 S4, Codex 9086e6a8): `execute/2` and `run/1` are not
  implemented yet and return `{:error, :not_implemented}`.
  """
  use Mix.Task

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

  @doc "Runs one parsed command as the resolved operator `actor`."
  @spec execute(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
  def execute(_parsed, _actor), do: red({:error, :not_implemented})

  @impl Mix.Task
  def run(_argv), do: red({:error, :not_implemented})

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

  # RED stub result for the not-yet-bounded commands, typed dynamic() so
  # callers compile against it; nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
