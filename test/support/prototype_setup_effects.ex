defmodule SdrAgent.PrototypeSetupEffects do
  @moduledoc """
  The recording stub of `SdrAgent.Prototype.Setup`'s effects map (setup
  contract r2 §2, Codex 85ab1090), for tests only: CONTROL-FLOW evidence,
  never proof of any real dependency.

  `stub/1` returns `{effects, observer}`. Each effect appends
  `{name, args}` to an Agent log and answers from the scripted `answers`
  (a value, or a function of the effect's own arguments), else from the
  r2 §2 success schema. `observer.log.()` is the ordered log;
  `observer.seed` is the exact synthetic seed term `read_seed` returns by
  default (a fresh reference inside, so identity can be checked). Every
  value is synthetic; nothing connects to a database or reads a file.
  """

  alias SdrAgent.Actor

  @effects [
    attach_log: 0,
    environment: 0,
    repo_config: 0,
    cluster_marker: 0,
    maintenance_identity: 0,
    app_stopped: 0,
    read_seed: 2,
    storage_status: 0,
    storage_up: 0,
    with_repo: 1,
    in_transaction: 0,
    target_identity: 0,
    migrate: 0,
    check_migrated: 0,
    check_resumable: 0,
    check_fresh: 0,
    bootstrap: 1,
    verify: 1,
    operator_actor: 1,
    seed_run: 2
  ]

  @system_identifier 7_400_000_000_000_000_001
  @data_dir "/synthetic/d237/pgdata"
  @ids %{
    tenant: "0190f0f0-0000-7000-8000-000000000001",
    anchor: "0190f0f0-0000-7000-8000-000000000002",
    binding: "0190f0f0-0000-7000-8000-000000000003",
    delegation: "0190f0f0-0000-7000-8000-000000000004"
  }

  @doc "The effect names and arities of setup contract r2 §2, in contract order."
  @spec effects() :: keyword(non_neg_integer())
  def effects, do: @effects

  @doc "The synthetic marker identifier the default effects agree on."
  @spec system_identifier() :: pos_integer()
  def system_identifier, do: @system_identifier

  @doc "The synthetic data directory the default effects agree on."
  @spec data_dir() :: String.t()
  def data_dir, do: @data_dir

  @doc "The synthetic ids the default `bootstrap` returns."
  @spec ids() :: map()
  def ids, do: @ids

  @doc "The default arguments: fresh mode, no credential, valid pins."
  @spec args(map()) :: map()
  def args(overrides \\ %{}) do
    pin = String.duplicate("a", 64)

    Map.merge(
      %{
        agent: "claude_code",
        session_correlation: "setup-session-0001",
        seed_dir: "/synthetic/seed",
        seed_sha256s: %{offering_profile: pin, writing_guide: pin, campaign: pin, provenance: pin},
        mode: :fresh,
        auditor_credential_out: nil
      },
      overrides
    )
  end

  @doc "A recording stub; see the moduledoc."
  @spec stub(map()) :: {map(), %{log: (-> list()), seed: map()}}
  def stub(answers \\ %{}) do
    {:ok, log} = Agent.start_link(fn -> [] end)
    seed = %{"synthetic_seed" => true, "ref" => make_ref()}
    defaults = defaults(seed)

    effects =
      for {name, arity} <- @effects, into: %{} do
        {name, recorder(name, arity, log, Map.get(answers, name, Map.fetch!(defaults, name)))}
      end

    {effects, %{log: fn -> Agent.get(log, &Enum.reverse/1) end, seed: seed}}
  end

  @doc "The effect names of a log, in order."
  @spec names(list()) :: [atom()]
  def names(log), do: Enum.map(log, &elem(&1, 0))

  defp recorder(name, 0, log, answer) do
    fn ->
      Agent.update(log, &[{name, []} | &1])
      answer(answer, [])
    end
  end

  defp recorder(name, 1, log, answer) do
    fn a ->
      Agent.update(log, &[{name, [a]} | &1])
      answer(answer, [a])
    end
  end

  defp recorder(name, 2, log, answer) do
    fn a, b ->
      Agent.update(log, &[{name, [a, b]} | &1])
      answer(answer, [a, b])
    end
  end

  defp answer(fun, args) when is_function(fun, length(args)), do: apply(fun, args)
  defp answer(value, _args), do: value

  defp defaults(seed) do
    %{
      attach_log: :ok,
      environment: %{mix_env: :dev, flag?: true, switch?: true, instance?: true, session?: true},
      repo_config: [
        database: "sdr_agent_prototype",
        port: 5541,
        socket_dir: "/private/tmp/d237-pg"
      ],
      cluster_marker: {:ok, %{system_identifier: @system_identifier, data_dir: @data_dir}},
      maintenance_identity:
        {:ok,
         %{database: "postgres", system_identifier: @system_identifier, data_directory: @data_dir}},
      app_stopped: :ok,
      read_seed: fn _dir, _pins -> {:ok, seed} end,
      storage_status: :down,
      storage_up: :ok,
      with_repo: fn fun -> {:ok, fun.(), []} end,
      in_transaction: false,
      target_identity:
        {:ok,
         %{
           database: "sdr_agent_prototype",
           database_oid: 16_384,
           system_identifier: @system_identifier
         }},
      migrate: {:ok, []},
      check_migrated: :ok,
      check_resumable: :ok,
      check_fresh: :ok,
      bootstrap:
        {:ok,
         %{
           tenant: %{id: @ids.tenant},
           anchor: %{id: @ids.anchor},
           auditor: nil,
           binding: %{id: @ids.binding},
           delegation: %{id: @ids.delegation}
         }},
      verify: fn _created -> :ok end,
      operator_actor: fn delegation_id ->
        {:ok, %Actor{type: :prototype_operator, id: delegation_id, tenant_id: @ids.tenant}}
      end,
      seed_run: fn _seed, _actor -> {:ok, %{}} end
    }
  end
end
