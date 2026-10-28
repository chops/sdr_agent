defmodule SdrAgent.Prototype.SetupFlowTest do
  @moduledoc """
  Setup contract r3 (Codex 85ab1090, 57fc6bb4), the PURE control flow of
  `SdrAgent.Prototype.Setup` over the recording stub
  (`SdrAgent.PrototypeSetupEffects`): CONTROL-FLOW evidence only, no
  database, no sandbox, no cluster, no file.

  One test per independently reached row (generated per scenario): the
  fresh and resume success logs; the validated-seed handoff; every phase
  0-3 refusal with its exact `setup_phase` map; every effect's unknown
  return (`{:unexpected, phase}`) and raise (propagates, unrescued, except
  `BootCheck.Refusal`); the actor-mismatch rows; each asserting the exact
  log, so no later effect ran. Also `preflight/2`, `prepare_storage/2`,
  `cluster_identity_check/2` and the non-invoking shape of
  `real_effects/1`. r3 adds exact-validation controls (newlines, digests;
  no normalization), malformed-success controls at the bootstrap, actor
  and `with_repo` boundaries (the bootstrap success is the domain-struct
  fixture), and truthful `:refused` presentation for every returned
  bootstrap and Seed code (no rollback claimed from a code). r4 (N1, Codex
  7be92491) separates a wrapper that never ran the callback (the log ends
  at `with_repo`) from one that ran it and then returned or failed
  malformed (the callback's effects stay, exactly once, then
  `{:unexpected, 1}`), including a wrapper that replays the callback.

  PARKED Q-C draft (contract r4 Q-C, not committed): the early
  `repo_state/0` effect runs first in phase 1, before any storage effect;
  `{:started, true}` refuses there (the query-free nested refusal), the
  two proceeding states are controls, and every other shape is
  `{:unexpected, 1}`; `repo_state_check/1` is its pure decision.

  RED at the declarations (every function `{:error, :not_implemented}`, no
  effect called): each failure exposes a missing declaration, not an
  executed effect scenario (Codex 57fc6bb4).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Actor
  alias SdrAgent.Prototype.Setup
  alias SdrAgent.PrototypeSetupEffects, as: E

  @fresh_log [
    :attach_log,
    :environment,
    :repo_config,
    :cluster_marker,
    :maintenance_identity,
    :app_stopped,
    :read_seed,
    :repo_state,
    :storage_status,
    :storage_up,
    :with_repo,
    :in_transaction,
    :target_identity,
    :migrate,
    :check_migrated,
    :check_fresh,
    :bootstrap,
    :verify,
    :operator_actor,
    :seed_run
  ]

  @resume_log [
    :attach_log,
    :environment,
    :repo_config,
    :cluster_marker,
    :maintenance_identity,
    :app_stopped,
    :read_seed,
    :repo_state,
    :storage_status,
    :with_repo,
    :in_transaction,
    :target_identity,
    :check_resumable,
    :check_fresh,
    :bootstrap,
    :verify,
    :operator_actor,
    :seed_run
  ]

  @other_id 7_400_000_000_000_000_002
  @other_uuid "0190f0f0-0000-7000-8000-0000000000ff"

  # The refusal and known-outcome rows: {id, mode, stop}. Their arguments,
  # answers and expected result are `scenario/1`.
  @rows [
    {:args_invalid_agent, :fresh, :attach_log},
    {:args_agent_atom, :fresh, :attach_log},
    {:args_invalid_correlation, :fresh, :attach_log},
    {:args_bad_digest, :fresh, :attach_log},
    {:args_missing_digest, :fresh, :attach_log},
    {:args_bad_mode, :fresh, :attach_log},
    {:args_seed_dir_not_binary, :fresh, :attach_log},
    {:args_extra_key, :fresh, :attach_log},
    {:args_credential_flag, :fresh, :attach_log},
    {:args_correlation_leading_newline, :fresh, :attach_log},
    {:args_correlation_trailing_newline, :fresh, :attach_log},
    {:args_agent_trailing_newline, :fresh, :attach_log},
    {:args_agent_leading_space, :fresh, :attach_log},
    {:args_digest_trailing_newline, :fresh, :attach_log},
    {:args_digest_leading_newline, :fresh, :attach_log},
    {:args_digest_short, :fresh, :attach_log},
    {:args_digest_long, :fresh, :attach_log},
    {:args_digest_non_hex, :fresh, :attach_log},
    {:args_digest_not_binary, :fresh, :attach_log},
    {:attach_failed, :fresh, :attach_log},
    {:env_wrong, :fresh, :environment},
    {:env_flag_unset, :fresh, :environment},
    {:env_switch_unset, :fresh, :environment},
    {:env_instance_unset, :fresh, :environment},
    {:env_session_unset, :fresh, :environment},
    {:env_not_boolean, :fresh, :environment},
    {:env_extra_key, :fresh, :environment},
    {:repo_mismatch, :fresh, :repo_config},
    {:identity_other_identifier, :fresh, :maintenance_identity},
    {:identity_other_data_directory, :fresh, :maintenance_identity},
    {:identity_not_postgres, :fresh, :maintenance_identity},
    {:marker_error_pending_s4, :fresh, :cluster_marker},
    {:identity_error, :fresh, :maintenance_identity},
    {:marker_zero_identifier, :fresh, :maintenance_identity},
    {:marker_relative_data_dir, :fresh, :maintenance_identity},
    {:identity_missing_key, :fresh, :maintenance_identity},
    {:app_running, :fresh, :app_stopped},
    {:seed_invalid, :fresh, :read_seed},
    {:fresh_database_exists, :fresh, :storage_status},
    {:fresh_status_error, :fresh, :storage_status},
    {:fresh_already_up, :fresh, :storage_up},
    {:fresh_up_error, :fresh, :storage_up},
    {:resume_database_down, :resume, :storage_status},
    {:resume_status_error, :resume, :storage_status},
    {:repo_state_started_in_transaction, :fresh, :repo_state},
    {:repo_state_started_not_boolean, :fresh, :repo_state},
    {:repo_state_started_bare, :fresh, :repo_state},
    {:repo_state_one_tuple, :fresh, :repo_state},
    {:repo_state_three_tuple, :fresh, :repo_state},
    {:repo_state_not_started_tuple, :fresh, :repo_state},
    {:repo_state_nil, :fresh, :repo_state},
    {:repo_state_resume_in_transaction, :resume, :repo_state},
    {:with_repo_error, :fresh, :with_repo},
    {:with_repo_forged_success, :fresh, :with_repo},
    {:nested_transaction, :fresh, :in_transaction},
    {:target_other_database, :fresh, :target_identity},
    {:target_other_identifier, :fresh, :target_identity},
    {:target_unavailable, :fresh, :target_identity},
    {:target_zero_oid, :fresh, :target_identity},
    {:migrated_mismatch, :fresh, :check_migrated},
    {:fresh_not_fresh, :fresh, :check_fresh},
    {:resume_not_resumable, :resume, :check_resumable},
    {:resume_not_fresh, :resume, :check_fresh},
    {:bootstrap_failed, :fresh, :bootstrap},
    {:bootstrap_unknown_error, :fresh, :bootstrap},
    {:bootstrap_plain_maps, :fresh, :bootstrap},
    {:bootstrap_missing_delegation, :fresh, :bootstrap},
    {:bootstrap_extra_key, :fresh, :bootstrap},
    {:bootstrap_with_auditor, :fresh, :bootstrap},
    {:bootstrap_foreign_binding_tenant, :fresh, :bootstrap},
    {:bootstrap_delegation_other_binding, :fresh, :bootstrap},
    {:bootstrap_delegation_other_operator, :fresh, :bootstrap},
    {:bootstrap_nil_id, :fresh, :bootstrap},
    {:boot_refused, :fresh, :verify},
    {:actor_not_found, :fresh, :operator_actor},
    {:actor_other_id, :fresh, :operator_actor},
    {:actor_other_tenant, :fresh, :operator_actor},
    {:actor_other_type, :fresh, :operator_actor},
    {:actor_unknown_error, :fresh, :operator_actor},
    {:actor_plain_map, :fresh, :operator_actor},
    {:actor_ok_nil, :fresh, :operator_actor},
    {:seed_failed, :fresh, :seed_run},
    {:seed_forbidden, :fresh, :seed_run},
    {:seed_binding_mismatch, :fresh, :seed_run},
    {:seed_not_prototype_runtime, :fresh, :seed_run},
    {:seed_not_implemented, :fresh, :seed_run}
  ]

  # Every effect with a closed success shape, its phase and its mode: an
  # unknown return (`:maybe`) stops there as `{:unexpected, phase}`.
  # `repo_config` is excluded: any non-keyword is the documented
  # `repo_target_mismatch` (`check_repo_target/1`).
  @unexpected [
    {:attach_log, 0, :fresh},
    {:environment, 0, :fresh},
    {:cluster_marker, 0, :fresh},
    {:maintenance_identity, 0, :fresh},
    {:app_stopped, 0, :fresh},
    {:read_seed, 0, :fresh},
    {:repo_state, 1, :fresh},
    {:storage_status, 1, :fresh},
    {:storage_up, 1, :fresh},
    {:with_repo, 1, :fresh},
    {:in_transaction, 1, :fresh},
    {:target_identity, 1, :fresh},
    {:migrate, 1, :fresh},
    {:check_migrated, 1, :fresh},
    {:check_resumable, 1, :resume},
    {:check_fresh, 1, :fresh},
    {:bootstrap, 2, :fresh},
    {:verify, 3, :fresh},
    {:operator_actor, 3, :fresh},
    {:seed_run, 3, :fresh}
  ]

  describe "success" do
    test "fresh: the exact effect log and ids only" do
      {effects, observer} = E.stub(%{})
      assert Setup.run(effects, E.args()) == {:ok, success()}
      assert E.names(observer.log.()) == @fresh_log
    end

    test "resume: no storage_up and no migrate; check_resumable then check_fresh" do
      {effects, observer} = E.stub(%{storage_status: :up})
      assert Setup.run(effects, E.args(%{mode: :resume})) == {:ok, success()}
      assert E.names(observer.log.()) == @resume_log
    end

    test "the validated seed is read once and handed to the seed unchanged, with the actor" do
      {effects, observer} = E.stub(%{})
      args = E.args()
      assert Setup.run(effects, args) == {:ok, success()}
      log = observer.log.()

      assert for({:read_seed, a} <- log, do: a) == [[args.seed_dir, args.seed_sha256s]]

      assert [[seed, actor]] = for({:seed_run, a} <- log, do: a)
      assert seed === observer.seed

      assert actor == %Actor{
               type: :prototype_operator,
               id: E.ids().delegation,
               tenant_id: E.ids().tenant
             }
    end

    test "bootstrap gets exactly the agent atom and correlation, with no auditor password" do
      {effects, observer} = E.stub(%{})
      assert Setup.run(effects, E.args()) == {:ok, success()}

      assert for({:bootstrap, a} <- observer.log.(), do: a) == [
               [[agent: :claude_code, session_correlation: "setup-session-0001"]]
             ]
    end

    test "verify gets the created rows and the actor resolver the setup delegation's id" do
      {effects, observer} = E.stub(%{})
      assert Setup.run(effects, E.args()) == {:ok, success()}
      log = observer.log.()
      assert [[created]] = for({:verify, a} <- log, do: a)
      assert created.delegation.id == E.ids().delegation
      assert for({:operator_actor, a} <- log, do: a) == [[E.ids().delegation]]
    end
  end

  describe "refusals and known outcomes (one test per row)" do
    for {id, mode, stop} <- @rows do
      test "#{id} stops at #{stop}" do
        {args, answers, expected} = scenario(unquote(id))
        mode = unquote(mode)
        {effects, observer} = E.stub(answers)
        result = Setup.run(effects, E.args(Map.put_new(args, :mode, mode)))

        assert result == {:error, expected}, "#{unquote(id)}: #{inspect(result)}"
        assert E.names(observer.log.()) == upto(mode, unquote(stop))
      end
    end
  end

  # N1 (Codex 7be92491): a wrapper that RAN the callback and then returned
  # a malformed result, or failed afterwards. The callback's effects ran
  # exactly once and stay in the log; the wrapper's completion is reported
  # as {:unexpected, 1} (the failure location, not the last completed
  # domain phase: phases 2 and 3 already committed and are not undone). No
  # retry, re-entry, second bootstrap or second seed.
  describe "N1: a malformed wrapper result after the callback ran" do
    for {label, wrapper} <- [
          two_tuple: :two_tuple,
          apps_not_list: :apps_not_list,
          error_after_callback: :error_after_callback,
          replays_callback: :replays_callback
        ] do
      test "#{label}: the callback's effects ran once, then {:unexpected, 1}" do
        {effects, observer} = E.stub(%{with_repo: wrapper(unquote(wrapper))})
        result = Setup.run(effects, E.args())
        log = E.names(observer.log.())

        assert result == {:error, {:unexpected, 1}}, inspect(result)
        assert log == @fresh_log, "the executed callback log was not kept exactly once"
        assert Enum.count(log, &(&1 == :bootstrap)) == 1
        assert Enum.count(log, &(&1 == :seed_run)) == 1
        assert Enum.count(log, &(&1 == :with_repo)) == 1
      end
    end
  end

  describe "an unknown return stops as {:unexpected, phase} (one test per effect)" do
    for {name, phase, mode} <- @unexpected do
      test "#{name} returning :maybe" do
        name = unquote(name)
        mode = unquote(mode)
        answers = Map.merge(mode_answers(mode), %{name => :maybe})
        {effects, observer} = E.stub(answers)
        result = Setup.run(effects, E.args(%{mode: mode}))

        assert result == {:error, {:unexpected, unquote(phase)}}, inspect(result)
        assert E.names(observer.log.()) == upto(mode, name)
      end
    end
  end

  describe "a raise propagates unrescued (one test per effect)" do
    for {name, arity} <- E.effects() do
      mode = if name == :check_resumable, do: :resume, else: :fresh

      test "#{name} raising" do
        name = unquote(name)
        mode = unquote(mode)
        answers = Map.put(mode_answers(mode), name, raising(unquote(arity)))
        {effects, observer} = E.stub(answers)

        assert_raise RuntimeError, "synthetic effect failure", fn ->
          Setup.run(effects, E.args(%{mode: mode}))
        end

        assert E.names(observer.log.()) == upto(mode, name)
      end
    end
  end

  describe "preflight/2 and prepare_storage/2" do
    test "preflight returns the internal context and calls no storage or Repo effect" do
      {effects, observer} = E.stub(%{})
      args = E.args()

      assert {:ok, %Setup.Context{} = ctx} = Setup.preflight(effects, args)

      assert ctx == %Setup.Context{
               system_identifier: E.system_identifier(),
               seed: observer.seed,
               seed_sha256s: args.seed_sha256s,
               mode: :fresh,
               agent: :claude_code,
               session_correlation: args.session_correlation
             }

      assert E.names(observer.log.()) == upto(:fresh, :read_seed)
    end

    test "prepare_storage: fresh checks absence then creates; resume only checks presence" do
      {effects, observer} = E.stub(%{})
      assert Setup.prepare_storage(effects, %Setup.Context{mode: :fresh}) == :ok
      assert E.names(observer.log.()) == [:repo_state, :storage_status, :storage_up]

      {effects, observer} = E.stub(%{storage_status: :up})
      assert Setup.prepare_storage(effects, %Setup.Context{mode: :resume}) == :ok
      assert E.names(observer.log.()) == [:repo_state, :storage_status]
    end
  end

  describe "Q-C draft: the early repo_state/0 check (PARKED, contract r4)" do
    test "{:started, false} proceeds through the whole fresh and resume flows (control)" do
      {effects, observer} = E.stub(%{repo_state: {:started, false}})
      assert Setup.run(effects, E.args()) == {:ok, success()}
      assert E.names(observer.log.()) == @fresh_log

      {effects, observer} = E.stub(%{repo_state: {:started, false}, storage_status: :up})
      assert Setup.run(effects, E.args(%{mode: :resume})) == {:ok, success()}
      assert E.names(observer.log.()) == @resume_log
    end

    test "repo_state runs after phase 0 and before every storage effect" do
      {effects, observer} = E.stub(%{})
      assert Setup.run(effects, E.args()) == {:ok, success()}
      log = E.names(observer.log.())
      at = Enum.find_index(log, &(&1 == :repo_state))
      assert Enum.at(log, at - 1) == :read_seed
      assert Enum.at(log, at + 1) == :storage_status
    end

    test "{:started, true} refuses with zero storage effects" do
      {effects, observer} = E.stub(%{repo_state: {:started, true}})
      assert Setup.run(effects, E.args()) == {:error, refused(1, :bootstrap_failed)}
      log = E.names(observer.log.())
      refute :storage_status in log
      refute :storage_up in log
      refute :with_repo in log
    end

    test "repo_state_check/1: the two proceeding states, the refusal, and unknown shapes" do
      assert Setup.repo_state_check(:not_started) == :ok
      assert Setup.repo_state_check({:started, false}) == :ok
      assert Setup.repo_state_check({:started, true}) == {:error, :nested}

      for state <- [
            :maybe,
            :started,
            {:started},
            {:started, :yes},
            {:started, false, :x},
            nil,
            {:not_started}
          ] do
        assert Setup.repo_state_check(state) == {:error, :unexpected}, inspect(state)
      end
    end
  end

  describe "cluster_identity_check/2 (pure, typed facts before equality)" do
    test "equal typed facts on the maintenance database pass" do
      assert Setup.cluster_identity_check(marker(), identity()) == :ok
    end

    test "valid typed facts that differ are a mismatch" do
      for identity <- [
            identity(%{system_identifier: @other_id}),
            identity(%{data_directory: "/synthetic/other/pgdata"}),
            identity(%{database: "sdr_agent_prototype"})
          ] do
        assert Setup.cluster_identity_check(marker(), identity) ==
                 {:error, :cluster_identity_mismatch},
               inspect(identity)
      end
    end

    test "untyped, missing or malformed facts are unexpected, never equal" do
      for {m, i} <- [
            {marker(%{system_identifier: 0}), identity(%{system_identifier: 0})},
            {marker(%{system_identifier: nil}), identity(%{system_identifier: nil})},
            {marker(%{data_dir: ""}), identity(%{data_directory: ""})},
            {marker(%{data_dir: "pgdata"}), identity(%{data_directory: "pgdata"})},
            {Map.delete(marker(), :data_dir), Map.delete(identity(), :data_directory)},
            {marker(), Map.put(identity(), :extra, 1)},
            {:none, identity()},
            {marker(), nil}
          ] do
        assert Setup.cluster_identity_check(m, i) == {:error, :unexpected}, inspect({m, i})
      end
    end
  end

  describe "real_effects/1 (shape only; nothing invoked)" do
    test "exactly the contract's effect names, each a function of its arity" do
      effects = Setup.real_effects(E.args())
      assert is_map(effects)
      assert Enum.sort(Map.keys(effects)) == Enum.sort(Keyword.keys(E.effects()))

      for {name, arity} <- E.effects() do
        assert is_function(Map.get(effects, name), arity), "#{name}/#{arity}"
      end
    end
  end

  ## Scenarios: {args overrides, answers, expected error}

  defp scenario(:args_invalid_agent), do: {%{agent: "gpt"}, %{}, refused(0, :invalid_agent)}
  defp scenario(:args_agent_atom), do: {%{agent: :claude_code}, %{}, refused(0, :invalid_agent)}

  defp scenario(:args_invalid_correlation),
    do: {%{session_correlation: "short"}, %{}, refused(0, :invalid_correlation)}

  defp scenario(:args_bad_digest) do
    pins = E.args().seed_sha256s

    {%{seed_sha256s: %{pins | campaign: String.duplicate("A", 64)}}, %{},
     refused(0, :invalid_arguments)}
  end

  defp scenario(:args_missing_digest) do
    pins = Map.delete(E.args().seed_sha256s, :provenance)
    {%{seed_sha256s: pins}, %{}, refused(0, :invalid_arguments)}
  end

  defp scenario(:args_bad_mode), do: {%{mode: :rebuild}, %{}, refused(0, :invalid_arguments)}

  defp scenario(:args_seed_dir_not_binary),
    do: {%{seed_dir: nil}, %{}, refused(0, :invalid_arguments)}

  defp scenario(:args_extra_key), do: {%{skip_checks: true}, %{}, refused(0, :invalid_arguments)}

  defp scenario(:args_credential_flag),
    do: {%{auditor_credential_out: "/synthetic/credential"}, %{}, refused(0, :invalid_arguments)}

  # S4 (Codex 57fc6bb4): exact validation, no normalization: the
  # correlation uses Authority's absolute-anchored pattern, and agents and
  # digests are compared exactly.
  defp scenario(:args_correlation_leading_newline),
    do: {%{session_correlation: "\nsetup-session-0001"}, %{}, refused(0, :invalid_correlation)}

  defp scenario(:args_correlation_trailing_newline),
    do: {%{session_correlation: "setup-session-0001\n"}, %{}, refused(0, :invalid_correlation)}

  defp scenario(:args_agent_trailing_newline),
    do: {%{agent: "claude_code\n"}, %{}, refused(0, :invalid_agent)}

  defp scenario(:args_agent_leading_space),
    do: {%{agent: " claude_code"}, %{}, refused(0, :invalid_agent)}

  defp scenario(:args_digest_trailing_newline), do: digest(String.duplicate("a", 64) <> "\n")
  defp scenario(:args_digest_leading_newline), do: digest("\n" <> String.duplicate("a", 64))
  defp scenario(:args_digest_short), do: digest(String.duplicate("a", 63))
  defp scenario(:args_digest_long), do: digest(String.duplicate("a", 65))
  defp scenario(:args_digest_non_hex), do: digest(String.duplicate("g", 64))
  defp scenario(:args_digest_not_binary), do: digest(:aaaa)

  defp scenario(:attach_failed),
    do: {%{}, %{attach_log: {:error, :not_implemented}}, {:sink_unavailable, 0}}

  defp scenario(:env_wrong), do: {%{}, env(%{mix_env: :test}), refused(0, :wrong_env)}
  defp scenario(:env_flag_unset), do: {%{}, env(%{flag?: false}), refused(0, :flag_unset)}
  defp scenario(:env_switch_unset), do: {%{}, env(%{switch?: false}), refused(0, :switch_unset)}

  defp scenario(:env_instance_unset),
    do: {%{}, env(%{instance?: false}), refused(0, :switch_unset)}

  defp scenario(:env_session_unset),
    do: {%{}, env(%{session?: false}), refused(0, :session_unset)}

  defp scenario(:env_not_boolean), do: {%{}, env(%{flag?: "true"}), {:unexpected, 0}}
  defp scenario(:env_extra_key), do: {%{}, env(%{debug?: true}), {:unexpected, 0}}

  defp scenario(:repo_mismatch) do
    config = [database: "sdr_agent_dev", port: 5541, socket_dir: "/private/tmp/d237-pg"]
    {%{}, %{repo_config: config}, refused(0, :repo_target_mismatch)}
  end

  defp scenario(:identity_other_identifier),
    do:
      {%{}, %{maintenance_identity: {:ok, identity(%{system_identifier: @other_id})}},
       refused(0, :cluster_identity_mismatch)}

  defp scenario(:identity_other_data_directory),
    do:
      {%{}, %{maintenance_identity: {:ok, identity(%{data_directory: "/synthetic/other"})}},
       refused(0, :cluster_identity_mismatch)}

  defp scenario(:identity_not_postgres),
    do:
      {%{}, %{maintenance_identity: {:ok, identity(%{database: "sdr_agent_prototype"})}},
       refused(0, :cluster_identity_mismatch)}

  defp scenario(:marker_error_pending_s4),
    do: {%{}, %{cluster_marker: {:error, :not_owned}}, {:unexpected, 0}}

  defp scenario(:identity_error),
    do: {%{}, %{maintenance_identity: {:error, :econnrefused}}, {:unexpected, 0}}

  defp scenario(:marker_zero_identifier),
    do: {%{}, %{cluster_marker: {:ok, marker(%{system_identifier: 0})}}, {:unexpected, 0}}

  defp scenario(:marker_relative_data_dir),
    do: {%{}, %{cluster_marker: {:ok, marker(%{data_dir: "pgdata"})}}, {:unexpected, 0}}

  defp scenario(:identity_missing_key),
    do:
      {%{}, %{maintenance_identity: {:ok, Map.delete(identity(), :data_directory)}},
       {:unexpected, 0}}

  defp scenario(:app_running),
    do: {%{}, %{app_stopped: {:error, :app_running}}, refused(0, :app_running)}

  defp scenario(:seed_invalid),
    do:
      {%{}, %{read_seed: fn _dir, _pins -> {:error, {"campaign.json", :invalid}} end},
       refused(0, :seed_invalid)}

  # Q-C draft (contract r4 §Q-C, PARKED): the early repo_state/0 check runs
  # before any storage effect; {:started, true} is the explicit query-free
  # nested refusal (Q-A semantics); any other shape is unexpected, never a
  # guessed :not_started or false.
  defp scenario(:repo_state_started_in_transaction),
    do: {%{}, %{repo_state: {:started, true}}, refused(1, :bootstrap_failed)}

  defp scenario(:repo_state_resume_in_transaction),
    do: {%{}, %{repo_state: {:started, true}, storage_status: :up}, refused(1, :bootstrap_failed)}

  defp scenario(:repo_state_started_not_boolean),
    do: {%{}, %{repo_state: {:started, :yes}}, {:unexpected, 1}}

  defp scenario(:repo_state_started_bare), do: {%{}, %{repo_state: :started}, {:unexpected, 1}}
  defp scenario(:repo_state_one_tuple), do: {%{}, %{repo_state: {:started}}, {:unexpected, 1}}

  defp scenario(:repo_state_three_tuple),
    do: {%{}, %{repo_state: {:started, false, :extra}}, {:unexpected, 1}}

  defp scenario(:repo_state_not_started_tuple),
    do: {%{}, %{repo_state: {:not_started}}, {:unexpected, 1}}

  defp scenario(:repo_state_nil), do: {%{}, %{repo_state: nil}, {:unexpected, 1}}

  defp scenario(:fresh_database_exists),
    do: {%{}, %{storage_status: :up}, refused(1, :database_exists)}

  defp scenario(:fresh_status_error),
    do: {%{}, %{storage_status: {:error, :eacces}}, refused(1, :storage_failed)}

  defp scenario(:fresh_already_up),
    do: {%{}, %{storage_up: {:error, :already_up}}, refused(1, :database_exists)}

  defp scenario(:fresh_up_error),
    do: {%{}, %{storage_up: {:error, :eacces}}, refused(1, :storage_failed)}

  defp scenario(:resume_database_down),
    do: {%{}, %{storage_status: :down}, refused(1, :database_not_resumable)}

  defp scenario(:resume_status_error),
    do: {%{}, %{storage_status: {:error, :eacces}}, refused(1, :storage_failed)}

  defp scenario(:with_repo_error),
    do: {%{}, %{with_repo: fn _fun -> {:error, :repo_not_started} end}, {:unexpected, 1}}

  # with_repo must return exactly `{:ok, callback_result, apps}` with the
  # callback's own result. These two rows never run the callback, so the
  # log genuinely ends at with_repo (N1, Codex 7be92491: a malformed result
  # AFTER the callback ran is its own describe block).
  defp scenario(:with_repo_forged_success),
    do: {%{}, %{with_repo: fn _fun -> {:ok, {:ok, success()}, []} end}, {:unexpected, 1}}

  defp scenario(:nested_transaction),
    do: {%{}, %{in_transaction: true}, refused(1, :bootstrap_failed)}

  defp scenario(:target_other_database),
    do:
      {%{}, %{target_identity: {:ok, target(%{database: "sdr_agent_dev"})}},
       refused(1, :cluster_identity_mismatch)}

  defp scenario(:target_other_identifier),
    do:
      {%{}, %{target_identity: {:ok, target(%{system_identifier: @other_id})}},
       refused(1, :cluster_identity_mismatch)}

  defp scenario(:target_unavailable),
    do: {%{}, %{target_identity: {:error, :live_identity_unavailable}}, {:unexpected, 1}}

  defp scenario(:target_zero_oid),
    do: {%{}, %{target_identity: {:ok, target(%{database_oid: 0})}}, {:unexpected, 1}}

  defp scenario(:migrated_mismatch),
    do: {%{}, %{check_migrated: {:error, :migration_failed}}, refused(1, :migration_failed)}

  defp scenario(:fresh_not_fresh),
    do: {%{}, %{check_fresh: {:error, :database_not_fresh}}, refused(1, :database_not_fresh)}

  defp scenario(:resume_not_resumable),
    do:
      {%{}, %{storage_status: :up, check_resumable: {:error, :database_not_resumable}},
       refused(1, :database_not_resumable)}

  defp scenario(:resume_not_fresh),
    do:
      {%{}, %{storage_status: :up, check_fresh: {:error, :database_not_fresh}},
       refused(1, :database_not_fresh)}

  defp scenario(:bootstrap_failed),
    do: {%{}, %{bootstrap: {:error, :bootstrap_failed}}, refused(2, :bootstrap_failed)}

  defp scenario(:bootstrap_unknown_error),
    do: {%{}, %{bootstrap: {:error, :other}}, {:unexpected, 2}}

  # S1 (Codex 57fc6bb4): a malformed bootstrap success is unexpected, never
  # accepted by loosening the schema.
  defp scenario(:bootstrap_plain_maps) do
    plain = Map.new(E.created(), fn {key, value} -> {key, value && %{id: value.id}} end)
    {%{}, %{bootstrap: {:ok, plain}}, {:unexpected, 2}}
  end

  defp scenario(:bootstrap_missing_delegation),
    do: {%{}, %{bootstrap: {:ok, Map.delete(E.created(), :delegation)}}, {:unexpected, 2}}

  defp scenario(:bootstrap_extra_key),
    do: {%{}, %{bootstrap: {:ok, Map.put(E.created(), :extra, nil)}}, {:unexpected, 2}}

  defp scenario(:bootstrap_with_auditor),
    do: {%{}, %{bootstrap: {:ok, %{E.created() | auditor: E.created().anchor}}}, {:unexpected, 2}}

  defp scenario(:bootstrap_foreign_binding_tenant),
    do:
      {%{}, %{bootstrap: {:ok, put_in(E.created().binding.tenant_id, @other_uuid)}},
       {:unexpected, 2}}

  defp scenario(:bootstrap_delegation_other_binding),
    do:
      {%{}, %{bootstrap: {:ok, put_in(E.created().delegation.binding_id, @other_uuid)}},
       {:unexpected, 2}}

  defp scenario(:bootstrap_delegation_other_operator),
    do:
      {%{}, %{bootstrap: {:ok, put_in(E.created().delegation.operator_user_id, @other_uuid)}},
       {:unexpected, 2}}

  defp scenario(:bootstrap_nil_id),
    do: {%{}, %{bootstrap: {:ok, put_in(E.created().delegation.id, nil)}}, {:unexpected, 2}}

  defp scenario(:boot_refused) do
    verify = fn _created ->
      raise SdrAgent.Prototype.BootCheck.Refusal, code: :binding_not_exact
    end

    {%{}, %{verify: verify}, refused(3, :boot_refused)}
  end

  defp scenario(:actor_not_found),
    do:
      {%{}, %{operator_actor: fn _id -> {:error, :delegation_not_found} end},
       refused(3, :boot_refused)}

  defp scenario(:actor_other_id),
    do: {%{}, %{operator_actor: actor(%{id: @other_uuid})}, refused(3, :boot_refused)}

  defp scenario(:actor_other_tenant),
    do: {%{}, %{operator_actor: actor(%{tenant_id: @other_uuid})}, refused(3, :boot_refused)}

  defp scenario(:actor_other_type),
    do: {%{}, %{operator_actor: actor(%{type: :human})}, refused(3, :boot_refused)}

  defp scenario(:actor_unknown_error),
    do: {%{}, %{operator_actor: fn _id -> {:error, :weird} end}, {:unexpected, 3}}

  defp scenario(:actor_plain_map) do
    actor = fn id -> {:ok, %{type: :prototype_operator, id: id, tenant_id: E.ids().tenant}} end
    {%{}, %{operator_actor: actor}, {:unexpected, 3}}
  end

  defp scenario(:actor_ok_nil),
    do: {%{}, %{operator_actor: fn _id -> {:ok, nil} end}, {:unexpected, 3}}

  defp scenario(:seed_failed), do: {%{}, seed_answer(:seed_failed), seed_refused()}
  defp scenario(:seed_forbidden), do: {%{}, seed_answer(:forbidden), seed_refused()}

  defp scenario(:seed_binding_mismatch),
    do: {%{}, seed_answer(:binding_mismatch), seed_refused()}

  defp scenario(:seed_not_prototype_runtime),
    do: {%{}, seed_answer(:not_prototype_runtime), seed_refused()}

  defp scenario(:seed_not_implemented), do: {%{}, seed_answer(:not_implemented), {:unexpected, 3}}

  ## Helpers

  defp success, do: %{binding_id: E.ids().binding, delegation_id: E.ids().delegation}
  defp refused(phase, reason), do: %{phase: phase, result: :refused, reason: reason}
  # S2 (Codex 57fc6bb4): no Seed code positively establishes a rollback (its
  # documented refusals return before any seed transaction), so each is
  # presented as refused, never rolled_back.
  defp seed_refused, do: %{phase: 3, result: :refused, reason: :seed_failed}
  defp seed_answer(code), do: %{seed_run: fn _seed, _actor -> {:error, code} end}

  defp upto(mode, name) do
    log = if mode == :resume, do: @resume_log, else: @fresh_log
    {before, [^name | _]} = Enum.split_while(log, &(&1 != name))
    before ++ [name]
  end

  defp digest(pin) do
    pins = E.args().seed_sha256s
    {%{seed_sha256s: %{pins | writing_guide: pin}}, %{}, refused(0, :invalid_arguments)}
  end

  # Wrappers that run the callback, then return or fail malformed.
  # `:replays_callback` calls it twice: the orchestrator's callback is
  # single-use, so the second call must run no effect (contract r4 §N1).
  defp wrapper(:two_tuple), do: fn fun -> {:ok, fun.()} end
  defp wrapper(:apps_not_list), do: fn fun -> {:ok, fun.(), :apps} end

  defp wrapper(:error_after_callback) do
    fn fun ->
      _ = fun.()
      {:error, :cleanup_failed}
    end
  end

  defp wrapper(:replays_callback) do
    fn fun ->
      _ = fun.()
      {:ok, fun.(), []}
    end
  end

  defp mode_answers(:resume), do: %{storage_status: :up}
  defp mode_answers(:fresh), do: %{}

  defp env(changes) do
    base = %{mix_env: :dev, flag?: true, switch?: true, instance?: true, session?: true}
    %{environment: Map.merge(base, changes)}
  end

  defp marker(changes \\ %{}),
    do: Map.merge(%{system_identifier: E.system_identifier(), data_dir: E.data_dir()}, changes)

  defp identity(changes \\ %{}) do
    Map.merge(
      %{
        database: "postgres",
        system_identifier: E.system_identifier(),
        data_directory: E.data_dir()
      },
      changes
    )
  end

  defp target(changes) do
    Map.merge(
      %{
        database: "sdr_agent_prototype",
        database_oid: 16_384,
        system_identifier: E.system_identifier()
      },
      changes
    )
  end

  defp actor(changes) do
    fn id ->
      base = %Actor{type: :prototype_operator, id: id, tenant_id: E.ids().tenant}
      {:ok, struct!(base, changes)}
    end
  end

  defp raising(0), do: fn -> raise "synthetic effect failure" end
  defp raising(1), do: fn _a -> raise "synthetic effect failure" end
  defp raising(2), do: fn _a, _b -> raise "synthetic effect failure" end
end
