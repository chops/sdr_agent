defmodule SdrAgent.AgentEnv.State do
  @moduledoc """
  The agent environment's cooperative state files under `<root>/state/`
  (plan `claude-c2star-s1-environment-plan-r2.md` section 4.2): the read and
  validation facade (S1 PR-A) and, from S1 PR-B GREEN-2 (P5 correction
  `claude-c2star-s1-prb-p5-correction-r1.md`), `create/3`: the exclusive
  create of one validated file, used for the run boot marker and the run
  receipt. It never replaces, changes or removes a published file. S1 PR-B
  GREEN-3 (Codex rulings `b684dba9` and the `31b72fea` review) adds the
  lease writer `acquire_lease/3` (phase P1), `release/3` (phase P5; it
  removes the lease and nothing else) and the read-only `classify/2`.

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
  | `{:boot, nonce}` | `instance.<nonce>.boot` | `nonce`, `boot_id` (32 lowercase hex), `booted_at` |
  | `{:run_receipt, nonce}` | `instance.<nonce>.exit` | `nonce`, `boot_id`, `completed_at` |

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
  @bootstrap_steps [:create, :migrate, :seed, :probe]
  @step_names Map.new(@steps, &{Atom.to_string(&1), &1})
  @fixed_files %{
    "environment.pending" => :pending,
    "instance.lease" => :lease,
    "environment.created.json" => :created,
    "environment.json" => :environment,
    "authorization.claim.json" => :claim,
    "authorization.json" => :authorization
  }

  @type name ::
          :pending
          | :lease
          | :created
          | :environment
          | :claim
          | :authorization
          | {:receipt, nonce :: String.t(), :create | :migrate | :seed | :probe | :provision}
          | {:boot, nonce :: String.t()}
          | {:run_receipt, nonce :: String.t()}
  @type view :: {:valid, sha256 :: String.t(), map()} | :absent | {:invalid, atom()}
  @type db_facts ::
          :unknown
          | :absent
          | {:present, %{database_oid: pos_integer(), tenant_id: String.t() | nil}}

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

  @doc """
  Exclusively creates state file `name` under `root` with `data` (string
  keys; `DateTime` values are encoded as their canonical text). The bytes
  are the canonical encoding and must read back valid for `name`, or
  nothing is written (`{:error, :invalid}`). The file is first written to
  a private temporary file in `<root>/state` and then published with a
  hard link, which fails when the name exists (`{:error, :exists}`), so a
  published file is never replaced and never seen half-written. Any other
  failure is `{:error, :write_failed}`. Returns `{:ok, sha256}`.
  """
  @spec create(Path.t(), name(), map()) ::
          {:ok, String.t()} | {:error, :exists | :invalid | :write_failed}
  def create(root, name, data) when is_binary(root) and is_map(data) do
    file = path(root, name)

    with {:ok, bytes} <- encode(data),
         {:valid, sha256, _data} <- validate(bytes, name) do
      publish(file, bytes, sha256)
    else
      _invalid -> {:error, :invalid}
    end
  end

  ## Leases, release and classification (S1 PR-B GREEN-3)

  @doc """
  Phase P1: takes the lease of `mode` and returns its fresh nonce.
  `:bootstrap` needs `classify(root, :unknown) == :fresh` and creates
  `environment.pending`, then the bootstrap lease, with one nonce;
  `:provisioning` and `:run` need `{:bound, _}` and target its binding
  digest (run: port 4130). A held lease is `:lease_held`, otherwise
  `:not_fresh` (bootstrap) or `:not_bound`. Exclusive creates only: a lost
  race is `:lease_held` (or `:not_fresh`), and a pending marker left by a
  failed lease write quarantines the root. `opts` is reserved.
  """
  @spec acquire_lease(Path.t(), :bootstrap | :provisioning | :run, keyword()) ::
          {:ok, String.t()} | {:error, :lease_held | :not_fresh | :not_bound | :write_failed}
  def acquire_lease(root, :bootstrap, opts) when is_binary(root) and is_list(opts) do
    case classify(root, :unknown) do
      :fresh -> bootstrap_lease(root, new_nonce())
      {:leased, _mode} -> {:error, :lease_held}
      _other -> {:error, :not_fresh}
    end
  end

  def acquire_lease(root, mode, opts)
      when is_binary(root) and mode in [:provisioning, :run] and is_list(opts) do
    case classify(root, :unknown) do
      {:bound, %{sha256: binding}} ->
        write_lease(root, mode, new_nonce(), %{"binding_sha256" => binding})

      {:leased, _mode} ->
        {:error, :lease_held}

      _other ->
        {:error, :not_bound}
    end
  end

  @doc """
  Phase P5: removes the lease, and nothing else, when it is the held lease
  of `mode` with `nonce` (`:lease_missing`, `:lease_invalid`,
  `:lease_mismatch`) and that mode's receipts are present (else
  `:receipts_missing`) and valid (`:invalid_file`):

    * bootstrap: the four step receipts of `nonce` and `environment.json`,
      with a history consistent with them (the pending marker and
      `environment.created.json` of `nonce`; the environment's nonce,
      database and oid those of the created file, its tenant the probe's;
      else `:binding_inconsistent`);
    * provisioning: `instance.<nonce>.provision.exit`;
    * run: `instance.<nonce>.exit`, whose `boot_id` must be that of a valid
      boot marker `instance.<nonce>.boot` (an absent, invalid or different
      marker is `:boot_id_mismatch`).

  A refusal changes no file.
  """
  @spec release(Path.t(), :bootstrap | :provisioning | :run, String.t()) ::
          :ok
          | {:error,
             :lease_missing
             | :lease_invalid
             | :lease_mismatch
             | :receipts_missing
             | :invalid_file
             | :binding_inconsistent
             | :boot_id_mismatch
             | :write_failed}
  def release(root, mode, nonce)
      when is_binary(root) and mode in [:bootstrap, :provisioning, :run] do
    with {:ok, sha256, lease} <- held_lease(root),
         :ok <- same_lease(lease, mode, nonce),
         :ok <- released(root, mode, nonce) do
      remove_lease(root, sha256)
    end
  end

  @doc """
  Classifies `<root>/state/` given the database facts the caller observed
  (`:unknown`, `:absent` or `{:present, %{database_oid:, tenant_id:}}`).
  It reads only, and creates or changes nothing.

    * `{:quarantine, :state_unavailable}` — the root or `state` is not a
      physical directory, or cannot be listed (an absent `state/` in a
      physical root is no files);
    * `{:quarantine, :unrecognised_file}` / `{:quarantine, :invalid_file}` —
      any file that is not a state file name, or does not read valid;
    * `{:leased, mode}` — a valid lease over that recognised, valid history
      (held or stale; every launch refuses it);
    * `{:bound, %{sha256, data}}` — `environment.json` with its whole
      bootstrap history (pending and created of its nonce, the four step
      receipts of that nonce, the probe's tenant) and database facts that
      agree (`:unknown`, or present with its oid and tenant). Otherwise
      `:binding_inconsistent` (also for facts `:absent`),
      `:missing_bootstrap_receipt`, `:database_oid_mismatch` or
      `:tenant_mismatch`. Boot markers, run receipts, provision receipts and
      the S2 authorization files are recognised and do not unbind;
    * with no environment: `:pending_without_environment`,
      `:created_without_pending`, `:database_without_pending` (present
      facts), `:binding_inconsistent` (other history), or `:fresh`.
  """
  @spec classify(Path.t(), db_facts()) ::
          :fresh
          | {:bound, %{sha256: String.t(), data: map()}}
          | {:leased, String.t()}
          | {:quarantine, atom()}
  def classify(root, facts) when is_binary(root) do
    with {:ok, names} <- state_names(root),
         {:ok, views} <- valid_views(root, names) do
      classify_views(views, facts)
    end
  end

  defp new_nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp bootstrap_lease(root, nonce) do
    pending = %{
      "environment_id" => AgentEnv.environment_id(),
      "nonce" => nonce,
      "started_at" => DateTime.utc_now()
    }

    case create(root, :pending, pending) do
      {:ok, _sha256} -> write_lease(root, :bootstrap, nonce, @bootstrap_target)
      {:error, :exists} -> {:error, :not_fresh}
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp write_lease(root, mode, nonce, target) do
    lease = %{
      "environment_id" => AgentEnv.environment_id(),
      "mode" => Atom.to_string(mode),
      "nonce" => nonce,
      "target" => target,
      "port" => if(mode == :run, do: AgentEnv.http_port()),
      "started_at" => DateTime.utc_now()
    }

    case create(root, :lease, lease) do
      {:ok, _sha256} -> {:ok, nonce}
      {:error, :exists} -> {:error, :lease_held}
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp held_lease(root) do
    case read(root, :lease) do
      {:valid, sha256, lease} -> {:ok, sha256, lease}
      :absent -> {:error, :lease_missing}
      {:invalid, _reason} -> {:error, :lease_invalid}
    end
  end

  defp same_lease(lease, mode, nonce) do
    if lease["mode"] == Atom.to_string(mode) and is_binary(nonce) and lease["nonce"] == nonce,
      do: :ok,
      else: {:error, :lease_mismatch}
  end

  defp released(root, :bootstrap, nonce) do
    names = Enum.map(@bootstrap_steps, &{:receipt, nonce, &1}) ++ [:environment]
    views = Map.new(names, &{&1, read(root, &1)})

    with :ok <- present_and_valid(Map.values(views)) do
      bootstrap_history(root, nonce, views)
    end
  end

  defp released(root, :provisioning, nonce),
    do: present_and_valid([read(root, {:receipt, nonce, :provision})])

  defp released(root, :run, nonce) do
    receipt = read(root, {:run_receipt, nonce})

    with :ok <- present_and_valid([receipt]) do
      {:valid, _sha256, %{"boot_id" => boot_id}} = receipt

      case read(root, {:boot, nonce}) do
        {:valid, _sha256, %{"boot_id" => ^boot_id}} -> :ok
        _absent_invalid_or_different -> {:error, :boot_id_mismatch}
      end
    end
  end

  defp present_and_valid(views) do
    cond do
      Enum.any?(views, &(&1 == :absent)) -> {:error, :receipts_missing}
      Enum.any?(views, &match?({:invalid, _reason}, &1)) -> {:error, :invalid_file}
      true -> :ok
    end
  end

  # The released bootstrap's history: pending and created of `nonce`, and
  # an environment of that nonce, created database and probe tenant.
  defp bootstrap_history(root, nonce, views) do
    {:valid, _sha256, environment} = views[:environment]
    {:valid, _sha256, probe} = views[{:receipt, nonce, :probe}]

    with {:valid, _sha256, %{"nonce" => ^nonce}} <- read(root, :pending),
         {:valid, _sha256, created} <- read(root, :created),
         true <- created_matches?(created, environment),
         true <- environment["nonce"] == nonce,
         true <- environment["tenant_id"] == probe["tenant_id"] do
      :ok
    else
      _inconsistent -> {:error, :binding_inconsistent}
    end
  end

  defp created_matches?(created, environment) do
    created["nonce"] == environment["nonce"] and created["database"] == environment["database"] and
      created["database_oid"] == environment["database_oid"]
  end

  # Removes the lease only while it is still the one that was checked.
  defp remove_lease(root, sha256) do
    case read(root, :lease) do
      {:valid, ^sha256, _lease} ->
        case File.rm(path(root, :lease)) do
          :ok -> :ok
          {:error, _reason} -> {:error, :write_failed}
        end

      _changed ->
        {:error, :lease_mismatch}
    end
  end

  # The names of the files in `<root>/state/` (an absent directory in a
  # physical root is none), or a quarantine.
  defp state_names(root) do
    dir = Path.join(root, "state")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, files} <- state_files(dir) do
      names = Enum.map(files, &state_name/1)

      if Enum.any?(names, &is_nil/1),
        do: {:quarantine, :unrecognised_file},
        else: {:ok, names}
    else
      _unavailable -> {:quarantine, :state_unavailable}
    end
  end

  defp state_files(dir) do
    case File.lstat(dir) do
      {:error, :enoent} -> {:ok, []}
      {:ok, %File.Stat{type: :directory}} -> File.ls(dir)
      _other -> {:error, :state_unavailable}
    end
  end

  defp state_name(file) do
    case Map.fetch(@fixed_files, file) do
      {:ok, name} -> name
      :error -> instance_name(String.split(file, "."))
    end
  end

  defp instance_name(["instance", nonce, step, "exit"]) do
    case Map.fetch(@step_names, step) do
      {:ok, step} -> if nonce?(nonce), do: {:receipt, nonce, step}
      :error -> nil
    end
  end

  defp instance_name(["instance", nonce, "boot"]), do: if(nonce?(nonce), do: {:boot, nonce})

  defp instance_name(["instance", nonce, "exit"]),
    do: if(nonce?(nonce), do: {:run_receipt, nonce})

  defp instance_name(_other), do: nil

  defp valid_views(root, names) do
    views = Map.new(names, &{&1, read(root, &1)})

    if Enum.all?(views, &match?({_name, {:valid, _sha256, _data}}, &1)),
      do: {:ok, Map.new(views, fn {name, {:valid, sha256, data}} -> {name, {sha256, data}} end)},
      else: {:quarantine, :invalid_file}
  end

  defp classify_views(%{lease: {_sha256, %{"mode" => mode}}}, _facts), do: {:leased, mode}
  defp classify_views(%{environment: _} = views, facts), do: bound(views, facts)

  defp classify_views(views, facts) do
    cond do
      Map.has_key?(views, :pending) -> {:quarantine, :pending_without_environment}
      Map.has_key?(views, :created) -> {:quarantine, :created_without_pending}
      match?({:present, _facts}, facts) -> {:quarantine, :database_without_pending}
      views == %{} -> :fresh
      true -> {:quarantine, :binding_inconsistent}
    end
  end

  defp bound(views, facts) do
    {sha256, environment} = views[:environment]
    nonce = environment["nonce"]
    receipts = Enum.map(@bootstrap_steps, &Map.get(views, {:receipt, nonce, &1}))

    cond do
      not history?(views, environment) -> {:quarantine, :binding_inconsistent}
      Enum.any?(receipts, &is_nil/1) -> {:quarantine, :missing_bootstrap_receipt}
      not probe_tenant?(views, environment) -> {:quarantine, :binding_inconsistent}
      stray_receipts?(views, nonce) -> {:quarantine, :binding_inconsistent}
      true -> with_facts(facts, sha256, environment)
    end
  end

  defp history?(views, environment) do
    nonce = environment["nonce"]

    with {_sha256, %{"nonce" => ^nonce}} <- views[:pending],
         {_sha256, created} <- views[:created] do
      created_matches?(created, environment)
    else
      _missing_or_other_nonce -> false
    end
  end

  defp probe_tenant?(views, environment) do
    {_sha256, probe} = views[{:receipt, environment["nonce"], :probe}]
    probe["tenant_id"] == environment["tenant_id"]
  end

  # Bootstrap step receipts of any other nonce cannot belong to this binding.
  defp stray_receipts?(views, nonce) do
    Enum.any?(Map.keys(views), fn
      {:receipt, other, step} -> step in @bootstrap_steps and other != nonce
      _name -> false
    end)
  end

  defp with_facts(:unknown, sha256, environment),
    do: {:bound, %{sha256: sha256, data: environment}}

  defp with_facts(:absent, _sha256, _environment), do: {:quarantine, :binding_inconsistent}

  defp with_facts({:present, %{database_oid: oid, tenant_id: tenant_id}}, sha256, environment) do
    cond do
      oid != environment["database_oid"] -> {:quarantine, :database_oid_mismatch}
      tenant_id != environment["tenant_id"] -> {:quarantine, :tenant_mismatch}
      true -> {:bound, %{sha256: sha256, data: environment}}
    end
  end

  defp encode(data) do
    case Canonical.encode(data) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      _other -> :error
    end
  rescue
    _error -> :error
  end

  defp publish(file, bytes, sha256) do
    temporary = Path.join(Path.dirname(file), ".#{Path.basename(file)}.#{temporary_suffix()}.tmp")
    outcome = with :ok <- write_private(temporary, bytes), do: make_link(temporary, file)
    _ = File.rm(temporary)

    case outcome do
      :ok -> {:ok, sha256}
      {:error, :eexist} -> {:error, :exists}
      _error -> {:error, :write_failed}
    end
  end

  defp write_private(temporary, bytes) do
    case :file.open(String.to_charlist(temporary), [:write, :exclusive, :binary]) do
      {:ok, device} -> write_device(device, temporary, bytes)
      error -> error
    end
  end

  defp write_device(device, temporary, bytes) do
    with :ok <- :file.write(device, bytes),
         :ok <- :file.sync(device) do
      File.chmod(temporary, 0o600)
    end
  after
    :file.close(device)
  end

  defp make_link(temporary, file),
    do: :file.make_link(String.to_charlist(temporary), String.to_charlist(file))

  defp temporary_suffix, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp file_name(:pending), do: "environment.pending"
  defp file_name(:lease), do: "instance.lease"
  defp file_name(:created), do: "environment.created.json"
  defp file_name(:environment), do: "environment.json"
  defp file_name(:claim), do: "authorization.claim.json"
  defp file_name(:authorization), do: "authorization.json"

  defp file_name({:receipt, nonce, step}) when step in @steps do
    if nonce?(nonce), do: "instance.#{nonce}.#{step}.exit", else: invalid_name!({:receipt, nonce})
  end

  defp file_name({:boot, nonce} = name),
    do: if(nonce?(nonce), do: "instance.#{nonce}.boot", else: invalid_name!(name))

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

  defp checks({:boot, _nonce}),
    do: %{"nonce" => :nonce, "boot_id" => :boot_id, "booted_at" => :timestamp}

  defp checks({:run_receipt, _nonce}),
    do: %{"nonce" => :nonce, "boot_id" => :boot_id, "completed_at" => :timestamp}

  defp extra(:probe), do: %{"tenant_id" => :uuid}

  defp extra(:provision),
    do: %{"authorization_id" => :authorization_id, "grant_id" => :uuid, "event_id" => :uuid}

  defp extra(_step), do: %{}

  defp valid_value?(:any, _value), do: true
  defp valid_value?(:environment_id, value), do: value == AgentEnv.environment_id()
  defp valid_value?(:nonce, value), do: nonce?(value)
  defp valid_value?(:boot_id, value), do: hex?(value, 32)
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

  defp consistent?(data, {:boot, nonce}), do: data["nonce"] == nonce
  defp consistent?(data, {:run_receipt, nonce}), do: data["nonce"] == nonce
  defp consistent?(_data, _name), do: true

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
