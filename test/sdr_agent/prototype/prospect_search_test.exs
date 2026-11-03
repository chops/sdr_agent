defmodule SdrAgent.Prototype.ProspectSearchTest do
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.HostedOwnerFixtures, as: H

  @facade SdrAgent.Prototype.ProspectSearch
  @supervisor SdrAgent.Discovery.Supervisor
  @limiter SdrAgent.Discovery.Limiter

  defmodule FakeClient do
    def execute(request) do
      send(
        Application.fetch_env!(:sdr_agent, :prospect_search_test_receiver),
        {:provider_call, self(), request}
      )

      receive do
        :return -> {:ok, %{kind: request.kind, candidates: [], cost_dollars: 0.007}}
        {:return, outcome} -> outcome
      end
    end
  end

  setup do
    loaded!(@facade)
    loaded!(@supervisor)
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    reviewer = human(:reviewer, ctx.fx.tenant)
    H.enter!(ctx)

    env = [
      prospect_search_enabled: true,
      prospect_search_test_key: "synthetic-key",
      prospect_search_client: FakeClient,
      prospect_search_test_receiver: self(),
      prospect_search_cooldown_ms: 0,
      prospect_search_timeout_ms: 30_000
    ]

    previous = for {key, _} <- env, do: {key, Application.fetch_env(:sdr_agent, key)}
    for {key, value} <- env, do: Application.put_env(:sdr_agent, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:sdr_agent, key, old)
          :error -> Application.delete_env(:sdr_agent, key)
        end
      end
    end)

    start_supervised!(@supervisor)
    Map.merge(ctx, %{user: enrolled.user, owner: enrolled.owner, reviewer: reviewer})
  end

  defp start(user, request \\ %{kind: :company, query: "synthetic developer tools"}),
    do: call(@facade, :start, [user, request])

  defp counts do
    Map.new(
      ~w(accounts contacts leads owner_prospect_intakes agent_runs remote_model_calls operations),
      fn table ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM " <> table)
        {table, n}
      end
    )
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, remaining - 1)
        )
  end

  test "available only to a fresh live owner", ctx do
    assert call(@facade, :available?, [ctx.user])

    for actor <- [ctx.reviewer, ctx.fx.auditor, ctx.fx.actor, nil] do
      refute call(@facade, :available?, [actor])
      assert {:error, :forbidden} = start(actor)
    end

    refute_received {:provider_call, _, _}
  end

  test "missing config or key is unavailable, never an accidental provider request", ctx do
    Application.put_env(:sdr_agent, :prospect_search_enabled, false)
    refute call(@facade, :available?, [ctx.user])
    assert {:error, :unavailable} = start(ctx.user)
    Application.put_env(:sdr_agent, :prospect_search_enabled, true)
    Application.put_env(:sdr_agent, :prospect_search_test_key, nil)
    refute call(@facade, :available?, [ctx.user])
    assert {:error, :unavailable} = start(ctx.user)
    refute_received {:provider_call, _, _}
  end

  test "company context facade checks owner before validating suggestions", ctx do
    candidate = %{kind: :company, id: "server-card", name: "Cedar Tools"}
    input = %{website_url: "https://cedar.test", domain: "cedar.test"}
    assert {:ok, context} = call(@facade, :company_context, [ctx.user, candidate, input])
    assert context.name == "Cedar Tools"

    assert {:error, :forbidden} =
             call(@facade, :company_context, [ctx.reviewer, candidate, input])

    refute_received {:provider_call, _, _}
  end

  test "malformed, oversized or caller-controlled request fields refuse before egress", ctx do
    for request <- [
          nil,
          %{},
          %{kind: :other, query: "x"},
          %{kind: :company, query: ""},
          %{kind: :company, query: String.duplicate("x", 501)},
          %{kind: :company, query: <<255>>},
          %{kind: :company, query: "x", url: "https://other.test"},
          %{kind: :people, query: "CEO", company: nil},
          %{kind: :contents, company: %{}}
        ] do
      assert {:error, :invalid_input} = start(ctx.user, request)
    end

    refute_received {:provider_call, _, _}
  end

  test "search sends an asynchronous closed outcome and writes no business/model state", ctx do
    before = counts()
    assert {:ok, id} = start(ctx.user)
    assert is_binary(id)
    assert_receive {:provider_call, worker, %{kind: :company}}, 1000
    send(worker, :return)
    assert_receive {:prospect_search_result, ^id, {:ok, %{candidates: []}}}, 1000
    assert counts() == before
  end

  test "unsafe well-formed company contexts refuse before paid egress", ctx do
    for company <- [
          %{
            id: "c",
            name: "Cedar",
            domain: "linkedin.com",
            website_url: "https://www.linkedin.com/company/cedar"
          },
          %{id: "c", name: "Cedar", domain: "cedar.test", website_url: "http://cedar.test"},
          %{id: "c", name: "Cedar", domain: "other.test", website_url: "https://cedar.test"}
        ],
        kind <- [:people, :contents] do
      request =
        if kind == :people,
          do: %{kind: kind, company: company, query: "CEO"},
          else: %{kind: kind, company: company}

      assert {:error, :invalid_input} = start(ctx.user, request)
    end

    refute_received {:provider_call, _, _}
  end

  test "two tabs cannot start simultaneous paid actions for the same owner", ctx do
    assert {:ok, _id} = start(ctx.user)
    assert_receive {:provider_call, _worker, _}, 1000

    other =
      Task.async(fn ->
        H.enter!(ctx)
        start(ctx.user)
      end)

    assert {:error, :busy} = Task.await(other)
    refute_receive {:provider_call, _, _}, 20
  end

  test "owner cancellation stops the holder and permits are monitor-released", ctx do
    assert {:ok, id} = start(ctx.user)
    assert_receive {:provider_call, worker, _}, 1000
    ref = Process.monitor(worker)
    assert :ok = call(@facade, :cancel, [ctx.user, id])
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1000
    assert_receive {:prospect_search_result, ^id, {:error, :cancelled}}, 1000
    eventually(fn -> match?({:ok, _}, start(ctx.user)) end)
  end

  test "a different tab cannot cancel a request by guessing its id", ctx do
    assert {:ok, id} = start(ctx.user)
    assert_receive {:provider_call, worker, _}, 1000

    other =
      Task.async(fn ->
        H.enter!(ctx)
        call(@facade, :cancel, [ctx.user, id])
      end)

    assert {:error, :forbidden} = Task.await(other)
    assert Process.alive?(worker)
  end

  test "socket process exit cancels its provider worker", ctx do
    parent = self()

    # Task propagates the fixture's explicit $callers clock/authority seams,
    # unlike raw spawn. Its exit still exercises real receiver monitoring.
    task =
      Task.async(fn ->
        H.enter!(ctx)
        send(parent, {:started, self(), start(ctx.user)})

        receive do
          :stop -> :ok
        end
      end)

    socket = task.pid

    assert_receive {:started, ^socket, {:ok, _id}}, 1000
    assert_receive {:provider_call, worker, _}, 1000
    ref = Process.monitor(worker)
    send(socket, :stop)
    Task.await(task)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1000
  end

  test "total deadline terminates an unresponsive provider without retry", ctx do
    Application.put_env(:sdr_agent, :prospect_search_timeout_ms, 30)
    Application.put_env(:sdr_agent, :prospect_search_cooldown_ms, 5000)
    assert {:ok, id} = start(ctx.user)
    assert_receive {:provider_call, worker, _}, 1000
    assert_receive {:prospect_search_result, ^id, {:error, :timeout}}, 1000
    refute Process.alive?(worker)
    assert {:error, :cooldown} = start(ctx.user)
    refute_receive {:provider_call, _, _}, 30
  end

  test "completion applies the owner-wide cooldown", ctx do
    Application.put_env(:sdr_agent, :prospect_search_cooldown_ms, 5000)
    assert {:ok, id} = start(ctx.user)
    assert_receive {:provider_call, worker, _}, 1000
    send(worker, :return)
    assert_receive {:prospect_search_result, ^id, {:ok, _}}, 1000
    assert {:error, :cooldown} = start(ctx.user)
  end

  test "revocation is checked fresh before subsequent action or display", ctx do
    assert call(@facade, :authorized?, [ctx.user])
    assert {:ok, _} = H.disable(ctx, ctx.owner.id, actor: ctx.user)
    refute call(@facade, :authorized?, [ctx.user])
    assert {:error, :forbidden} = start(ctx.user)
    refute_received {:provider_call, _, _}
  end

  test "search subtree crash kills tasks without restarting paid requests", ctx do
    assert {:ok, _id} = start(ctx.user)
    assert_receive {:provider_call, worker, _}, 1000
    limiter = Process.whereis(@limiter)
    ref = Process.monitor(worker)
    Process.exit(limiter, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1000

    eventually(fn ->
      pid = Process.whereis(@limiter)
      is_pid(pid) and pid != limiter
    end)

    refute_receive {:provider_call, _, _}, 30
  end

  test "a forged result message cannot release a paid operation permit", ctx do
    assert {:ok, id} = start(ctx.user)
    assert_receive {:provider_call, worker, _}, 1000
    send(Process.whereis(@limiter), {:prospect_search_result, id, {:ok, %{candidates: []}}})
    assert {:error, :busy} = start(ctx.user)
    assert Process.alive?(worker)
  end
end
