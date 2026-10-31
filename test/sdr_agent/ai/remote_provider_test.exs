defmodule SdrAgent.AI.RemoteProviderTest do
  @moduledoc """
  S-B4 RED (plan r1 4f2863c8 sections A-B, r2 ca6ba97d M1-M4; Codex
  reviews c506097c and 27883f4d): the hosted provider path under the
  trusted `:model_transport :remote`.

  - `SdrAgent.AI.ModelProvider.Runtime` under `:remote` starts no local
    ClaudeCLI tree (`children/0` is `[]`) and resolves the provider to
    `SdrAgent.AI.ModelProvider.ClaudeCLI.Remote`, with no local server,
    port, reaper or shim check. `status/0` under `:remote` reports the
    trusted singleton tenant's worker view (presence, intake, last seen;
    no executable digest) and no local server, or the
    `:provider_not_running` refusal.
  - `ClaudeCLI.Remote.prepare/2` reads the actor's current live binding
    only. No active worker → `{:error, :provider_not_running}`; paused
    intake → `{:error, :provider_held}`; enrolled pins that are not exactly
    a compiled profile's (profile, model and CLI version) →
    `{:error, :worker_pins_incompatible}`. Otherwise it returns
    `ClaudeCLI.provenance/1` of that profile (provider `:claude_cli`).
  - Before any reservation, `prepare/2` refuses a request whose worst-case
    encoded launch response (`SdrAgent.Agents.RemoteLaunch`, below the web
    layer) would exceed 1048576 bytes: `{:error,
    :remote_launch_too_large}`, with no invocation and no charge.
  - `SdrAgent.Agents.RemoteLaunch.encode/1` gives exactly the
    `{"call": launch}` response bytes, with the seven wire keys.
  - Direct-domain control (Codex 27883f4d condition 2): a remote
    reservation whose stored request passes the raw caps but whose launch
    cannot be delivered (escaping input) is refused at reservation. This
    asserts the tightened reservation invariant (addendum 037a03d2, Codex
    entity PASS 77dcda1e): `check_request/1` itself refuses it, so no
    undeliverable call is ever claimed.
  - `SdrAgent.SDR.Model.call/4` end to end in prototype runtime: the
    facade waits, holding no lock (the test's claim, complete and settle
    run during the wait), and returns the released output from the result
    gate's own read: one invocation, one settlement, a `released_unverified`
    release.
  - Each settled call is charged once to the provisioned grant and has
    exactly one reserved, sent and completed event (no failed or unknown).
  - A withheld result (an honest live warning Failure on the invocation,
    so the prototype gate withholds `witness_evidence_present`) gives the
    caller a halt and no business output, although the invocation is
    completed.
  - Wait timeout (`config :sdr_agent, :remote_wait_ms`): the run halts
    `:provider_error` and is failed with the `remote_wait_timeout` detail.
    A late completion is then settled once by the settler, with no
    release, no resume, no refund and no second call or charge.

  Synthetic fixtures only; no model, CLI or network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.GateFixtures
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.RemoteSettlerFixtures, as: S
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Prompts
  alias SdrAgent.SDR.Schemas

  @remote SdrAgent.AI.ModelProvider.ClaudeCLI.Remote
  @launch SdrAgent.Agents.RemoteLaunch
  @launch_keys ~w(call_id model_id profile_id prompt request_digest result_deadline schema)

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    agent = Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    F.remote!()
    put_env!(:model_provider, ClaudeCLI)
    Map.merge(ctx, %{fx: fx})
  end

  ## Helpers

  defp put_env!(key, value) do
    previous = Application.fetch_env(:sdr_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:sdr_agent, key, old)
        :error -> Application.delete_env(:sdr_agent, key)
      end
    end)

    Application.put_env(:sdr_agent, key, value)
  end

  # A live hosted owner, prototype runtime, the provisioned grant and a run.
  defp world!(ctx, pins \\ F.pins()) do
    _owner = H.enrol!(ctx)
    %{token: token, worker: worker} = F.enrol!(ctx.fx, pins)
    H.enter!(ctx)
    grant = G.provision!(ctx.fx)
    run = G.run!(ctx.fx)
    fx = Map.merge(ctx.fx, %{grant: grant, run: run})
    Map.merge(ctx, %{fx: fx, token: token, worker: worker})
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, error.__struct__, Exception.message(error)}
  catch
    kind, reason -> {kind, reason}
  end

  defp remote(fun, args), do: safely(fn -> apply(@remote, fun, args) end)

  defp qualification_input do
    %{
      icp: %{
        name: "Synthetic ICP",
        version: 1,
        employee_count_min: 50,
        employee_count_max: 500,
        industries: ["robotics"],
        geographies: ["US"],
        personas: ["operations"],
        triggers: ["expansion"]
      },
      company: %{
        name: "Example Robotics",
        industry: "robotics",
        employee_count: 120,
        geography: "US"
      },
      contact: %{title: "VP Operations", persona: "operations"},
      evidence: []
    }
  end

  # A facade request in SDR.Model's shape, with `prompt` as given.
  defp request(ctx, prompt) do
    purpose = :qualification
    p = Prompts.ref(purpose)
    s = Schemas.ref(purpose)

    %{
      id: "sb4-#{System.unique_integer([:positive])}",
      run: ctx.fx.run,
      actor: ctx.fx.agent,
      operation: "sdr.qualification",
      prompt: prompt,
      schema: Schemas.for_purpose(purpose),
      input: %{},
      content_capture: :off,
      audit: %{
        purpose: purpose,
        parameters: %{},
        prompt_template_id: p.id,
        prompt_template_version: p.version,
        prompt_template_sha256: p.sha256,
        output_schema_id: s.id,
        output_schema_version: s.version,
        output_schema_sha256: s.sha256
      }
    }
  end

  defp sdr(ctx) do
    %Context{
      actor: ctx.fx.agent,
      tenant_id: ctx.fx.tenant.id,
      run_id: ctx.fx.run.id,
      correlation_id: ctx.fx.run.correlation_id,
      signal_id: "sig-sb4-#{System.unique_integer([:positive])}",
      model: []
    }
  end

  defp invocations(ctx),
    do: F.rows(SdrAgent.Agents.ModelInvocation, "agent_run_id = $1", [F.dump(ctx.fx.run.id)])

  # Waits (bounded) until the run has a pending remote call; returns its row.
  defp await_pending!(ctx, tries \\ 200) do
    case invocations(ctx) do
      [invocation | _] ->
        case F.call_of(invocation["id"] |> F.load()) do
          %{"state" => "pending"} = call -> call
          _other -> retry_pending!(ctx, tries)
        end

      [] ->
        retry_pending!(ctx, tries)
    end
  end

  defp retry_pending!(_ctx, 0), do: flunk("no pending remote call appeared for the run")

  defp retry_pending!(ctx, tries) do
    Process.sleep(25)
    await_pending!(ctx, tries - 1)
  end

  # The caller in its own process, in prototype runtime.
  defp call_async(ctx) do
    Task.async(fn ->
      H.enter!(ctx)

      safely(fn ->
        Model.call(sdr(ctx), :qualification, qualification_input(), Ecto.UUID.generate())
      end)
    end)
  end

  # Claims, completes and settles the run's pending call. `before_complete`
  # runs after the claim (the invocation is sent) and before completion.
  defp drive!(ctx, output \\ S.valid_output(), before_complete \\ fn _launch -> :ok end) do
    _call = await_pending!(ctx)
    nonce = F.nonce()
    launch = F.claim!(ctx.token, nonce)
    before_complete.(launch)

    result =
      F.complete(
        ctx.token,
        nonce,
        launch.call_id,
        launch.request_sha256,
        S.valid_transcript(output)
      )

    assert F.kind(result) == :accepted, "prerequisite: completion #{inspect(result)}"
    S.settle!(ctx.fx)
    launch
  end

  # Settlement audit cardinality of invocation `id`: exactly one of each
  # lifecycle event the domain wrote, and no other terminal event.
  defp settlement_events(id) do
    Map.new(
      ~w(model.invocation.reserved model.invocation.sent model.invocation.completed model.invocation.failed model.invocation.unknown),
      &{&1, S.any_tenant_subject_count(&1, id)}
    )
  end

  defp settled_once,
    do: %{
      "model.invocation.reserved" => 1,
      "model.invocation.sent" => 1,
      "model.invocation.completed" => 1,
      "model.invocation.failed" => 0,
      "model.invocation.unknown" => 0
    }

  ## Runtime under :remote

  describe "Runtime" do
    test "children/0 starts no local ClaudeCLI tree under :remote", _ctx do
      assert Runtime.children() == []
    end

    test "resolve/1 selects ClaudeCLI.Remote with no local server check", _ctx do
      result = safely(fn -> Runtime.resolve([]) end)
      assert match?({:ok, _model}, result), "resolve under :remote: #{inspect(result)}"
      {:ok, model} = result
      assert model[:provider] == @remote
    end

    test "control: under :local the ClaudeCLI tree is still started", _ctx do
      F.remote!(:local)
      assert [{SdrAgent.AI.ModelProvider.ProfileSupervisor, _}] = Runtime.children()
    end

    # Plan r2 row "Runtime.status/0 remote branch" (Codex terminal-settle
    # review f25f89c8: an owned S-B4 deliverable). The tenant comes from
    # the trusted singleton tenant, never a caller argument.
    test "status/0 under :remote reports the worker view and no local server", ctx do
      _ctx = world!(ctx)
      status = safely(fn -> Runtime.status() end)
      assert is_map(status), "status: #{inspect(status, limit: 8)}"
      assert status[:transport] == :remote, "no remote branch: #{inspect(status, limit: 8)}"
      assert status.configured == ClaudeCLI
      assert status.effective == @remote
      assert status.refusal == nil
      assert status.server == :not_applicable
      assert status.cli_executable == nil

      assert %{present?: true, intake: :open, last_seen_at: _} = status.worker
      refute Map.has_key?(status.worker, :executable_sha256)
    end

    test "status/0 under :remote with no worker reports the refusal", _ctx do
      status = safely(fn -> Runtime.status() end)
      assert is_map(status), "status: #{inspect(status, limit: 8)}"
      assert status[:transport] == :remote, "no remote branch: #{inspect(status, limit: 8)}"
      assert status.effective == nil
      assert status.refusal == :provider_not_running
      assert status.worker.present? == false
    end
  end

  ## prepare/2

  describe "ClaudeCLI.Remote.prepare/2" do
    test "an active worker with compiled pins: the exact ClaudeCLI provenance", ctx do
      ctx = world!(ctx)
      {:ok, profile} = SdrAgent.AI.ModelProfiles.fetch_real(:claude_cli_opus)
      result = remote(:prepare, [request(ctx, F.prompt()), []])
      assert result == {:ok, ClaudeCLI.provenance(profile)}
      assert match?({:ok, %{provider: :claude_cli}}, result)
    end

    test "no enrolled worker: provider_not_running", ctx do
      _owner = H.enrol!(ctx)
      H.enter!(ctx)
      grant = G.provision!(ctx.fx)
      run = G.run!(ctx.fx)
      ctx = Map.put(ctx, :fx, Map.merge(ctx.fx, %{grant: grant, run: run}))
      assert remote(:prepare, [request(ctx, F.prompt()), []]) == {:error, :provider_not_running}
    end

    test "a paused worker: provider_held", ctx do
      ctx = world!(ctx)
      :ok = PrototypeFixtures.leave_runtime()
      :ok = PrototypeFixtures.put_live_identity(ctx.destination)
      F.set_intake!(ctx.fx, ctx.worker, :paused)
      H.enter!(ctx)
      assert remote(:prepare, [request(ctx, F.prompt()), []]) == {:error, :provider_held}
    end

    test "enrolled pins with another CLI version: worker_pins_incompatible", ctx do
      ctx = world!(ctx, Map.put(F.pins(), "cli_version", "9.9.9-other"))

      assert remote(:prepare, [request(ctx, F.prompt()), []]) ==
               {:error, :worker_pins_incompatible}
    end

    test "a worst-case escaping prompt: remote_launch_too_large, no reservation", ctx do
      ctx = world!(ctx)
      prompt = String.duplicate(<<1>>, 262_144)
      assert remote(:prepare, [request(ctx, prompt), []]) == {:error, :remote_launch_too_large}

      result = safely(fn -> ModelProvider.complete(request(ctx, prompt), provider: @remote) end)
      assert result == {:error, :remote_launch_too_large}
      assert invocations(ctx) == []
    end

    test "control: a maximal ASCII prompt is deliverable and prepares", ctx do
      ctx = world!(ctx)
      prompt = String.duplicate("a", 262_144)
      assert match?({:ok, %{provider: :claude_cli}}, remote(:prepare, [request(ctx, prompt), []]))
    end
  end

  ## RemoteLaunch encoder

  describe "RemoteLaunch" do
    test "encode/1 is exactly {\"call\": launch} with the seven wire keys", _ctx do
      launch = %{
        call_id: Ecto.UUID.generate(),
        profile_id: :claude_cli_opus,
        model_id: "synthetic-model",
        request_sha256: :crypto.hash(:sha256, "r"),
        prompt: "p",
        schema: %{"type" => "object"},
        result_deadline: ~U[2026-10-31 19:00:00.123456Z]
      }

      result = safely(fn -> apply(@launch, :encode, [launch]) end)
      assert is_binary(result), "encode/1: #{inspect(result)}"
      assert %{"call" => wire} = Jason.decode!(result)
      assert wire |> Map.keys() |> Enum.sort() == @launch_keys
      assert wire["request_digest"] == Base.encode16(launch.request_sha256, case: :lower)
      assert wire["profile_id"] == "claude_cli_opus"
      assert {:ok, _at, 0} = DateTime.from_iso8601(wire["result_deadline"])
      assert safely(fn -> apply(@launch, :max_bytes, []) end) == 1_048_576
    end
  end

  ## Direct-domain reservation control (addendum 037a03d2)

  describe "direct reservation" do
    test "an undeliverable escaping request is refused at remote reservation", ctx do
      ctx = world!(ctx)
      body = F.request(String.duplicate(<<1>>, 262_144))
      # The tightened invariant: the request check itself refuses it.
      assert match?({:error, _message}, SdrAgent.Agents.RemoteCalls.check_request(body)),
             "check_request admitted an undeliverable request"

      result = F.reserve(ctx.fx, %{request: body})

      assert match?({:error, %Ash.Error.Invalid{}}, result),
             "an undeliverable launch was reserved: #{inspect(result, limit: 5)}"

      assert F.count(F.call_resource()) == 0
    end

    test "control: a deliverable maximal ASCII request is reserved", ctx do
      ctx = world!(ctx)
      invocation = F.reserve!(ctx.fx, %{request: F.request(String.duplicate("a", 262_144))})
      assert %{"state" => "pending"} = F.call_of(invocation.id)
    end
  end

  ## SDR.Model end to end

  describe "SDR.Model.call/4" do
    test "waits without a lock and returns the gate's released output", ctx do
      ctx = world!(ctx)
      task = call_async(ctx)
      launch = drive!(ctx)
      result = Task.await(task, 30_000)

      assert match?({:ok, _output, _invocation}, result),
             "remote SDR call: #{inspect(result, limit: 8)}"

      {:ok, output, invocation} = result
      assert invocation.provider == :claude_cli
      assert invocation.status == :completed
      assert (output["score"] || output[:score]) == 82, "released output: #{inspect(output)}"

      assert [one] = invocations(ctx)
      assert F.load(one["id"]) == invocation.id
      assert F.call_row(launch.call_id)["state"] == "completed"
      assert S.release_count(invocation.id) == 1

      assert {:ok, %{disposition: :released_unverified}} =
               SdrAgent.Agents.get_result_release(invocation.id, actor: ctx.fx.agent)

      # One charge to the provisioned grant, and one settlement.
      assert G.charged(ctx.fx) == 1
      assert settlement_events(invocation.id) == settled_once()
    end

    test "a withheld result gives the caller no business output", ctx do
      ctx = world!(ctx)
      task = call_async(ctx)

      # An honest domain Failure (a live warning on the sent invocation)
      # makes the prototype gate withhold: witness_evidence_present. The
      # comparator is not touched.
      launch =
        drive!(ctx, S.valid_output(), fn launch ->
          [row] = invocations(ctx)
          invocation = F.invocation(F.load(row["id"]))
          assert F.load(F.call_of(invocation.id)["id"]) == launch.call_id

          GateFixtures.cause!(invocation,
            severity: :warning,
            operation_id: ctx.fx.run.operation_id
          )
        end)

      result = Task.await(task, 30_000)

      assert match?({:error, {:halt, _reason}}, result),
             "a withheld remote result reached the caller: #{inspect(result, limit: 8)}"

      refute inspect(result) =~ "82"

      assert [row] = invocations(ctx)
      id = F.load(row["id"])
      assert S.invocation_row(id)["status"] == "completed"
      assert F.call_row(launch.call_id)["state"] == "completed"

      assert {:ok, %{disposition: :withheld, reason: :prototype_authority_refused}} =
               SdrAgent.Agents.get_result_release(id, actor: ctx.fx.agent)

      assert S.run_row(ctx.fx.run.id)["status"] != "running"
      assert G.charged(ctx.fx) == 1
      assert settlement_events(id) == settled_once()
    end

    test "timeout: the run fails; a late result settles once with no release", ctx do
      ctx = world!(ctx)
      put_env!(:remote_wait_ms, 2_000)
      task = call_async(ctx)

      # The worker claims during the wait and completes only after it. (A
      # claim after the run failed is refused by the launch check,
      # run_not_running_at_launch, so the late case is a late RESULT.)
      _call = await_pending!(ctx)
      nonce = F.nonce()
      launch = F.claim!(ctx.token, nonce)

      result = Task.await(task, 30_000)
      assert result == {:error, {:halt, :provider_error}}, "timeout: #{inspect(result, limit: 8)}"

      run = S.run_row(ctx.fx.run.id)
      assert run["status"] == "failed"
      assert run["status_reason"] == "provider_error"
      # The discriminator: the wait bound, not any other provider error.
      assert run["failure_reason"] == "model provider error: remote_wait_timeout"

      assert [invocation] = invocations(ctx)
      id = F.load(invocation["id"])
      assert invocation["status"] == "sent", "the caller settled the invocation"
      assert G.charged(ctx.fx) == 1

      late =
        F.complete(
          ctx.token,
          nonce,
          launch.call_id,
          launch.request_sha256,
          S.valid_transcript(S.valid_output())
        )

      assert F.kind(late) == :accepted, "late completion: #{inspect(late)}"
      S.settle!(ctx.fx)
      assert F.call_row(launch.call_id)["state"] == "completed"
      assert S.invocation_row(id)["status"] == "completed"
      assert S.release_count(id) == 0
      assert length(invocations(ctx)) == 1
      assert F.count(F.call_resource()) == 1
      assert S.run_row(ctx.fx.run.id)["status"] == "failed"

      # The late result: one settlement, no refund or second charge.
      assert G.charged(ctx.fx) == 1
      assert settlement_events(id) == settled_once()
    end
  end
end
