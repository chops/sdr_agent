defmodule SdrAgent.CalibrationConsole.Evidence do
  @moduledoc """
  The calibration evidence file (R0-07 slice E, rows R10-4 and R11-3;
  harness round 13, entity PASS at 094caa86; staged E2 contract in the
  packet).

  One file per invocation, `r0-calibration-<profile>-<invocation id>.json`
  (`file_name/2`), in an owner-only directory: mode 0700, owned by this
  user, and neither it nor any ancestor a symlink. The file is mode 0600
  and holds the canonical bytes (`sdr-canonical-json/1`) of a document in
  the closed schema `r0-calibration-evidence/1`. It carries metadata only:
  no prompt, response, output or error text, and no release or latch data
  (the latch is created from the file's hash, never the reverse).

  `publish/3` is create-only. The document is first checked against the
  closed schema and its own target (as `validate/3` checks a file), then
  written to a temporary file in the same directory, synced, made 0600 and
  hard-linked to the final name, which fails if the name exists. The first
  file published **is** the frozen observation: a later or concurrent
  publish never replaces or recomputes it; it validates the existing file
  and returns its exact bytes and hash.

  `validate/3` recomputes nothing. It requires the directory to be safe as
  above (checked again on every validation), a regular file (not a
  symlink), mode 0600, owned by this user, with the deterministic name, in
  canonical form and the closed schema, naming the target's invocation,
  run, tenant and profile, and:

    * prompt and schema commitments among the code-owned definitions
      (`SdrAgent.CalibrationConsole.Prompt.prompt_refs/0`, current and
      historical) and equal to the invocation's immutable reservation;
    * the candidate exactly the tuple recorded by the invocation's original
      reservation event (`SdrAgent.Agents.Admission.Gate.recorded_tuple/1`,
      pinned to that time's versions);
    * attested values that are the candidate's CLI version and model as a
      pair, or both null; never other text;
    * the invocation's recorded status, validation status and timestamps,
      and an output commitment equal to the SHA-256 of the canonical parsed
      output (null without one);
    * every link it names existing, belonging to the invocation and carrying
      the evidence hash it recorded (`Canonical.sha256(link.evidence)`), and
      the evaluated projection and method of one of those links (both null
      without links). Links are immutable, so a later successor never
      invalidates the historical reference;
    * when a `:calibration` latch exists, its `evidence_sha256` equal to
      this file's hash: a changed, replaced or missing file under a latch is
      a conflict, and the original bytes replay unchanged. A new file is
      created only while the invocation has no release at all, so a missing
      file under a latch is never recreated, even from identical bytes;
    * every timestamp a canonical UTC timestamp (six fraction digits and
      `Z`), never other text.

  **Durability (limited).** The temporary file is written and synced before
  it is made 0600 and linked, so a process crash leaves either no final
  name or the complete file. The directory entry itself is not synced (the
  runtime has no directory fsync), so a power loss may lose a just-created
  name; the latch is decided only after `publish/3` returns, and a missing
  file under an existing latch is a conflict for the owner, never
  recreated.

  Errors: `:evidence_schema` (a document outside the closed schema, or an
  identifier that is not a plain id), `:evidence_dir_unsafe`, and
  `:calibration_evidence_conflict` for anything else, including a failed
  write, sync, chmod or link (never raised; nothing is published). No file
  I/O happens
  under a database lock, and nothing is logged. The row checks use the
  test-seam calibration read; outside test-seam builds every publish and
  validation is a conflict.
  """

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @doc "The deterministic file name of `invocation_id`'s evidence for `profile_id`."
  def file_name(profile_id, invocation_id),
    do: "r0-calibration-#{profile_id}-#{invocation_id}.json"

  if @test_seams do
    import Bitwise

    require Ash.Query

    alias SdrAgent.Agents.Checks.CalibrationContext
    alias SdrAgent.Agents.Admission.Gate
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ModelResultRelease
    alias SdrAgent.Agents.WireWitnessLink

    alias SdrAgent.AI.ModelProfiles
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.CalibrationConsole.Outcome
    alias SdrAgent.CalibrationConsole.Prompt

    @schema "r0-calibration-evidence/1"
    @keys ~w(schema canonicalization invocation_id run_id tenant_id profile_id candidate
             evaluated_projection_version evaluated_method outcome links inventory_sha256
             prompt output_schema attested_cli_version attested_model_id invocation_status
             validation_status output_sha256 reserved_at sent_at completed_at observed_at)
    @candidate_keys ~w(provider cli_version profile_id model_id projection_version method)
    @ref_keys ~w(id version sha256)
    @link_keys ~w(evidence_sha256 id)
    @nullable ~w(evaluated_projection_version evaluated_method attested_cli_version
                 attested_model_id sent_at completed_at)
    @required ~w(invocation_status validation_status reserved_at observed_at)
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @sha256 ~r/\A[0-9a-f]{64}\z/
    @timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
    @conflict {:error, :calibration_evidence_conflict}

    @type result ::
            {:ok, %{path: Path.t(), sha256: String.t(), bytes: binary()}}
            | {:error, :evidence_schema | :evidence_dir_unsafe | :calibration_evidence_conflict}

    @doc """
    Read-only: `:ok` when `dir` is a safe evidence directory by the rule
    `publish/3` applies (0700, this user's, no symlink in it or any
    ancestor), otherwise `{:error, :evidence_dir_unsafe}` (packet 8.14.9
    round 4). Nothing is changed.
    """
    def check_dir(dir), do: safe_dir(dir)

    @doc "Publishes `document` create-only in `dir` (see the moduledoc)."
    @spec publish(Path.t(), map(), keyword()) :: result()
    def publish(dir, document, opts) do
      with {:ok, decoded} <- schema(document),
           :ok <- safe_dir(dir) do
        target = target(decoded)
        path = Path.join(dir, file_name(target.profile_id, target.invocation_id))

        # An existing name (even a dangling symlink) is validated, never
        # replaced.
        if match?({:ok, _}, File.lstat(path)) do
          validate(path, target, opts)
        else
          create(dir, path, decoded, target, opts)
        end
      end
    end

    @doc "Validates the evidence file at `path` for `target` (see the moduledoc)."
    @spec validate(Path.t(), map(), keyword()) :: result()
    def validate(path, target, opts) do
      with :ok <- safe_dir(Path.dirname(path)),
           {:ok, bytes} <- private_file(path),
           {:ok, decoded} <- canonical(bytes),
           :ok <- named(path, target),
           sha = hex(:crypto.hash(:sha256, bytes)),
           :ok <- consistent(decoded, target, opts, {:existing, sha}) do
        {:ok, %{path: path, sha256: sha, bytes: bytes}}
      else
        _ -> @conflict
      end
    end

    ## Publishing

    defp create(dir, path, decoded, target, opts) do
      bytes = Canonical.encode!(decoded)

      # Initial creation only: an existing latch means the frozen file is
      # missing, and a missing file is never recreated (even identically).
      case consistent(decoded, target, opts, {:create, hex(:crypto.hash(:sha256, bytes))}) do
        :ok -> link_new(dir, path, bytes, target, opts)
        _inconsistent -> @conflict
      end
    end

    # A temporary file in the same directory, synced and 0600, hard-linked to
    # the final name; the link fails if the name exists (create-only).
    defp link_new(dir, path, bytes, target, opts) do
      temp =
        Path.join(dir, ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))

      try do
        with :ok <- write_synced(temp, bytes),
             :ok <- File.ln(temp, path) do
          {:ok, %{path: path, sha256: hex(:crypto.hash(:sha256, bytes)), bytes: bytes}}
        else
          {:error, :eexist} -> validate(path, target, opts)
          _write_or_link_failed -> @conflict
        end
      after
        File.rm(temp)
      end
    end

    # `:ok`, or the failure of any step (never raised; the caller removes the
    # temporary file and publishes nothing).
    defp write_synced(temp, bytes) do
      case :file.open(temp, [:write, :exclusive, :binary, :raw]) do
        {:ok, file} ->
          result =
            try do
              with :ok <- :file.write(file, bytes), do: :file.sync(file)
            after
              :file.close(file)
            end

          with :ok <- result, do: File.chmod(temp, 0o600)

        {:error, _reason} = error ->
          error
      end
    end

    # The directory is 0700 and this user's; neither it nor an ancestor is a
    # symlink.
    defp safe_dir(dir) do
      expanded = Path.expand(dir)

      with true <- no_symlink?(expanded),
           {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}} <- File.lstat(expanded),
           {:ok, me} <- uid(),
           true <- (mode &&& 0o777) == 0o700 and uid == me do
        :ok
      else
        _ -> {:error, :evidence_dir_unsafe}
      end
    end

    defp no_symlink?(path) do
      path
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))
    end

    # `{:ok, uid}` of this process: the owner of a file it has just created
    # (no external command is launched), or `:error`.
    defp uid do
      probe =
        Path.join(
          System.tmp_dir!(),
          ".sdr-uid-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
        )

      case :file.open(probe, [:write, :exclusive, :raw]) do
        {:ok, file} ->
          :file.close(file)
          probe_owner(probe)

        _cannot_create ->
          :error
      end
    end

    defp probe_owner(probe) do
      case File.lstat(probe) do
        {:ok, %File.Stat{uid: uid}} -> {:ok, uid}
        _ -> :error
      end
    after
      File.rm(probe)
    end

    ## The file

    defp private_file(path) do
      with {:ok, %File.Stat{type: :regular, mode: mode, uid: uid}} <- File.lstat(path),
           {:ok, me} <- uid(),
           true <- (mode &&& 0o777) == 0o600 and uid == me,
           {:ok, bytes} <- File.read(path) do
        {:ok, bytes}
      else
        _ -> :error
      end
    end

    # Canonical bytes of a closed-schema document.
    defp canonical(bytes) do
      with {:ok, decoded} <- Jason.decode(bytes),
           {:ok, ^decoded} <- schema(decoded),
           true <- Canonical.encode!(decoded) == bytes do
        {:ok, decoded}
      else
        _ -> :error
      end
    end

    defp named(path, target) do
      if Path.basename(path) == file_name(target.profile_id, target.invocation_id),
        do: :ok,
        else: :error
    end

    ## The closed schema

    # `{:ok, decoded}` (string keys, as JSON) or `{:error, :evidence_schema}`.
    defp schema(document) do
      decoded = Canonical.normalize(document)

      if is_map(decoded) and closed?(decoded),
        do: {:ok, decoded},
        else: {:error, :evidence_schema}
    rescue
      _ -> {:error, :evidence_schema}
    end

    defp closed?(doc), do: Enum.all?(checks(), & &1.(doc))

    defp checks do
      [
        &(Enum.sort(Map.keys(&1)) == Enum.sort(@keys)),
        &(&1["schema"] == @schema and &1["canonicalization"] == Canonical.version()),
        &Enum.all?(~w(invocation_id run_id tenant_id), fn key -> uuid?(&1[key]) end),
        &(real_profile?(&1["profile_id"]) and &1["outcome"] in Outcome.values()),
        &keyed?(&1["candidate"], @candidate_keys),
        &(ref?(&1["prompt"]) and ref?(&1["output_schema"]) and links?(&1["links"])),
        &Enum.all?(~w(inventory_sha256 output_sha256), fn key -> nullable_sha?(&1[key]) end),
        &Enum.all?(@nullable, fn key -> nullable_string?(&1[key]) end),
        &Enum.all?(@required, fn key -> is_binary(&1[key]) end),
        &Enum.all?(~w(reserved_at observed_at), fn key -> timestamp?(&1[key]) end),
        &Enum.all?(~w(sent_at completed_at), fn key -> is_nil(&1[key]) or timestamp?(&1[key]) end)
      ]
    end

    # A canonical UTC timestamp (`sdr-canonical-json/1`: six fraction digits
    # and `Z`) that round-trips exactly; never other text.
    defp timestamp?(value) when is_binary(value) do
      with true <- value =~ @timestamp,
           {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
        Canonical.normalize(datetime) == value
      else
        _ -> false
      end
    end

    defp timestamp?(_value), do: false

    defp uuid?(value), do: is_binary(value) and value =~ @uuid
    defp sha?(value), do: is_binary(value) and value =~ @sha256
    defp nullable_sha?(value), do: is_nil(value) or sha?(value)
    defp nullable_string?(value), do: is_nil(value) or is_binary(value)

    defp real_profile?(value) when is_binary(value),
      do: Enum.any?(ModelProfiles.real_ids(), &(Atom.to_string(&1) == value))

    defp real_profile?(_value), do: false

    defp keyed?(map, keys) when is_map(map),
      do: Enum.sort(Map.keys(map)) == Enum.sort(keys) and Enum.all?(Map.values(map), &is_binary/1)

    defp keyed?(_map, _keys), do: false

    defp ref?(ref), do: keyed?(ref, @ref_keys) and sha?(ref["sha256"])

    defp links?(links) when is_list(links) do
      Enum.all?(
        links,
        &(keyed?(&1, @link_keys) and uuid?(&1["id"]) and sha?(&1["evidence_sha256"]))
      )
    end

    defp links?(_links), do: false

    defp target(doc) do
      %{
        invocation_id: doc["invocation_id"],
        run_id: doc["run_id"],
        tenant_id: doc["tenant_id"],
        profile_id: doc["profile_id"]
      }
    end

    ## Consistency with the target and its rows

    # `{:existing, sha}` for a file on disk, `{:create, sha}` for a new one;
    # `sha` is the SHA-256 of its bytes.
    defp consistent(doc, target, opts, commitment) do
      target = Map.update!(target, :profile_id, &to_string/1)

      with true <- target(doc) == target,
           true <- doc["prompt"] in Enum.map(Prompt.prompt_refs(), &ref/1),
           true <- doc["output_schema"] in Enum.map(Prompt.schema_refs(), &ref/1),
           {:ok, invocation} <- invocation(target, Keyword.get(opts, :actor)),
           true <- recorded?(doc, invocation, target),
           true <- candidate?(doc, invocation),
           true <- attested?(doc),
           {:ok, links} <- links(doc["links"], invocation),
           true <- evaluated?(doc, links),
           :ok <- latch(invocation, commitment) do
        :ok
      else
        _ -> :error
      end
    end

    # The candidate is exactly the tuple admission recorded on the
    # invocation's original reservation event (pinned to the versions of
    # that time, never today's profile).
    defp candidate?(doc, invocation) do
      case Gate.recorded_tuple(invocation) do
        {:ok, entry} -> doc["candidate"] == Gate.tuple_record(entry)
        _none_or_invalid -> false
      end
    end

    # Observed init values: the candidate's own CLI version and model as a
    # pair, or both null (no valid init); never other text.
    defp attested?(%{"attested_cli_version" => nil, "attested_model_id" => nil}), do: true

    defp attested?(%{"candidate" => candidate} = doc) do
      doc["attested_cli_version"] == candidate["cli_version"] and
        doc["attested_model_id"] == candidate["model_id"]
    end

    # The evaluated projection and method are one named link's, or both
    # null without links.
    defp evaluated?(%{"evaluated_projection_version" => nil, "evaluated_method" => nil}, []),
      do: true

    defp evaluated?(doc, links) do
      Enum.any?(links, fn link ->
        {doc["evaluated_projection_version"], doc["evaluated_method"]} ==
          {link.evidence["projection_version"], to_string(link.method)}
      end)
    end

    # An existing file must be the one an existing calibration latch commits
    # (or there is no latch yet); a new file may be created only while there
    # is no release at all. Anything else is a conflict.
    defp latch(invocation, {mode, sha}) do
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        model_invocation_id == ^invocation.id and tenant_id == ^invocation.tenant_id
      )
      |> Ash.read_one()
      |> case do
        {:ok, nil} -> :ok
        {:ok, %{disposition: :calibration, evidence_sha256: ^sha}} when mode == :existing -> :ok
        _other -> :error
      end
    end

    defp ref(%{id: id, version: version, sha256: sha}),
      do: %{"id" => id, "version" => version, "sha256" => hex(sha)}

    # The invocation's immutable reservation and recorded outcome.
    defp recorded?(doc, invocation, target) do
      invocation.agent_run_id == target.run_id and
        to_string(invocation.profile_id) == target.profile_id and
        reservation(invocation) == %{"prompt" => doc["prompt"], "schema" => doc["output_schema"]} and
        doc["invocation_status"] == to_string(invocation.status) and
        doc["validation_status"] == to_string(invocation.validation_status) and
        Enum.all?(~w(reserved_at sent_at completed_at)a, fn field ->
          doc[Atom.to_string(field)] == Canonical.normalize(Map.get(invocation, field))
        end) and
        doc["output_sha256"] == output_commitment(invocation.parsed_output)
    end

    defp reservation(invocation) do
      %{
        "prompt" => %{
          "id" => invocation.prompt_template_id,
          "version" => invocation.prompt_template_version,
          "sha256" => hex(invocation.prompt_template_sha256)
        },
        "schema" => %{
          "id" => invocation.output_schema_id,
          "version" => invocation.output_schema_version,
          "sha256" => hex(invocation.output_schema_sha256)
        }
      }
    end

    defp output_commitment(nil), do: nil
    defp output_commitment(output) when is_map(output), do: hex(Canonical.sha256(output))
    defp output_commitment(_forbidden_or_other), do: :unreadable

    # The named links, each of this invocation with the evidence hash it
    # recorded: `{:ok, rows}` or `:error`.
    defp links(refs, invocation) do
      Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
        case recorded_link(ref, invocation) do
          {:ok, row} -> {:cont, {:ok, [row | acc]}}
          :error -> {:halt, :error}
        end
      end)
    end

    defp recorded_link(%{"id" => id, "evidence_sha256" => sha}, invocation) do
      with {:ok, row} <- link(id, invocation),
           true <- hex(Canonical.sha256(row.evidence)) == sha do
        {:ok, row}
      else
        _missing_foreign_or_changed -> :error
      end
    end

    # The bound proof invocation through the audited calibration read, as
    # this tenant's AGT.
    defp invocation(target, %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant_id} = actor)
         when tenant_id == target.tenant_id do
      profile = Enum.find(ModelProfiles.real_ids(), &(Atom.to_string(&1) == target.profile_id))

      ModelInvocation
      |> Ash.Query.for_read(:read, %{},
        actor: actor,
        context: CalibrationContext.context(profile, target.invocation_id)
      )
      |> Ash.Query.filter(id == ^target.invocation_id and tenant_id == ^tenant_id)
      |> Ash.read_one()
      |> case do
        {:ok, %ModelInvocation{} = invocation} -> {:ok, invocation}
        _ -> :error
      end
    end

    defp invocation(_target, _actor), do: :error

    defp link(id, invocation) do
      WireWitnessLink
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        id == ^id and tenant_id == ^invocation.tenant_id and
          model_invocation_id == ^invocation.id
      )
      |> Ash.read_one()
      |> case do
        {:ok, %WireWitnessLink{} = link} -> {:ok, link}
        _ -> :error
      end
    end

    defp hex(bytes) when is_binary(bytes), do: Base.encode16(bytes, case: :lower)
  else
    @doc "Outside test-seam builds no calibration evidence is published."
    def publish(_dir, _document, _opts), do: {:error, :calibration_evidence_conflict}

    @doc "Outside test-seam builds no evidence directory is usable."
    def check_dir(_dir), do: {:error, :calibration_evidence_conflict}

    @doc "Outside test-seam builds no calibration evidence validates."
    def validate(_path, _target, _opts), do: {:error, :calibration_evidence_conflict}
  end
end
