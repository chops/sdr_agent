defmodule SdrAgent.Agents.RemoteLaunch do
  @moduledoc """
  S-B4: the one encoder of a remote call's launch, below the web layer.

  `encode/1` gives the exact `{"call": launch}` response bytes that
  `SdrAgentWeb.WorkerController` sends to a claiming Mac worker (the S-B7
  wire contract): seven keys, `call_id`, `profile_id`, `model_id`,
  `request_digest` (lowercase hex of the stored request SHA-256), `prompt`,
  `schema` and `result_deadline` (ISO 8601, UTC, microseconds).

  The Mac client refuses a response over `max_bytes/0` (1048576). So a
  launch is deliverable only when its encoding fits:

    * `worst_case_bytes/2` encodes a prompt and schema with the widest value
      of every fixed field (a UUID call id, the longest compiled real
      profile id and model id, a 64-character digest and a fixed-width
      deadline). `SdrAgent.Agents.RemoteCalls.check_request/1` refuses a
      reservation whose worst case is over the limit, and
      `SdrAgent.AI.ModelProvider.ClaudeCLI.Remote.prepare/2` refuses the
      call before any reservation.
    * `deliverable?/1` checks one actual launch; a claim (fresh or replay)
      of an undeliverable launch is refused and rolled back.
  """

  alias SdrAgent.AI.ModelProfiles

  @max_bytes 1_048_576
  @widest_call_id "00000000-0000-0000-0000-000000000000"
  @widest_deadline ~U[9999-12-31 23:59:59.999999Z]

  @type launch :: %{
          required(:call_id) => String.t(),
          required(:profile_id) => atom(),
          required(:model_id) => String.t(),
          required(:request_sha256) => binary(),
          required(:prompt) => String.t(),
          required(:schema) => map(),
          required(:result_deadline) => DateTime.t()
        }

  @doc "The largest launch response the Mac client accepts, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The seven-key wire map of `launch` (string keys)."
  @spec wire(launch()) :: map()
  def wire(launch) do
    %{
      "call_id" => launch.call_id,
      "profile_id" => Atom.to_string(launch.profile_id),
      "model_id" => launch.model_id,
      "request_digest" => Base.encode16(launch.request_sha256, case: :lower),
      "prompt" => launch.prompt,
      "schema" => launch.schema,
      "result_deadline" => DateTime.to_iso8601(launch.result_deadline)
    }
  end

  @doc "The exact `{\"call\": launch}` response bytes."
  @spec encode(launch()) :: binary()
  def encode(launch), do: Jason.encode!(%{"call" => wire(launch)})

  @doc "Whether `launch` encodes to at most `max_bytes/0`."
  @spec deliverable?(launch()) :: boolean()
  def deliverable?(launch), do: byte_size(encode(launch)) <= @max_bytes

  @doc """
  The encoded size of a launch of `prompt` and `schema` with the widest
  value of every fixed field (see the moduledoc).
  """
  @spec worst_case_bytes(String.t(), map()) :: non_neg_integer()
  def worst_case_bytes(prompt, schema) when is_binary(prompt) and is_map(schema) do
    profiles = Enum.map(ModelProfiles.real_ids(), &elem(ModelProfiles.fetch_real(&1), 1))

    launch = %{
      call_id: @widest_call_id,
      profile_id: Enum.max_by(profiles, &byte_size(Atom.to_string(&1.id))).id,
      model_id: Enum.max_by(Enum.map(profiles, & &1.resolved_model), &byte_size/1),
      request_sha256: <<0::256>>,
      prompt: prompt,
      schema: schema,
      result_deadline: @widest_deadline
    }

    byte_size(encode(launch))
  end
end
