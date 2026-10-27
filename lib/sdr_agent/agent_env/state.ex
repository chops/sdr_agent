defmodule SdrAgent.AgentEnv.State do
  @moduledoc """
  The agent environment's cooperative state files under `<root>/state/`
  (plan `claude-c2star-s1-environment-plan-r2.md` section 4.2): the read and
  validation facade (S1 PR-A). The writers, leases, release and
  classification are S1 PR-B; nothing here creates, changes or removes a
  file.

  A file is valid only when it is a regular file (never a symlink) of at
  most 64 KiB whose bytes are exactly the canonical
  `SdrAgent.Audit.Canonical` encoding of a JSON object (so no trailing
  newline), with exactly its closed key set and well-formed values.
  `read/2` returns `{:valid, sha256, data}` (`sha256`: lowercase hex of the
  bytes; `data`: the decoded object, string keys), `:absent` when there is
  no file, or `{:invalid, reason}`. It never raises for a known name.

  | Name | File | Keys |
  |---|---|---|
  | `:pending` | `environment.pending` | `environment_id`, `nonce`, `started_at` |
  | `:lease` | `instance.lease` | `environment_id`, `mode`, `nonce`, `target`, `port`, `started_at` |
  | `:created` | `environment.created.json` | `database`, `database_oid`, `nonce` |
  | `:environment` | `environment.json` | `environment_id`, `database`, `database_oid`, `tenant_id`, `nonce`, `created_at` |
  | `:claim` | `authorization.claim.json` | `authorization_id`, `authorization_sha256`, `binding_sha256`, `nonce`, `claimed_at` |
  | `:authorization` | `authorization.json` | `authorization_id`, `authorization_sha256`, `binding_sha256`, `grant_id`, `revision`, `event_id`, `nonce` |
  | `{:receipt, nonce, step}` | `instance.<nonce>.<step>.exit` | `nonce`, `step`, `completed_at`; `probe` adds `tenant_id`; `provision` adds `authorization_id`, `grant_id`, `event_id` |
  | `{:run_receipt, nonce}` | `instance.<nonce>.exit` | `nonce`, `completed_at` |

  A lease's `target` is `{database, host, port}` = `{"sdr_agent_agentenv",
  "localhost", 5520}` in bootstrap mode, otherwise `{binding_sha256}`; its
  `port` is 4130 in run mode, otherwise `null`.

  `authorization_id` is an S2 registry id: the registry's closed id pattern
  `\\A[a-z0-9][a-z0-9.-]{0,63}\\z` (one lowercase letter or digit, then up to
  63 lowercase letters, digits, dots or dashes), never checked as a UUID.
  `tenant_id`, `grant_id` and `event_id` are UUIDs in the canonical lowercase
  hyphenated form only.
  """

  alias SdrAgent.AgentEnv
  alias SdrAgent.Audit.Canonical

  @max_bytes 65_536
  @steps [:create, :migrate, :seed, :probe, :provision]
  @bootstrap_target %{"database" => "sdr_agent_agentenv", "host" => "localhost", "port" => 5520}

  @type name ::
          :pending
          | :lease
          | :created
          | :environment
          | :claim
          | :authorization
          | {:receipt, nonce :: String.t(), :create | :migrate | :seed | :probe | :provision}
          | {:run_receipt, nonce :: String.t()}
  @type view :: {:valid, sha256 :: String.t(), map()} | :absent | {:invalid, atom()}

  @doc "The configured root, or `{:error, :agent_env_not_configured}`."
  @spec root() :: {:ok, Path.t()} | {:error, :agent_env_not_configured}
  def root do
    with true <- AgentEnv.configured?(),
         root when is_binary(root) <- Keyword.get(AgentEnv.config(), :root),
         :absolute <- Path.type(root) do
      {:ok, root}
    else
      _other -> {:error, :agent_env_not_configured}
    end
  end

  @doc "The view of state file `name` under `root` (see the moduledoc)."
  @spec read(Path.t(), name()) :: view()
  def read(root, name) when is_binary(root) do
    file = path(root, name)
    view(file, name)
  end

  @doc "The path of state file `name` under `root`; raises `ArgumentError` for another name."
  @spec path(Path.t(), name()) :: Path.t()
  def path(root, name), do: Path.join([root, "state", file_name(name)])

  defp file_name(:pending), do: "environment.pending"
  defp file_name(:lease), do: "instance.lease"
  defp file_name(:created), do: "environment.created.json"
  defp file_name(:environment), do: "environment.json"
  defp file_name(:claim), do: "authorization.claim.json"
  defp file_name(:authorization), do: "authorization.json"

  defp file_name({:receipt, nonce, step}) when step in @steps do
    if nonce?(nonce), do: "instance.#{nonce}.#{step}.exit", else: invalid_name!({:receipt, nonce})
  end

  defp file_name({:run_receipt, nonce} = name),
    do: if(nonce?(nonce), do: "instance.#{nonce}.exit", else: invalid_name!(name))

  defp file_name(name), do: invalid_name!(name)

  defp invalid_name!(name),
    do: raise(ArgumentError, "not an agent environment state file: #{inspect(name)}")

  defp view(file, name) do
    case bytes(file) do
      {:ok, bytes} -> validate(bytes, name)
      :absent -> :absent
      {:error, reason} -> {:invalid, reason}
    end
  rescue
    _error -> {:invalid, :unreadable}
  end

  defp bytes(file) do
    case File.lstat(file) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes -> read_bytes(file)
      {:ok, %File.Stat{type: :regular}} -> {:error, :too_large}
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, :enoent} -> :absent
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp read_bytes(file) do
    case File.read(file) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :too_large}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp validate(bytes, name) do
    with {:ok, data} <- decode(bytes),
         :ok <- key_set(data, name),
         :ok <- values(data, name) do
      {:valid, sha256(bytes), data}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = data} -> canonical(data, bytes)
      {:ok, _other} -> {:invalid, :not_an_object}
      {:error, _error} -> {:invalid, :not_json}
    end
  end

  defp canonical(data, bytes) do
    if Canonical.encode(data) == {:ok, bytes}, do: {:ok, data}, else: {:invalid, :not_canonical}
  end

  defp key_set(data, name) do
    if data |> Map.keys() |> Enum.sort() == Enum.sort(Map.keys(checks(name))),
      do: :ok,
      else: {:invalid, :key_set}
  end

  defp values(data, name) do
    if Enum.all?(checks(name), fn {key, check} -> valid_value?(check, Map.get(data, key)) end) and
         consistent?(data, name),
       do: :ok,
       else: {:invalid, :value}
  end

  defp checks(:pending),
    do: %{"environment_id" => :environment_id, "nonce" => :nonce, "started_at" => :timestamp}

  defp checks(:lease) do
    %{
      "environment_id" => :environment_id,
      "mode" => :lease_mode,
      "nonce" => :nonce,
      "target" => :map,
      "port" => :any,
      "started_at" => :timestamp
    }
  end

  defp checks(:created),
    do: %{"database" => :database, "database_oid" => :oid, "nonce" => :nonce}

  defp checks(:environment) do
    %{
      "environment_id" => :environment_id,
      "database" => :database,
      "database_oid" => :oid,
      "tenant_id" => :uuid,
      "nonce" => :nonce,
      "created_at" => :timestamp
    }
  end

  defp checks(:claim) do
    %{
      "authorization_id" => :authorization_id,
      "authorization_sha256" => :sha256,
      "binding_sha256" => :sha256,
      "nonce" => :nonce,
      "claimed_at" => :timestamp
    }
  end

  defp checks(:authorization) do
    %{
      "authorization_id" => :authorization_id,
      "authorization_sha256" => :sha256,
      "binding_sha256" => :sha256,
      "grant_id" => :uuid,
      "revision" => :revision,
      "event_id" => :uuid,
      "nonce" => :nonce
    }
  end

  defp checks({:receipt, _nonce, step}),
    do: Map.merge(%{"nonce" => :nonce, "step" => :any, "completed_at" => :timestamp}, extra(step))

  defp checks({:run_receipt, _nonce}), do: %{"nonce" => :nonce, "completed_at" => :timestamp}

  defp extra(:probe), do: %{"tenant_id" => :uuid}

  defp extra(:provision),
    do: %{"authorization_id" => :authorization_id, "grant_id" => :uuid, "event_id" => :uuid}

  defp extra(_step), do: %{}

  defp valid_value?(:any, _value), do: true
  defp valid_value?(:environment_id, value), do: value == AgentEnv.environment_id()
  defp valid_value?(:nonce, value), do: nonce?(value)
  defp valid_value?(:sha256, value), do: hex?(value, 64)
  defp valid_value?(:oid, value), do: is_integer(value) and value > 0
  defp valid_value?(:revision, value), do: value == 1
  defp valid_value?(:map, value), do: is_map(value)
  defp valid_value?(:lease_mode, value), do: value in ["bootstrap", "provisioning", "run"]

  defp valid_value?(:database, value),
    do: is_binary(value) and byte_size(value) in 1..63

  # Only the canonical lowercase hyphenated form: `Ecto.UUID.cast/1` alone
  # would also accept uppercase hex and any 16-byte binary (a raw UUID).
  defp valid_value?(:uuid, value),
    do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))

  # An S2 registry id (the registry's closed id pattern; S2 plan r1 OQ1).
  defp valid_value?(:authorization_id, value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, value)

  defp valid_value?(:timestamp, value),
    do: is_binary(value) and match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp nonce?(value), do: hex?(value, 32)

  defp hex?(value, length) when is_binary(value) and byte_size(value) == length,
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  defp hex?(_value, _length), do: false

  # Cross-field rules: a lease's target and port follow its mode; a receipt
  # names its own nonce and step.
  defp consistent?(%{"mode" => "bootstrap"} = lease, :lease),
    do: lease["target"] == @bootstrap_target and is_nil(lease["port"])

  defp consistent?(%{"mode" => mode, "target" => target, "port" => port}, :lease) do
    Map.keys(target) == ["binding_sha256"] and valid_value?(:sha256, target["binding_sha256"]) and
      port == if(mode == "run", do: AgentEnv.http_port(), else: nil)
  end

  defp consistent?(data, {:receipt, nonce, step}),
    do: data["nonce"] == nonce and data["step"] == Atom.to_string(step)

  defp consistent?(data, {:run_receipt, nonce}), do: data["nonce"] == nonce
  defp consistent?(_data, _name), do: true

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
