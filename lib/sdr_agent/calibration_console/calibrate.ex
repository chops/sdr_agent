if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.CalibrationConsole.Calibrate do
    @moduledoc """
    The console's `calibrate <profile>` (R0-07 slice E, d3c; packet 8.14.1,
    8.14.4, 8.14.8 and 8.14.9; entity/action PASS at 125102e, 623e7db and
    babd986) and the evidence document of its one call.

    ## The command

    `run/2` performs one calibration call of `profile_id` and returns
    `{:ok, summary}` or `{:stop, reason, summary}`, where `summary` is
    `%{record: :none | :released | {:kept, state}, invocation_id:, outcome:,
    evidence: %{path, sha256} | nil}` and `reason` an atom. Every decision
    after the call reads the fresh committed row; the matrix (8.14.4) is
    followed branch by branch:

      1. the closed options (`:calibration_options_invalid`), the tenant
         (`:console` is the singleton, read by the kernel actor; a test UUID
         must exist), and the fixed `CalibrationConsole` v1 definition,
         registered by that tenant's kernel actor and verified (tenant,
         name, version, module, body and hash, active) — all before the
         claim, which then follows (row 1);
      2. preflight: the pinned CLI (`verify`), a trusted witness store,
         G-R0, the owner's typed `CALIBRATE <profile>`, and the isolation
         check (row 2 aborts and releases; row 3 keeps the claim);
      3. the private server (unnamed, linked), the proof run (8.14.9
         attributes) and the reservation under the calibration marker
         (rows 4 and 5);
      4. `launch_pending`, the sealed authority (row 7), the one call
         through `ModelProvider.calibration_call/3`, then the launch receipt
         read from this command's mailbox only after the call (rows 8–10);
      5. admission open and quiescence observed (rows 11 and 12), the one
         bounded observation (`ResultGate.await/3` with the candidate), the
         document, `Evidence.publish/3`, `finish_calibration` (E1),
         `finished` and the release (row 13).

    A launch refused with a typed receipt is stopped through
    `SDR.Model.stop_refused/3` before E1 (8.14.9). The command is the only
    writer of the launch record. The authority is revoked and the private
    server stopped on every path; neither ever masks the stop reported.
    `hook:` (tests only) is called with `:before_issue` and `:before_call`
    and its return value is ignored; a raising hook keeps the record.

    `command/1` maps the subcommand's argv to `{:run, profile_id,
    console_opts(profile_id)}`; `console_opts/1` holds the console's fixed
    options (no hook, no server, isolation or record override).

    ## Recovery

    `recover/2` (d3d, packet 8.14.11; contract PASS at 5153ad3) recovers a
    stale launch record for `invocation_id` (a UUID, or nil only for an
    `aborted` record that never reserved) and returns `{:ok, summary}` or
    `{:stop, reason, summary}`, `summary` being `run/2`'s plus `ticket:
    :none | :ended | :kept | :released`. In order:

      1. the closed options (`run/2`'s value rules plus a boolean `stopped`;
         no hook, server or isolation: recovery makes no call) and the id,
         then the tenant, all before any filesystem access;
      2. the lock (`LaunchRecord.recover/2`): a refusal creates nothing, and
         an existing ticket is never adopted (`:recovery_in_progress`);
      3. the target, before any effect: the tenant's ClaudeCLI invocations
         whose one original reservation event records this record's claim
         must be exactly the one requested (and the one the record names),
         and it must be a generation-2 row of a real profile, bound to its
         recorded tuple, under a `:proof` run with no Operation;
      4. the state matrix: the unlaunched path (`RECOVER <id>`, unlaunched
         recovery of a reserved row, evidence, latch, `aborted`, release);
         the attested path (`stopped: true`, live work observed before the
         `STOPPED <id>` prompt, then the attestation event, its file in the
         ticket, evidence, latch, `recovered`, release); the final replay of
         an `aborted` or `finished` record whose target history and latched
         file are exactly what it attests; and the nil-target release of an
         `aborted` record with no candidate (`RECOVER ABORTED`).

    Evidence is a latch's own file, else an existing unlatched file (the
    frozen observation), each reused unchanged and never replaced; only
    with neither is a document built: `gate: nil` when unlaunched, or one
    bounded `ResultGate.await/3` with the recorded tuple, outside any lock,
    whose CLI init attestation stays nil. A stop before any effect ends this
    call's own bare ticket (`:ended`, or `:kept` when ending fails); after
    an effect the ticket is never ended (`:kept`). `recover_command/1` and
    `recover_opts/1` are the `calibrate-recover` subcommand's argv and fixed
    options.

    ## The document

    `document/1` is pure. It takes the snapshots the command gathered outside
    any database lock and builds the `r0-calibration-evidence/1` document
    that `SdrAgent.CalibrationConsole.Evidence.publish/3` takes:

      * `invocation` and `run`: the fresh committed rows (the run must be the
        invocation's own);
      * `tuple`: the candidate the invocation's original reservation event
        recorded (`SdrAgent.Agents.Admission.Gate.recorded_tuple/1`);
      * `gate`: `ResultGate.await/3`'s own `{:ok | :timeout, receipt}`, or nil
        on the unlaunched path (no await);
      * `link`: the receipt's own link (`receipt.link_id`), or nil when the
        receipt names none;
      * `attestation`: the server's init attestation after the call, or nil;
      * `output`: the parsed output read through the scoped calibration read,
        nil only when the row has none;
      * `observed_at`: the one clock read after the await.

    The outcome and the evaluated and attested fields are
    `SdrAgent.CalibrationConsole.Outcome.classify/1` of those snapshots. The
    document names only the receipt's own link, with its evidence hash and
    its validated `inventory_sha256`. Digests are lowercase hex and times are
    microsecond-precision UTC. No prompt, response, output or error text
    enters it.

    It exists only in test-seam builds (packet 8.14.1): a non-seam build has
    neither the module nor the `calibrate` subcommand path.

    Only a genuine observation builds a document: a sent call needs the
    await's own `{:ok | :timeout, receipt}`, and a nil `gate` is only the
    unlaunched path (`sent_at` nil), whose `launch_failed` outcome is built
    without evaluation or attestation and without inventing a receipt.

    Inconsistent or malformed snapshots are `{:error,
    :evidence_input_invalid}`, a hard stop, never a nil field or an
    exception: an error or unknown observation tag, a malformed receipt, a
    sent call without an observation or an unlaunched one with one, a link
    the receipt does not name, a named link that was not read, a link of
    another invocation, a run that is not the invocation's, an own link
    without a lowercase hex inventory digest, a candidate that is not
    exactly the six-key entry, a row or observation time that is not UTC,
    or an output that is not a JSON object canonical encoding accepts.
    """

    require Ash.Query

    alias SdrAgent.Actor
    alias SdrAgent.Agents
    alias SdrAgent.Agents.Admission.Gate
    alias SdrAgent.Agents.Admission.Refused
    alias SdrAgent.Agents.Checks.CalibrationAdmission
    alias SdrAgent.Agents.Checks.CalibrationContext
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ResultGate
    alias SdrAgent.Agents.Witness
    alias SdrAgent.Agents.Witness.Store
    alias SdrAgent.Agents.WireWitnessLink
    alias SdrAgent.AI.ModelProfiles
    alias SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.ClaudeCLI
    alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.Audit.Kernel, as: AuditKernel
    alias SdrAgent.Audit.Tenant
    alias SdrAgent.CalibrationConsole.Authority
    alias SdrAgent.CalibrationConsole.Evidence
    alias SdrAgent.CalibrationConsole.Isolation
    alias SdrAgent.CalibrationConsole.LaunchRecord
    alias SdrAgent.CalibrationConsole.Outcome
    alias SdrAgent.CalibrationConsole.ProcessProbe
    alias SdrAgent.CalibrationConsole.Prompt
    alias SdrAgent.Clock
    alias SdrAgent.SDR

    @schema "r0-calibration-evidence/1"
    @sha256 ~r/\A[0-9a-f]{64}\z/
    @invalid {:error, :evidence_input_invalid}
    @tuple_names [:provider, :profile_id, :method]
    # The states ResultGate/Witness receipts and their links carry.
    @receipt_statuses [:skipped, :unwitnessed, :inferred, :reconciled, :mismatch]
    @link_statuses [:inferred, :reconciled, :mismatch]
    @methods [:time_window, :propagated_id]
    @tuple_strings [:cli_version, :model_id, :projection_version]

    @projection "claude-message-json/3+prompt-builder/1"
    @required [:tenant, :root, :evidence_dir, :confirm, :probe, :server, :isolation, :record]
    @definition %{
      name: "CalibrationConsole",
      version: 1,
      module: "SdrAgent.CalibrationConsole.Calibrate",
      definition: %{
        "allowed_actions" => [],
        "model_policy" => %{"provider" => "claude_cli", "max_model_calls_per_run" => 1}
      }
    }
    @receipts [:calibration_launched, :calibration_launch_unverified]
    @quiescence_ms 3_000
    @poll_ms 50

    ## The command

    @doc "The subcommand's argv: `{:run, profile_id, console_opts(profile_id)}` or `{:error, :usage}`."
    def command([name]) when is_binary(name) do
      case Enum.find(ModelProfiles.real_ids(), &(Atom.to_string(&1) == name)) do
        nil -> {:error, :usage}
        profile_id -> {:run, profile_id, console_opts(profile_id)}
      end
    end

    def command(_argv), do: {:error, :usage}

    @doc "The console's fixed options for `profile_id` (no hook and no overrides)."
    def console_opts(_profile_id) do
      state = Path.join(System.user_home!(), ".local/state/sdr-agent/calibration")

      [
        tenant: :console,
        root: state,
        evidence_dir: Path.join(state, "evidence"),
        confirm: &read_confirmation/1,
        probe: ProcessProbe,
        server: [],
        isolation: [],
        record: []
      ]
    end

    @doc """
    The console's first-run setup (packet 8.14.9 round 4): `opts` is exactly
    `root` and `evidence_dir` (absolute and canonical, the latter
    `root/evidence`). The
    root must already be safe; the evidence directory is created only by an
    exclusive `mkdir`, its creator alone setting 0700, and an existing name
    is only inspected. Returns `{:ok, :created | :existing}` or
    `{:error, :calibration_options_invalid | :calibration_root_unsafe |
    :evidence_dir_unsafe | :calibration_setup_failed}`.
    """
    def prepare(opts) do
      with {:ok, root, evidence_dir} <- prepare_input(opts),
           :ok <- prepared_root(root) do
        create_evidence_dir(evidence_dir)
      end
    end

    defp prepare_input(opts) do
      with true <- Keyword.keyword?(opts),
           [:evidence_dir, :root] <- opts |> Keyword.keys() |> Enum.sort(),
           root = Keyword.fetch!(opts, :root),
           evidence_dir = Keyword.fetch!(opts, :evidence_dir),
           true <- absolute?(root) and absolute?(evidence_dir),
           true <- evidence_dir == Path.join(root, "evidence") do
        {:ok, root, evidence_dir}
      else
        _invalid -> {:error, :calibration_options_invalid}
      end
    end

    # The root's rule is the evidence directory's own (0700, this user's,
    # no symlink in it or any ancestor), as the launch record requires.
    defp prepared_root(root) do
      if Evidence.check_dir(root) == :ok, do: :ok, else: {:error, :calibration_root_unsafe}
    end

    defp create_evidence_dir(dir) do
      case File.mkdir(dir) do
        :ok -> secure_created(dir)
        {:error, :eexist} -> existing(dir)
        {:error, _io} -> {:error, :calibration_setup_failed}
      end
    end

    # Only the creator sets the mode. A failed chmod removes only its own,
    # still empty directory; a leftover is revalidated by later calls.
    defp secure_created(dir) do
      case File.chmod(dir, 0o700) do
        :ok ->
          if Evidence.check_dir(dir) == :ok,
            do: {:ok, :created},
            else: {:error, :evidence_dir_unsafe}

        {:error, _io} ->
          _ = File.rmdir(dir)
          {:error, :calibration_setup_failed}
      end
    end

    defp existing(dir) do
      if Evidence.check_dir(dir) == :ok,
        do: {:ok, :existing},
        else: {:error, :evidence_dir_unsafe}
    end

    defp read_confirmation(prompt) do
      case IO.gets(prompt) do
        line when is_binary(line) -> line
        _eof_or_error -> ""
      end
    end

    @doc "Performs one calibration call of `profile_id` (see the moduledoc)."
    def run(profile_id, opts) do
      with {:ok, options} <- options(profile_id, opts),
           {:ok, tenant_id} <- tenant(options.tenant),
           s = initial(profile_id, options, tenant_id),
           {:ok, definition} <- definition(s),
           {:ok, record} <- claim(s) do
        s = %{s | definition: definition, record: record}

        try do
          preflight(s)
        after
          teardown()
        end
      end
    end

    ## Options, tenant and definition (before the claim)

    defp options(profile_id, opts) do
      with true <- ModelProfiles.real?(profile_id),
           true <- Keyword.keyword?(opts),
           keys = Keyword.keys(opts),
           true <- keys == Enum.uniq(keys),
           true <- Enum.all?(keys, &(&1 in [:hook | @required])),
           true <- Enum.all?(@required, &Keyword.has_key?(opts, &1)),
           options = Map.new(opts),
           true <- valid_options?(options) do
        {:ok, Map.put_new(options, :hook, nil)}
      else
        _invalid -> pre_claim_stop(:calibration_options_invalid)
      end
    end

    defp valid_options?(o) do
      Enum.all?([
        o.tenant == :console or uuid?(o.tenant),
        absolute?(o.root) and absolute?(o.evidence_dir),
        is_function(o.confirm, 1),
        module?(o.probe),
        Enum.all?([o.server, o.isolation, o.record], &Keyword.keyword?/1),
        not Map.has_key?(o, :hook) or is_function(o.hook, 2)
      ])
    end

    defp module?(value), do: is_atom(value) and value not in [nil, true, false]

    defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
    # Absolute and canonical (its own expansion: no `.` or `..`, no
    # trailing slash), so every check judges exactly the path written.
    defp absolute?(path),
      do: is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path

    defp tenant(selector) do
      query =
        case selector do
          :console -> Ash.Query.filter(Tenant, singleton == true)
          id -> Ash.Query.filter(Tenant, id == ^id)
        end

      case query
           |> Ash.Query.for_read(:read, %{}, actor: Actor.system(:kernel, nil))
           |> Ash.read_one() do
        {:ok, %Tenant{id: id}} -> {:ok, id}
        _missing_or_unreadable -> pre_claim_stop(:calibration_tenant_unavailable)
      end
    end

    defp initial(profile_id, options, tenant_id) do
      %{
        profile: profile_id,
        options: options,
        tenant_id: tenant_id,
        agent: Actor.system(:agent_runtime, tenant_id),
        record_opts: [probe: options.probe] ++ options.record,
        definition: nil,
        record: nil,
        run: nil,
        invocation: nil,
        server: nil,
        binding: nil,
        outcome: nil,
        evidence: nil
      }
    end

    # The fixed definition, registered by the tenant's kernel actor and
    # verified as returned (the replay compares the body hash only).
    defp definition(s) do
      case Agents.register_definition(@definition, actor: Actor.system(:kernel, s.tenant_id)) do
        {:ok, definition} ->
          if eligible?(definition, s.tenant_id),
            do: {:ok, definition},
            else: pre_claim_stop(:calibration_definition_conflict)

        {:error, %Ash.Error.Invalid{}} ->
          pre_claim_stop(:calibration_definition_conflict)

        {:error, _unavailable} ->
          pre_claim_stop(:calibration_definition_unavailable)
      end
    end

    defp eligible?(definition, tenant_id) do
      definition.tenant_id == tenant_id and definition.name == @definition.name and
        definition.version == @definition.version and definition.module == @definition.module and
        definition.definition == @definition.definition and
        definition.definition_sha256 == Canonical.sha256(@definition.definition) and
        definition.status == :active
    end

    defp claim(s) do
      case LaunchRecord.claim(s.options.root, s.record_opts) do
        {:ok, record} -> {:ok, record}
        {:error, reason} -> pre_claim_stop(reason)
      end
    end

    defp pre_claim_stop(reason), do: {:stop, reason, summary(:none)}

    ## Preflight (rows 2 and 3)

    defp preflight(s) do
      with :ok <- Evidence.check_dir(s.options.evidence_dir),
           :ok <- pinned(s),
           :ok <- store(),
           {:ok, binding} <- grant(s),
           :ok <- confirmed(s),
           :ok <- isolation(s),
           {:ok, server} <- server(s) do
        create_run(%{s | binding: binding, server: server})
      else
        {:error, :calibration_isolation_cleanup_unconfirmed} ->
          kept(:calibration_isolation_cleanup_unconfirmed, s)

        {:error, reason} ->
          abort(s, reason)
      end
    end

    defp pinned(s) do
      case PinnedExecutable.verify(executable(s)) do
        :ok -> :ok
        {:error, _reason} -> {:error, :pinned_cli_unavailable}
      end
    end

    defp executable(s) do
      Keyword.get_lazy(s.options.server, :executable, fn ->
        case PinnedExecutable.identity() do
          %{executable: path} -> path
          nil -> nil
        end
      end)
    end

    defp store do
      case Witness.store_root() do
        root when is_binary(root) ->
          if match?({:ok, _root}, Store.validate_root(root)),
            do: :ok,
            else: {:error, :witness_store_untrusted}

        _unset ->
          {:error, :witness_store_untrusted}
      end
    end

    defp grant(s) do
      case Agents.select_calibration_grant(s.tenant_id, s.profile, actor: s.agent) do
        {:ok, binding} -> {:ok, binding}
        {:error, _reason} -> {:error, :calibration_grant_unavailable}
      end
    end

    defp confirmed(s) do
      typed = "CALIBRATE #{s.profile}"

      prompt =
        "One real #{s.profile} calibration call is charged to G-R0. Type #{typed} to proceed: "

      if String.trim(s.options.confirm.(prompt)) == typed,
        do: :ok,
        else: {:error, :calibration_not_confirmed}
    end

    defp isolation(s),
      do: Isolation.preflight(Keyword.put(s.options.isolation, :probe, s.options.probe))

    defp server(s) do
      opts =
        s.options.server
        |> Keyword.put(:profile, s.profile)
        |> Keyword.put(:executable, executable(s))

      case ClaudeCLI.start_link(opts) do
        {:ok, server} ->
          Process.put({__MODULE__, :server}, server)
          {:ok, server}

        _failed ->
          {:error, :calibration_server_unavailable}
      end
    end

    ## The proof run and the reservation (rows 4 and 5)

    defp create_run(s) do
      attrs = %{
        agent_definition_id: s.definition.id,
        usage_origin: :proof,
        trigger_signal_type: "calibration.console",
        trigger_signal_id: s.record.instance_id,
        correlation_id: Ash.UUIDv7.generate(),
        phase: :research,
        max_model_calls: 1,
        max_tool_calls: 0
      }

      with {:ok, created} <- ok_or(Agents.create_run(attrs, actor: s.agent), :created),
           {:ok, run} <- ok_or(Agents.start_run(created, actor: s.agent), {:started, created}) do
        reserve(%{s | run: run})
      else
        {:error, :created} ->
          abort(s, :calibration_run_unavailable)

        {:error, {:started, created}} ->
          stop_run_then_abort(%{s | run: created}, :calibration_run_unavailable)
      end
    end

    defp reserve(s) do
      marker =
        CalibrationAdmission.context(s.profile, candidate(s.profile),
          claim: s.record.instance_id,
          binding: s.binding
        )

      case Agents.reserve_model_invocation(s.run, reservation(s),
             actor: s.agent,
             calibration: marker
           ) do
        {:ok, invocation} ->
          pending(%{s | invocation: invocation})

        {:error, %Refused{} = refused} ->
          case stop_refused(s, refused) do
            :ok -> abort(s, :calibration_reservation_refused)
            :error -> kept(:calibration_run_stop_failed, s)
          end

        {:error, _other} ->
          stop_run_then_abort(s, :calibration_reservation_failed)
      end
    end

    defp reservation(s) do
      prompt = Prompt.prompt_ref()
      schema = Prompt.schema_ref()

      %{
        purpose: :qualification,
        parameters: %{},
        prompt_template_id: prompt.id,
        prompt_template_version: prompt.version,
        prompt_template_sha256: prompt.sha256,
        output_schema_id: schema.id,
        output_schema_version: schema.version,
        output_schema_sha256: schema.sha256,
        request: ModelProvider.request_body(base_request(s)),
        idempotency_key: request_id(s)
      }
      |> Map.merge(ClaudeCLI.provenance(ModelProfiles.fetch_real(s.profile) |> elem(1)))
    end

    defp request_id(s), do: "calibration-#{s.record.instance_id}"

    defp base_request(s),
      do: %{
        id: request_id(s),
        operation: "calibration.complete",
        prompt: Prompt.render(),
        schema: Prompt.schema()
      }

    defp candidate(profile_id) do
      {:ok, profile} = ModelProfiles.fetch_real(profile_id)

      %{
        provider: :claude_cli,
        cli_version: profile.cli_version,
        profile_id: profile.id,
        model_id: profile.resolved_model,
        projection_version: @projection,
        method: :propagated_id
      }
    end

    # The existing guarded run stop with the receipt, on the fresh run.
    defp stop_refused(s, refused) do
      ctx = %SDR.Context{
        actor: s.agent,
        tenant_id: s.tenant_id,
        run_id: s.run.id,
        correlation_id: s.run.correlation_id
      }

      with {:ok, run} <- Agents.get_run(s.run.id, actor: s.agent),
           {:ok, _stopped} <- SDR.Model.stop_refused(ctx, run, refused) do
        :ok
      else
        _failed -> :error
      end
    end

    defp stop_run_then_abort(s, reason) do
      with {:ok, run} <- Agents.get_run(s.run.id, actor: s.agent),
           {:ok, _cancelled} <- Agents.cancel_run(run, actor: s.agent) do
        abort(s, reason)
      else
        _failed -> kept(:calibration_run_stop_failed, s)
      end
    end

    ## The launch (rows 6 to 10)

    defp pending(s) do
      case LaunchRecord.advance(
             s.options.root,
             s.record,
             :launch_pending,
             %{invocation_id: s.invocation.id},
             s.record_opts
           ) do
        {:ok, record} -> hooked(%{s | record: record}, :before_issue, &issue/1)
        {:error, reason} -> kept(reason, s)
      end
    end

    defp issue(s) do
      binding = %{
        invocation_id: s.invocation.id,
        run_id: s.run.id,
        tenant_id: s.tenant_id,
        profile_id: s.profile,
        command_pid: self(),
        server_pid: s.server,
        prompt_sha256: hex(Prompt.prompt_ref().sha256),
        schema_sha256: hex(Prompt.schema_ref().sha256)
      }

      case authority_issue(binding) do
        {:ok, ref, instance} ->
          Process.put({__MODULE__, :authority}, ref)
          hooked(s, :before_call, &call(&1, ref, instance))

        :unavailable ->
          unlaunched(s, :calibration_authority_unavailable)
      end
    end

    # Only the registry operations themselves are guarded here: an exit
    # anywhere later is never reported as the authority being unavailable.
    defp authority_issue(binding) do
      instance = Authority.instance()

      case Authority.issue(Map.put(binding, :instance, instance)) do
        {:ok, ref} -> {:ok, ref, instance}
        _refused -> :unavailable
      end
    catch
      :exit, _unavailable -> :unavailable
    end

    defp hooked(s, phase, next) do
      case s.options.hook do
        nil ->
          next.(s)

        hook ->
          try do
            hook.(phase, %{
              invocation_id: s.invocation.id,
              run_id: s.run.id,
              tenant_id: s.tenant_id
            })

            :ok
          catch
            _kind, _reason -> :failed
          end
          |> case do
            :ok -> next.(s)
            :failed -> kept(:calibration_hook_failed, s)
          end
      end
    end

    defp call(s, ref, instance) do
      observer = make_ref()

      request =
        s
        |> base_request()
        |> Map.merge(%{
          actor: s.agent,
          run: s.run,
          calibration: %{
            authority: ref,
            run_id: s.run.id,
            tenant_id: s.tenant_id,
            instance: instance,
            observer: {self(), observer}
          }
        })

      result = ModelProvider.calibration_call(request, s.invocation.id, server: s.server)
      revoke()
      receipt = own_receipt(flush_receipts(), observer, s)

      case Agents.get_model_invocation(s.invocation.id, actor: s.agent) do
        {:ok, %ModelInvocation{sent_at: nil} = invocation} ->
          unlaunched_after_call(%{s | invocation: invocation}, receipt, result)

        {:ok, invocation} ->
          launched(%{s | invocation: invocation}, receipt)

        _unreadable ->
          kept(:calibration_invocation_unreadable, s)
      end
    end

    # Only this call's verified receipt of this invocation counts; any other
    # receipt message (stale or foreign) is dropped.
    defp own_receipt(receipts, observer, s) do
      Enum.find_value(receipts, fn
        {:calibration_launched, ^observer, %{invocation_id: id, server: server} = receipt}
        when id == s.invocation.id and server == s.server ->
          receipt

        _other ->
          nil
      end)
    end

    defp flush_receipts do
      receive do
        {kind, ref, receipt} when kind in @receipts -> [{kind, ref, receipt} | flush_receipts()]
      after
        0 -> []
      end
    end

    defp unlaunched_after_call(s, receipt, result) do
      cond do
        receipt != nil or s.record.state == "launched" ->
          kept(:calibration_launch_conflict, s)

        match?({:error, %Refused{}}, result) ->
          {:error, refused} = result

          case stop_refused(s, refused) do
            :ok -> unlaunched(s, :calibration_launch_refused)
            :error -> kept(:calibration_run_stop_failed, s)
          end

        true ->
          unlaunched(s, failure_reason(result))
      end
    end

    defp failure_reason({:error, reason}) when is_atom(reason), do: reason
    defp failure_reason(_result), do: :calibration_launch_failed

    defp launched(s, nil), do: kept(:calibration_launch_unverified, s)

    defp launched(s, receipt) do
      attrs = Map.take(receipt, [:root_pid, :root_identity, :process_group_id])

      case LaunchRecord.advance(s.options.root, s.record, :launched, attrs, s.record_opts) do
        {:ok, record} -> observe(%{s | record: record})
        {:error, reason} -> kept(reason, s)
      end
    end

    ## Unlaunched: recovery, evidence and latch (rows 7 and 8)

    defp unlaunched(s, reason) do
      with {:ok, invocation} <- recovered(s),
           s = %{s | invocation: invocation},
           {:ok, run} <-
             ok_or(Agents.get_run(s.run.id, actor: s.agent), :calibration_run_unreadable),
           {:ok, tuple} <- tuple(invocation),
           {:ok, document} <-
             document(%{
               invocation: invocation,
               run: run,
               tuple: tuple,
               gate: nil,
               link: nil,
               attestation: nil,
               output: nil,
               observed_at: Clock.utc_now()
             }) do
        s |> Map.put(:outcome, document.outcome) |> finalize(document, :aborted, reason)
      else
        {:error, failure} -> kept(failure, s)
      end
    end

    defp recovered(%{invocation: %ModelInvocation{status: :reserved} = invocation} = s) do
      case Agents.recover_calibration(invocation, :unlaunched, actor: s.agent) do
        {:ok, %{invocation: recovered}} -> {:ok, recovered}
        _failed -> {:error, :calibration_recovery_failed}
      end
    end

    defp recovered(s), do: {:ok, s.invocation}

    ## The normal path (rows 11 to 13)

    defp observe(s) do
      with :open <- admission(s),
           :quiescent <- quiescence(s, System.monotonic_time(:millisecond) + @quiescence_ms) do
        gate = %{run_id: s.run.id, operation_id: nil}

        case ResultGate.await(s.invocation, gate, methods: [candidate(s.profile)]) do
          {kind, receipt} = observation when kind in [:ok, :timeout] ->
            observed(s, observation, receipt)

          {:error, _reason} ->
            kept(:calibration_observation_failed, s)
        end
      else
        {:error, reason} -> kept(reason, s)
        _not_quiescent_or_blocked -> kept(:calibration_not_quiescent, s)
      end
    end

    defp admission(s) do
      if ClaudeCLI.admission(s.server) == %{admission: :open}, do: :open, else: :blocked
    end

    # Known live work (`:not_quiescent`) is re-observed within a short
    # bound; any other answer, a probe error above all, is returned at once
    # and never retried into absence.
    defp quiescence(s, until) do
      case LaunchRecord.quiescence(s.record, probe: s.options.probe) do
        :not_quiescent ->
          if System.monotonic_time(:millisecond) < until do
            Process.sleep(@poll_ms)
            quiescence(s, until)
          else
            :not_quiescent
          end

        other ->
          other
      end
    end

    defp observed(s, observation, receipt) do
      observed_at = Clock.utc_now()

      with {:ok, invocation} <- calibration_read(s),
           {:ok, run} <-
             ok_or(Agents.get_run(s.run.id, actor: s.agent), :calibration_run_unreadable),
           {:ok, tuple} <- tuple(invocation),
           {:ok, link} <- own_link_read(receipt, invocation),
           {:ok, document} <-
             document(%{
               invocation: invocation,
               run: run,
               tuple: tuple,
               gate: observation,
               link: link,
               attestation: ClaudeCLI.attestation(s.server),
               output: invocation.parsed_output,
               observed_at: observed_at
             }) do
        s
        |> Map.merge(%{invocation: invocation, outcome: document.outcome})
        |> finalize(document, :finished, nil)
      else
        {:error, failure} -> kept(failure, s)
      end
    end

    # The bound invocation, parsed output included, through the audited
    # calibration read.
    defp calibration_read(s) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{},
        actor: s.agent,
        context: CalibrationContext.context(s.profile, s.invocation.id)
      )
      |> Ash.Query.filter(id == ^s.invocation.id and tenant_id == ^s.tenant_id)
      |> Ash.read_one()
      |> case do
        {:ok, %ModelInvocation{} = invocation} -> {:ok, invocation}
        _failed -> {:error, :calibration_invocation_unreadable}
      end
    end

    defp own_link_read(%{link_id: nil}, _invocation), do: {:ok, nil}

    defp own_link_read(%{link_id: id}, invocation) when is_binary(id) do
      WireWitnessLink
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(id == ^id and model_invocation_id == ^invocation.id)
      |> Ash.read_one()
      |> case do
        {:ok, %WireWitnessLink{} = link} -> {:ok, link}
        _failed -> {:error, :calibration_link_unreadable}
      end
    end

    defp own_link_read(_receipt, _invocation), do: {:error, :evidence_input_invalid}

    defp tuple(invocation) do
      case Gate.recorded_tuple(invocation) do
        {:ok, %{} = tuple} -> {:ok, tuple}
        _missing -> {:error, :calibration_tuple_unrecorded}
      end
    end

    # Evidence (E2), the latch (E1), the final record state and the
    # release. Each step carries the state it reached, so a later failure
    # still reports the published file.
    defp finalize(s, document, final, reason) do
      case Evidence.publish(s.options.evidence_dir, document, actor: s.agent) do
        {:ok, evidence} ->
          latch(%{s | evidence: Map.take(evidence, [:path, :sha256])}, final, reason)

        {:error, failure} ->
          kept(failure, s)
      end
    end

    defp latch(s, final, reason) do
      case Agents.finish_calibration(s.invocation, %{sha256: s.evidence.sha256}, actor: s.agent) do
        {:ok, _latched} -> final_record(s, final, reason)
        _failed -> kept(:calibration_finish_failed, s)
      end
    end

    defp final_record(s, final, reason) do
      case LaunchRecord.advance(s.options.root, s.record, final, %{}, s.record_opts) do
        {:ok, record} -> release(%{s | record: record}, reason)
        {:error, failure} -> kept(failure, s)
      end
    end

    defp release(s, reason) do
      case LaunchRecord.release(s.options.root, s.record, s.record_opts) do
        :ok ->
          result = summary(:released, s)
          if reason, do: {:stop, reason, result}, else: {:ok, result}

        {:error, failure} ->
          kept(failure, s)
      end
    end

    ## Recovery (d3d, packet 8.14.11)

    @doc "The `calibrate-recover` argv: `{:recover, id | nil, recover_opts(stopped)}` or `{:error, :usage}`."
    def recover_command(["--release-aborted"]), do: {:recover, nil, recover_opts(false)}

    def recover_command([id]) do
      if uuid?(id), do: {:recover, id, recover_opts(false)}, else: {:error, :usage}
    end

    def recover_command([id, "--owner-verified-stopped"]) do
      if uuid?(id), do: {:recover, id, recover_opts(true)}, else: {:error, :usage}
    end

    def recover_command(_argv), do: {:error, :usage}

    @doc "The console's fixed recovery options; `stopped` is the owner's `--owner-verified-stopped`."
    def recover_opts(stopped) when is_boolean(stopped) do
      state = Path.join(System.user_home!(), ".local/state/sdr-agent/calibration")

      [
        tenant: :console,
        root: state,
        evidence_dir: Path.join(state, "evidence"),
        confirm: &read_confirmation/1,
        probe: ProcessProbe,
        record: [],
        stopped: stopped
      ]
    end

    @doc "Recovers the console's stale launch record for `invocation_id` (see the moduledoc)."
    def recover(invocation_id, opts) do
      with {:ok, options} <- recover_options(invocation_id, opts),
           {:ok, tenant_id} <- untracked(tenant(options.tenant)),
           r = recover_initial(invocation_id, options, tenant_id),
           {:ok, handle} <- lock(r) do
        r = %{r | handle: handle, record: handle.record}

        case target(r) do
          {:ok, r} -> decide(r)
          {:error, reason} -> pre_effect(reason, r)
        end
      end
    end

    @recover_required [:tenant, :root, :evidence_dir, :confirm, :probe, :record, :stopped]

    defp recover_options(invocation_id, opts) do
      with true <- is_nil(invocation_id) or uuid?(invocation_id),
           true <- Keyword.keyword?(opts),
           keys = Keyword.keys(opts),
           true <- Enum.sort(keys) == Enum.sort(@recover_required),
           options = Map.new(opts),
           true <- valid_recover_options?(options) do
        {:ok, options}
      else
        _invalid -> {:stop, :calibration_options_invalid, recover_summary(:none, :none)}
      end
    end

    defp valid_recover_options?(o) do
      Enum.all?([
        o.tenant == :console or uuid?(o.tenant),
        absolute?(o.root) and absolute?(o.evidence_dir),
        is_function(o.confirm, 1),
        module?(o.probe),
        Keyword.keyword?(o.record),
        is_boolean(o.stopped)
      ])
    end

    defp untracked({:stop, reason, summary}),
      do: {:stop, reason, Map.put(summary, :ticket, :none)}

    defp untracked(ok), do: ok

    defp recover_initial(invocation_id, options, tenant_id) do
      %{
        id: invocation_id,
        options: options,
        tenant_id: tenant_id,
        agent: Actor.system(:agent_runtime, tenant_id),
        record_opts: [probe: options.probe] ++ options.record,
        handle: nil,
        record: nil,
        profile: nil,
        run: nil,
        invocation: nil,
        attestation: nil,
        outcome: nil,
        evidence: nil
      }
    end

    # A refusal creates nothing: no ticket, the record as it was.
    defp lock(r) do
      case LaunchRecord.recover(r.options.root, r.record_opts) do
        {:ok, handle} ->
          {:ok, handle}

        {:error, reason} ->
          record =
            case LaunchRecord.read(r.options.root, r.record_opts) do
              {:ok, %{state: state}} -> {:kept, state}
              _none_or_unsafe -> :none
            end

          {:stop, reason, recover_summary(record, :none)}
      end
    end

    ## The target (before any effect)

    defp target(%{id: nil, record: %{state: "aborted", invocation_id: nil}} = r) do
      case candidates(r) do
        {:ok, []} -> {:ok, r}
        _bound_or_unreadable -> {:error, :calibration_target_ambiguous}
      end
    end

    defp target(%{id: nil}), do: {:error, :calibration_target_ambiguous}

    defp target(r) do
      with {:ok, candidates} <- candidates(r),
           {:ok, invocation} <- one(candidates, r),
           {:ok, run} <- eligible(invocation, r) do
        {:ok, %{r | invocation: invocation, run: run, profile: invocation.profile_id}}
      end
    end

    # Every invocation of the tenant whose one original reservation event
    # records this record's claim, whatever its current eligibility (which
    # the target check judges). A row whose binding cannot be read (missing,
    # duplicated or malformed provenance) can never show that nothing was
    # bound: the requested row is invalid, any other makes the set unknown.
    defp candidates(r) do
      case ModelInvocation
           |> Ash.Query.for_read(:read, %{}, actor: r.agent)
           |> Ash.Query.filter(tenant_id == ^r.tenant_id)
           |> Ash.read() do
        {:ok, invocations} -> claimed(invocations, r)
        {:error, _unreadable} -> {:error, :calibration_target_invalid}
      end
    end

    defp claimed(invocations, r) do
      instance_id = r.record.instance_id

      Enum.reduce_while(invocations, {:ok, []}, fn invocation, {:ok, acc} ->
        case Gate.recorded_claim(invocation) do
          {:ok, %{instance_id: ^instance_id}} ->
            {:cont, {:ok, [invocation | acc]}}

          {:error, _unreadable} when invocation.id == r.id ->
            {:halt, {:error, :calibration_target_invalid}}

          {:error, _unreadable} ->
            {:halt, {:error, :calibration_target_ambiguous}}

          _other_claim ->
            {:cont, {:ok, acc}}
        end
      end)
    end

    defp one([], %{record: %{state: "claimed"}}), do: {:error, :calibration_owner_conflict}

    defp one([%ModelInvocation{id: id} = invocation], %{id: id, record: record})
         when record.invocation_id in [nil, id],
         do: {:ok, invocation}

    defp one(_candidates, _r), do: {:error, :calibration_target_ambiguous}

    # Its own run is `:proof` with no Operation; it is a generation-2
    # ClaudeCLI row of a real profile bound to its recorded tuple.
    defp eligible(invocation, r) do
      with {:ok, run} <- Agents.get_run(invocation.agent_run_id, actor: r.agent),
           true <- run.usage_origin == :proof and is_nil(run.operation_id),
           true <- invocation.ledger_generation == 2 and invocation.provider == :claude_cli,
           true <- ModelProfiles.real?(invocation.profile_id),
           {:ok, %{} = tuple} <- Gate.recorded_tuple(invocation),
           true <- bound?(tuple, invocation) do
        {:ok, run}
      else
        _ineligible -> {:error, :calibration_target_invalid}
      end
    end

    defp bound?(tuple, invocation),
      do:
        tuple.provider == :claude_cli and tuple.profile_id == invocation.profile_id and
          tuple.model_id == invocation.model_id and
          tuple.cli_version == invocation.provider_version

    ## The state matrix

    defp decide(%{invocation: nil} = r), do: release_aborted(r)

    # The unlaunched path takes only a reserved row, or a failed one that
    # was never sent; any other unsent status is inconsistent.
    defp decide(%{record: %{state: state}, invocation: invocation} = r) do
      sent? = not is_nil(invocation.sent_at)
      unlaunched? = not sent? and invocation.status in [:reserved, :failed]

      case {state, sent?} do
        {pre, false} when pre in ["claimed", "launch_pending"] and unlaunched? ->
          unlaunched_recovery(r)

        {"launch_pending", true} ->
          attested(r)

        {"launched", true} ->
          attested(r)

        {final, _sent?} when final in ["aborted", "finished"] ->
          replay(r)

        _inconsistent ->
          pre_effect(:calibration_record_inconsistent, r)
      end
    end

    defp recover_confirmed(r, typed) do
      prompt = "Recovery of the calibration launch record. Type #{typed} to proceed: "
      String.trim(r.options.confirm.(prompt)) == typed
    end

    # The nil-target exception: an aborted record that never reserved.
    defp release_aborted(r) do
      if recover_confirmed(r, "RECOVER ABORTED"),
        do: recovery_release(r),
        else: pre_effect(:calibration_not_confirmed, r)
    end

    ## The unlaunched path

    defp unlaunched_recovery(r) do
      if recover_confirmed(r, "RECOVER #{r.id}") do
        case recovered(r) do
          {:ok, invocation} -> evidence(%{r | invocation: invocation}, :unlaunched)
          {:error, failure} -> post_effect(failure, r)
        end
      else
        pre_effect(:calibration_not_confirmed, r)
      end
    end

    ## The attested path

    defp attested(%{options: %{stopped: false}} = r),
      do: pre_effect(:owner_verification_required, r)

    defp attested(r) do
      with true <- recover_confirmed(r, "RECOVER #{r.id}") || :not_confirmed,
           :ok <- stopped(r),
           true <- recover_confirmed(r, "STOPPED #{r.id}") || :not_confirmed,
           {:ok, attestation} <- LaunchRecord.new_attestation(r.handle) do
        attest(r, attestation)
      else
        :not_confirmed -> pre_effect(:calibration_not_confirmed, r)
        {:error, reason} -> pre_effect(reason, r)
      end
    end

    # Live work is observed before the STOPPED prompt; a launch_pending
    # record has nothing observable and only the owner's STOPPED proves the
    # stop (no automatic quiescence while OQ-E3 is open).
    defp stopped(%{record: %{state: "launch_pending"}}), do: :ok

    defp stopped(r) do
      case LaunchRecord.quiescence(r.record, r.record_opts) do
        :quiescent -> :ok
        :not_quiescent -> {:error, :calibration_not_quiescent}
        {:error, :probe_unavailable} -> {:error, :probe_unavailable}
        _other -> {:error, :owner_verification_required}
      end
    end

    # The event first, then the ticket's file; from here every stop keeps
    # the ticket.
    defp attest(r, attestation) do
      with {:ok, %{invocation: invocation}} <-
             ok_or(
               Agents.recover_calibration(r.invocation, {:attested, attestation}, actor: r.agent),
               :calibration_recovery_failed
             ),
           {:ok, _written} <-
             LaunchRecord.write_attestation(r.options.root, r.handle, attestation, r.record_opts) do
        evidence(%{r | invocation: invocation, attestation: attestation}, :sent)
      else
        {:error, failure} -> post_effect(failure, r)
      end
    end

    ## Final replay

    defp replay(r) do
      with :ok <- attests(r.record.state, r.invocation),
           {:ok, %{} = latch} <- latch_of(r),
           {:ok, evidence} <- latched_file(r, latch) do
        r = frozen(r, evidence)

        if recover_confirmed(r, "RECOVER #{r.id}"),
          do: recovery_release(r),
          else: pre_effect(:calibration_not_confirmed, r)
      else
        {:ok, nil} -> pre_effect(:calibration_record_inconsistent, r)
        {:error, reason} -> pre_effect(reason, r)
      end
    end

    # A known artifact is reported as run/2 does: its own outcome, and only
    # its path and hash.
    defp frozen(r, evidence),
      do: %{r | evidence: Map.take(evidence, [:path, :sha256]), outcome: evidence.outcome}

    defp attests("aborted", %{status: :failed, sent_at: nil}), do: :ok

    defp attests("finished", %{status: status, sent_at: sent_at})
         when status in [:completed, :failed, :unknown] and not is_nil(sent_at),
         do: :ok

    defp attests(_state, _invocation), do: {:error, :calibration_record_inconsistent}

    ## Evidence, the latch, the final record and the release

    defp evidence(r, kind) do
      with {:ok, invocation} <- calibration_read(r),
           r = %{r | invocation: invocation},
           {:ok, latch} <- latch_of(r),
           {:ok, evidence} <- recovery_evidence(r, kind, latch) do
        r = frozen(r, evidence)
        if latch, do: recovery_final(r, kind), else: recovery_latch(r, kind)
      else
        {:error, failure} -> post_effect(failure, r)
      end
    end

    # A latch's own file, reused unchanged; otherwise an unlatched existing
    # file (the frozen observation); otherwise a fresh document.
    defp recovery_evidence(r, _kind, latch) when not is_nil(latch), do: latched_file(r, latch)

    defp recovery_evidence(r, kind, nil) do
      path = evidence_path(r)

      if match?({:ok, _}, File.lstat(path)),
        do: existing_file(r, path),
        else: fresh_evidence(r, kind)
    end

    defp latched_file(r, latch) do
      with {:ok, evidence} <- existing_file(r, evidence_path(r)),
           true <- evidence.sha256 == latch.evidence_sha256 do
        {:ok, evidence}
      else
        _changed_or_missing -> {:error, :calibration_evidence_conflict}
      end
    end

    defp existing_file(r, path) do
      case Evidence.validate(path, evidence_target(r), actor: r.agent) do
        {:ok, %{bytes: bytes} = evidence} ->
          {:ok, Map.put(evidence, :outcome, Jason.decode!(bytes)["outcome"])}

        {:error, _invalid} ->
          {:error, :calibration_evidence_conflict}
      end
    end

    defp fresh_evidence(r, :unlaunched), do: publish(r, nil, nil)

    # One bounded observation of the sent call, outside any lock, on the
    # freshly re-read row: the receipt's own link, no CLI init attestation.
    defp fresh_evidence(r, :sent) do
      with {:ok, tuple} <- tuple(r.invocation),
           {kind, receipt} = observation when kind in [:ok, :timeout] <-
             ResultGate.await(r.invocation, %{run_id: r.run.id, operation_id: nil},
               methods: [tuple]
             ),
           {:ok, invocation} <- calibration_read(r),
           {:ok, link} <- own_link_read(receipt, invocation) do
        publish(%{r | invocation: invocation}, observation, link)
      else
        {:error, :calibration_tuple_unrecorded} = error -> error
        {:error, :calibration_invocation_unreadable} = error -> error
        {:error, :calibration_link_unreadable} = error -> error
        _failed -> {:error, :calibration_observation_failed}
      end
    end

    defp publish(r, observation, link) do
      with {:ok, run} <-
             ok_or(Agents.get_run(r.run.id, actor: r.agent), :calibration_run_unreadable),
           {:ok, tuple} <- tuple(r.invocation),
           {:ok, document} <-
             document(%{
               invocation: r.invocation,
               run: run,
               tuple: tuple,
               gate: observation,
               link: link,
               attestation: nil,
               output: if(observation, do: r.invocation.parsed_output),
               observed_at: Clock.utc_now()
             }),
           {:ok, evidence} <- Evidence.publish(r.options.evidence_dir, document, actor: r.agent) do
        {:ok, Map.put(evidence, :outcome, document.outcome)}
      end
    end

    defp recovery_latch(r, kind) do
      case Agents.finish_calibration(r.invocation, %{sha256: r.evidence.sha256}, actor: r.agent) do
        {:ok, _latched} -> recovery_final(r, kind)
        _failed -> post_effect(:calibration_finish_failed, r)
      end
    end

    defp recovery_final(r, :unlaunched), do: recovery_advance(r, :aborted, %{})

    defp recovery_final(r, :sent),
      do: recovery_advance(r, :recovered, %{attestation_id: r.attestation.attestation_id})

    defp recovery_advance(r, state, attrs) do
      case LaunchRecord.advance(r.options.root, r.record, state, attrs, recovery_opts(r)) do
        {:ok, record} -> recovery_release(%{r | record: record})
        {:error, failure} -> post_effect(failure, r)
      end
    end

    defp recovery_release(r) do
      case LaunchRecord.release(r.options.root, r.record, recovery_opts(r)) do
        :ok -> {:ok, recover_summary(:released, r, :released)}
        {:error, failure} -> post_effect(failure, r)
      end
    end

    defp recovery_opts(r), do: r.record_opts ++ [recovery: r.handle]

    defp latch_of(r) do
      case Agents.get_result_release(r.invocation.id, actor: r.agent) do
        {:ok, %{disposition: :calibration} = latch} -> {:ok, latch}
        {:ok, _none_or_other} -> {:ok, nil}
        {:error, _unreadable} -> {:error, :calibration_release_unreadable}
      end
    end

    defp evidence_path(r),
      do:
        Path.join(
          r.options.evidence_dir,
          Evidence.file_name(r.invocation.profile_id, r.invocation.id)
        )

    defp evidence_target(r),
      do: %{
        invocation_id: r.invocation.id,
        run_id: r.invocation.agent_run_id,
        tenant_id: r.invocation.tenant_id,
        profile_id: to_string(r.invocation.profile_id)
      }

    ## Recovery stops

    # Before any effect: this call's own bare ticket is ended; a failed end
    # keeps it, with the original reason.
    defp pre_effect(reason, r) do
      ticket =
        case LaunchRecord.end_recovery(r.options.root, r.handle, r.record_opts) do
          :ok -> :ended
          {:error, _kept} -> :kept
        end

      {:stop, reason, recover_summary({:kept, current_state(r)}, r, ticket)}
    end

    # After an effect the ticket is never ended.
    defp post_effect(reason, r),
      do: {:stop, reason, recover_summary({:kept, current_state(r)}, r, :kept)}

    defp recover_summary(record, ticket),
      do: Map.put(summary(record), :ticket, ticket)

    defp recover_summary(record, r, ticket),
      do: Map.put(summary(record, r), :ticket, ticket)

    ## Stops, teardown and summaries

    # `aborted` then release; a failure keeps the record where it is and
    # still reports the original stop.
    defp abort(s, reason) do
      with {:ok, aborted} <-
             LaunchRecord.advance(s.options.root, s.record, :aborted, %{}, s.record_opts),
           :ok <- LaunchRecord.release(s.options.root, aborted, s.record_opts) do
        {:stop, reason, summary(:released, s)}
      else
        _failed -> kept(reason, s)
      end
    end

    defp kept(reason, s), do: {:stop, reason, summary({:kept, current_state(s)}, s)}

    defp current_state(s) do
      case LaunchRecord.read(s.options.root, s.record_opts) do
        {:ok, %{state: state}} -> state
        _missing -> s.record.state
      end
    end

    defp revoke do
      case Process.delete({__MODULE__, :authority}) do
        nil -> :ok
        ref -> Authority.revoke(ref)
      end
    catch
      :exit, _unavailable -> :ok
    end

    defp teardown do
      revoke()

      case Process.delete({__MODULE__, :server}) do
        nil -> :ok
        server -> GenServer.stop(server, :normal, 5_000)
      end

      flush_receipts()
      :ok
    catch
      :exit, _gone -> :ok
    end

    defp summary(record, s \\ %{invocation: nil, outcome: nil, evidence: nil}),
      do: %{
        record: record,
        invocation_id: s.invocation && s.invocation.id,
        outcome: s.outcome,
        evidence: s.evidence
      }

    defp ok_or({:ok, value}, _tag), do: {:ok, value}
    defp ok_or(_failed, tag), do: {:error, tag}

    @doc "The evidence document of the gathered snapshots (see the moduledoc)."
    def document(
          %{
            invocation: invocation,
            run: run,
            tuple: tuple,
            gate: gate,
            link: link,
            attestation: attestation,
            output: output,
            observed_at: observed_at
          } = _snapshot
        ) do
      with true <- invocation?(invocation) and tuple?(tuple) and utc?(observed_at),
           %{id: run_id} when run_id == invocation.agent_run_id <- run,
           {:ok, observation} <- observation(invocation, gate),
           {:ok, link} <- own_link(link, observation, invocation),
           {:ok, inventory} <- inventory(link),
           {:ok, links} <- links(link),
           {:ok, output_sha256} <- output_sha256(output) do
        outcome = classify(observation, invocation, attestation, link, tuple)

        {:ok,
         %{
           schema: @schema,
           canonicalization: Canonical.version(),
           invocation_id: invocation.id,
           run_id: run_id,
           tenant_id: invocation.tenant_id,
           profile_id: to_string(invocation.profile_id),
           candidate: Map.new(tuple, fn {key, value} -> {key, to_string(value)} end),
           evaluated_projection_version: outcome.evaluated_projection_version,
           evaluated_method: outcome.evaluated_method,
           outcome: outcome.outcome,
           links: links,
           inventory_sha256: inventory,
           prompt: ref(Prompt.prompt_ref()),
           output_schema: ref(Prompt.schema_ref()),
           attested_cli_version: outcome.attested_cli_version,
           attested_model_id: outcome.attested_model_id,
           invocation_status: to_string(invocation.status),
           validation_status: to_string(invocation.validation_status),
           output_sha256: output_sha256,
           reserved_at: usec(invocation.reserved_at),
           sent_at: usec(invocation.sent_at),
           completed_at: usec(invocation.completed_at),
           observed_at: usec(observed_at)
         }}
      else
        _inconsistent -> @invalid
      end
    end

    def document(_snapshot), do: @invalid

    ## The snapshots' shapes

    defp invocation?(%{
           id: id,
           agent_run_id: run_id,
           tenant_id: tenant_id,
           profile_id: profile_id,
           status: status,
           validation_status: validation_status,
           reserved_at: reserved_at,
           sent_at: sent_at,
           completed_at: completed_at
         }) do
      Enum.all?([id, run_id, tenant_id], &is_binary/1) and
        Enum.all?([profile_id, status, validation_status], &name?/1) and utc?(reserved_at) and
        Enum.all?([sent_at, completed_at], &(is_nil(&1) or utc?(&1)))
    end

    defp invocation?(_invocation), do: false

    # Exactly the six-key entry: names for the provider, profile and
    # method, strings for the rest.
    defp tuple?(%{} = tuple) when map_size(tuple) == 6 do
      Enum.all?(@tuple_names, &name?(Map.get(tuple, &1))) and
        Enum.all?(@tuple_strings, &is_binary(Map.get(tuple, &1)))
    end

    defp tuple?(_tuple), do: false

    defp name?(value), do: is_atom(value) and value not in [nil, true, false]

    # A well-formed UTC DateTime: zero offsets, an integer microsecond with
    # a precision of at most 6, and fields ISO 8601 formatting accepts.
    defp utc?(
           %DateTime{
             time_zone: "Etc/UTC",
             utc_offset: 0,
             std_offset: 0,
             microsecond: {microsecond, precision}
           } = time
         )
         when is_integer(microsecond) and microsecond in 0..999_999 and precision in 0..6,
         do: formattable?(time)

    defp utc?(_time), do: false

    # Formatting is pure; a value it cannot format is invalid input,
    # contained here and nowhere else.
    defp formattable?(time) do
      match?({:ok, _time, 0}, DateTime.from_iso8601(DateTime.to_iso8601(time)))
    rescue
      _unformattable -> false
    end

    ## The observation

    # A sent call is observed only through the await's own `{:ok |
    # :timeout, receipt}`; an unlaunched one (`sent_at` nil) had no await.
    # Nothing else is an observation, and none is ever invented.
    defp observation(%{sent_at: nil}, nil), do: {:ok, :unlaunched}

    defp observation(%{sent_at: %DateTime{}}, {kind, receipt} = gate)
         when kind in [:ok, :timeout] do
      if receipt?(receipt), do: {:ok, gate}, else: :error
    end

    defp observation(_invocation, _gate), do: :error

    defp receipt?(%{status: status, link_id: link_id, cause_id: cause_id, codes: codes})
         when is_list(codes) do
      status in @receipt_statuses and
        Enum.all?([link_id, cause_id], &(is_nil(&1) or is_binary(&1))) and
        Enum.all?(codes, &is_binary/1)
    end

    defp receipt?(_receipt), do: false

    # The unlaunched outcome is built here, not classified from an invented
    # receipt: no evaluation and no attestation (packet 8.14.8).
    defp classify(:unlaunched, _invocation, _attestation, _link, _tuple),
      do: %{
        outcome: "launch_failed",
        evaluated_projection_version: nil,
        evaluated_method: nil,
        attested_cli_version: nil,
        attested_model_id: nil
      }

    defp classify(gate, invocation, attestation, link, tuple) do
      Outcome.classify(%{
        invocation: invocation,
        attestation: attestation,
        gate: gate,
        link: link,
        candidate: tuple
      })
    end

    # The receipt's own link of this invocation, read when the receipt names
    # one; nil only when it names none (and always on the unlaunched path).
    defp own_link(nil, :unlaunched, _invocation), do: {:ok, nil}
    defp own_link(nil, {_kind, %{link_id: nil}}, _invocation), do: {:ok, nil}

    defp own_link(
           %{id: id, model_invocation_id: own, link_status: status, method: method} = link,
           {_kind, %{link_id: id}},
           invocation
         )
         when is_binary(id) and own == invocation.id and status in @link_statuses and
                method in @methods,
         do: {:ok, link}

    defp own_link(_link, _observation, _invocation), do: :error

    defp inventory(nil), do: {:ok, nil}

    defp inventory(%{evidence: %{"inventory_sha256" => digest}}) when is_binary(digest) do
      if digest =~ @sha256, do: {:ok, digest}, else: :error
    end

    defp inventory(_link), do: :error

    defp links(nil), do: {:ok, []}

    defp links(%{id: id, evidence: %{} = evidence}) do
      with {:ok, digest} <- canonical_sha256(evidence),
           do: {:ok, [%{id: id, evidence_sha256: digest}]}
    end

    # The commitment to the parsed output (a JSON object), nil without one.
    defp output_sha256(nil), do: {:ok, nil}

    defp output_sha256(%{} = output) when not is_struct(output),
      do: canonical_sha256(output)

    defp output_sha256(_output), do: :error

    # Canonical encoding is pure; a value it cannot encode is invalid input,
    # contained here and nowhere else.
    defp canonical_sha256(value) do
      {:ok, hex(Canonical.sha256(value))}
    rescue
      _unencodable -> :error
    end

    defp ref(ref), do: %{id: ref.id, version: ref.version, sha256: hex(ref.sha256)}

    defp usec(nil), do: nil

    defp usec(%DateTime{microsecond: {microsecond, _precision}} = time),
      do: %{time | microsecond: {microsecond, 6}}

    defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  end
end
