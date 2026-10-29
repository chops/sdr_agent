defmodule SdrAgent.Prototype.ContainmentGuardTest do
  @moduledoc """
  RED for `SdrAgent.Prototype.ContainmentGuard.guard/1` at the task kind
  `:import` and for its guard test protocol (D-237 S4 K0/guard RED packet
  r1).

  Contract encoded (packet section 4 cites each line):

  - `guard(kind)` returns `:ok` or `{:error, code}` with `code` in the
    closed `codes/0` (r3 section 5 "Codes", r4 rows 1e and 6a, r5 entity
    row "Guard verdict");
  - stage A reads only `Containment.entry/0`: no token, or a token of
    another kind, is `entry_unadopted` with NO env or view read (r3
    section 2 stage A; r5 row 1);
  - row 1e, rule G: `relaxation_expired` unless `wall < W_kind`; for the
    task kind `:import`, `W_task = 1_794_034_790_000` ms (r5 rule G, r5
    constants `E_ms` and `M_task`);
  - stage B: `System.get_env/0` then `Containment.config_check(env, kind)`
    (`otel_env`, `crash_dump_env`, `phx_server_env`, in that order);
  - the guard prints and logs nothing and never writes a token.

  The guard test protocol (packet section 3; NEW, NEEDS-REVIEW) is
  `SdrAgent.Prototype.ContainmentGuard.TestSeam`, compiled only when both
  `prototype_authority_compiled` and `prototype_test_seams` are set:

  - `with_refusal(code, fun)`: arms ONE refusal of a closed `code` for the
    calling process and every process that finds the scope through its
    `$callers`; the first guard call that passes stage A and row 1e and
    wins the scope's atomic claim returns `{:error, code}` before any env
    or view read. It cannot produce `:ok` and cannot supply a token;
    `:ok` or a non-code is refused (raise) without running `fun`; the
    prior binding is restored on every exit;
  - `refusal_hits/0`: 0 or 1, the innermost visible scope's claim count;
  - `with_wall_ms(ms, fun)`: row 1e's wall sample becomes
    `max(real_wall, ms)` (it can only move the sample later);
  - `with_read_log(fun)`: `{result, %{env: n, view: n}}`, the stage B and
    stage C entries made by guard calls that find the log scope.

  The shared test VM runs `SdrAgentWeb.Endpoint` (application.ex
  children), so the real view stage is expected to refuse
  (`endpoint_present`, r3 view row "endpoint"); no test here asserts a
  shared-VM `:ok`. The `:ok` happy path is the fresh-VM external test
  `containment_guard_happy_vm_test.exs` (packet OPEN item O-3).

  Env is VM-wide: async false; `ERL_CRASH_DUMP_BYTES` is saved, set to
  "0" and restored; a probe `OTEL_` name and `PHX_SERVER` are set only
  inside a test and always deleted. A run whose environment already has an
  `OTEL_` name or `PHX_SERVER` fails its precondition (names only are
  read; no value is read or printed).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

  alias SdrAgent.Prototype.Containment

  @guard SdrAgent.Prototype.ContainmentGuard
  @seam SdrAgent.Prototype.ContainmentGuard.TestSeam
  @dump_var "ERL_CRASH_DUMP_BYTES"
  @otel_probe "OTEL_D237_K0_GUARD_PROBE"
  @w_task 1_794_034_790_000
  @no_reads %{env: 0, view: 0}
  # The guard file opens (after comment lines) with the authority gate; the
  # seam module sits directly under the test-seam gate.
  @authority_if "if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do\n"
  @seam_if "if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do"
  @seam_def "defmodule SdrAgent.Prototype.ContainmentGuard.TestSeam do"
  # The closed family (packet section 4.2); order is OPEN item O-4.
  @codes [
    :entry_unadopted,
    :relaxation_expired,
    :descriptor_unknown,
    :otel_env,
    :crash_dump_env,
    :phx_server_env,
    :descriptor_unbounded,
    :exporter_destination,
    :tracer_provider,
    :tracer_noop,
    :tracer_sampler,
    :tracer_processor,
    :logger_filters,
    :logger_handlers,
    :endpoint_present,
    :listener_present,
    :listener_unknown,
    :distributed,
    :anchor_sinks
  ]

  setup do
    names = System.get_env() |> Map.keys()
    refute Enum.any?(names, &String.starts_with?(&1, "OTEL_")), "precondition: an OTEL_ name"
    refute "PHX_SERVER" in names, "precondition: PHX_SERVER is set"

    previous = System.get_env(@dump_var)
    System.put_env(@dump_var, "0")

    on_exit(fn ->
      System.delete_env(@otel_probe)
      System.delete_env("PHX_SERVER")

      if previous,
        do: System.put_env(@dump_var, previous),
        else: System.delete_env(@dump_var)
    end)

    :ok
  end

  # -- Structural presence (RED: absent module/function) -------------------

  defp api! do
    assert Code.ensure_loaded?(@guard), "SdrAgent.Prototype.ContainmentGuard is not available"
    assert function_exported?(@guard, :guard, 1), "ContainmentGuard.guard/1 is not implemented"
    assert function_exported?(@guard, :codes, 0), "ContainmentGuard.codes/0 is not implemented"
    assert Code.ensure_loaded?(@seam), "ContainmentGuard.TestSeam is not available"

    for {fun, arity} <- [with_refusal: 2, refusal_hits: 0, with_wall_ms: 2, with_read_log: 1] do
      assert function_exported?(@seam, fun, arity),
             "ContainmentGuard.TestSeam.#{fun}/#{arity} is not implemented"
    end
  end

  defp guard(kind), do: Function.capture(@guard, :guard, 1).(kind)
  defp codes, do: Function.capture(@guard, :codes, 0).()
  defp with_refusal(code, fun), do: Function.capture(@seam, :with_refusal, 2).(code, fun)
  defp refusal_hits, do: Function.capture(@seam, :refusal_hits, 0).()
  defp with_wall_ms(ms, fun), do: Function.capture(@seam, :with_wall_ms, 2).(ms, fun)
  defp with_read_log(fun), do: Function.capture(@seam, :with_read_log, 1).(fun)

  # -- Process helpers -----------------------------------------------------

  # Runs `fun` in a child whose `$callers` is this process followed by its
  # own `$callers` (as TaskBoundary's body process), so the child finds this
  # process's seam scopes. Returns {:returned, v}, {:raised, kind}, :died or
  # :timeout; a raised value is never kept.
  defp in_child(fun) do
    parent = self()
    tag = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, mref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(parent, {tag, outcome(fun)})
      end)

    receive do
      {^tag, value} ->
        Process.demonitor(mref, [:flush])
        value

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        :died
    after
      5_000 ->
        Process.exit(pid, :kill)
        :timeout
    end
  end

  defp outcome(fun) do
    {:returned, fun.()}
  catch
    kind, _reason -> {:raised, kind}
  end

  # A child that adopts `token` (nil: none) and then runs `fun`.
  defp with_token(token, fun) do
    in_child(fn ->
      adopted = if token, do: Containment.put_entry(token), else: :none
      {adopted, fun.()}
    end)
  end

  defp guard_with_token(token), do: with_token(token, fn -> guard(:import) end)

  # One guard call by a child holding `token`, at the injected wall `ms`,
  # under a read log: {child outcome, reads}.
  defp at_wall(ms, token) do
    with_read_log(fn -> with_wall_ms(ms, fn -> guard_with_token(token) end) end)
  end

  defp refusal?({:error, code}), do: code in @codes
  defp refusal?(_other), do: false

  # A completed child guard call: {:returned, {:ok, verdict}} with verdict :ok
  # or a closed refusal.
  defp closed_verdict?({:returned, {:ok, :ok}}), do: true
  defp closed_verdict?({:returned, {:ok, verdict}}), do: refusal?(verdict)
  defp closed_verdict?(_other), do: false

  # Runs `fun` with stdout, stderr and the log captured:
  # {{{result, stdout}, stderr}, log}.
  defp captured(fun) do
    with_log(fn -> with_io(:standard_error, fn -> with_io(fun) end) end)
  end

  # Every way to leave a seam call: return, raise, throw, exit.
  defp leaves do
    [
      fn -> :done end,
      fn -> raise ArgumentError end,
      fn -> throw(:left) end,
      fn -> exit(:left) end
    ]
  end

  # -- Tests ---------------------------------------------------------------

  describe "verdict shape and the closed family" do
    test "codes/0 is exactly the closed family of 19 unique codes" do
      api!()
      got = codes()
      assert is_list(got) and length(got) == length(Enum.uniq(got)), "codes/0 has duplicates"
      assert MapSet.new(got) == MapSet.new(@codes), "codes/0 is not the closed family"
    end

    test "with a valid token the guard reaches stage B and returns :ok or one closed code" do
      api!()
      {result, reads} = with_read_log(fn -> guard_with_token(:import) end)
      assert match?({:returned, {:ok, _verdict}}, result), "the token or guard call failed"
      {:returned, {:ok, verdict}} = result
      assert verdict == :ok or refusal?(verdict), "the verdict is not :ok or a closed code"
      refute verdict == {:error, :entry_unadopted}, "a valid token was refused at stage A"
      refute verdict == {:error, :relaxation_expired}, "row 1e refused before the cutoff"
      assert reads.env == 1, "stage B did not run exactly once after stage A passed"
    end
  end

  describe "stage A: the token, first, with no read" do
    test "no token refuses entry_unadopted with zero env and view reads" do
      api!()
      {result, reads} = with_read_log(fn -> guard_with_token(nil) end)
      assert result == {:returned, {:none, {:error, :entry_unadopted}}}
      assert reads == @no_reads, "the guard read env or view before refusing a missing token"
    end

    test "a token of every other kind refuses entry_unadopted with zero reads" do
      api!()

      for kind <- Containment.kinds() -- [:import] do
        {result, reads} = with_read_log(fn -> guard_with_token(kind) end)
        assert result == {:returned, {:ok, {:error, :entry_unadopted}}}, "kind #{kind} passed"
        assert reads == @no_reads, "kind #{kind}: a read happened before the refusal"
      end
    end

    test "the guard never writes or alters a token" do
      api!()
      unadopted = {:error, :entry_unadopted}
      none = with_token(nil, fn -> {guard(:import), Containment.entry()} end)
      held = with_token(:import, fn -> {guard(:import), Containment.entry()} end)
      assert none == {:returned, {:none, {unadopted, unadopted}}}, "the guard wrote a token"
      assert match?({:returned, {:ok, {_verdict, {:ok, :import}}}}, held), "the token changed"
    end
  end

  describe "row 1e: rule G on the wall sample (test-seam clock)" do
    test "W_task - 1 passes row 1e and reaches stage B" do
      api!()
      {result, reads} = at_wall(@w_task - 1, :import)
      assert match?({:returned, {:ok, _verdict}}, result)
      refute result == {:returned, {:ok, {:error, :relaxation_expired}}}, "W_task - 1 was refused"
      assert reads.env == 1
    end

    test "W_task refuses relaxation_expired with zero env and view reads" do
      api!()
      {result, reads} = at_wall(@w_task, :import)
      assert result == {:returned, {:ok, {:error, :relaxation_expired}}}
      assert reads == @no_reads
    end

    test "an injected time earlier than now cannot move the sample earlier" do
      api!()
      {result, reads} = at_wall(0, :import)
      refute result == {:returned, {:ok, {:error, :relaxation_expired}}}
      assert reads.env == 1, "an earlier injected time changed the path"
    end

    test "a missing token still refuses entry_unadopted at an expired wall (stage A first)" do
      api!()
      {result, reads} = at_wall(@w_task, nil)
      assert result == {:returned, {:none, {:error, :entry_unadopted}}}
      assert reads == @no_reads
    end
  end

  describe "stage B: the real environment (no seam)" do
    test "an OTEL_ name refuses otel_env after one env read and no view read" do
      api!()
      System.put_env(@otel_probe, "1")
      {result, reads} = with_read_log(fn -> guard_with_token(:import) end)
      System.delete_env(@otel_probe)
      assert result == {:returned, {:ok, {:error, :otel_env}}}
      assert reads == %{env: 1, view: 0}
    end

    test "ERL_CRASH_DUMP_BYTES other than \"0\" refuses crash_dump_env" do
      api!()
      System.put_env(@dump_var, "1")
      {result, reads} = with_read_log(fn -> guard_with_token(:import) end)
      System.put_env(@dump_var, "0")
      assert result == {:returned, {:ok, {:error, :crash_dump_env}}}
      assert reads == %{env: 1, view: 0}
    end

    test "PHX_SERVER refuses phx_server_env" do
      api!()
      System.put_env("PHX_SERVER", "1")
      {result, reads} = with_read_log(fn -> guard_with_token(:import) end)
      System.delete_env("PHX_SERVER")
      assert result == {:returned, {:ok, {:error, :phx_server_env}}}
      assert reads == %{env: 1, view: 0}
    end

    test "otel_env precedes phx_server_env" do
      api!()
      System.put_env(@otel_probe, "1")
      System.put_env("PHX_SERVER", "1")
      {result, _reads} = with_read_log(fn -> guard_with_token(:import) end)
      System.delete_env(@otel_probe)
      System.delete_env("PHX_SERVER")
      assert result == {:returned, {:ok, {:error, :otel_env}}}
    end
  end

  describe "guard test protocol: with_refusal/2" do
    test "each closed code, injected, is returned unchanged before any env or view read" do
      api!()

      for code <- @codes do
        {{result, hits}, reads} =
          with_read_log(fn ->
            with_refusal(code, fn -> {guard_with_token(:import), refusal_hits()} end)
          end)

        assert result == {:returned, {:ok, {:error, code}}}, "#{code} was not returned unchanged"
        assert hits == 1, "#{code}: the claim did not fire exactly once"
        assert reads == @no_reads, "#{code}: a read happened before the injected refusal"
      end
    end

    test "an armed refusal grants nothing: no token refuses entry_unadopted, claim unused" do
      api!()
      observed = with_refusal(:otel_env, fn -> {guard_with_token(nil), refusal_hits()} end)
      assert observed == {{:returned, {:none, {:error, :entry_unadopted}}}, 0}
    end

    test "an armed refusal never masks rule G: expired wall refuses, claim unused" do
      api!()

      observed =
        with_refusal(:otel_env, fn ->
          with_wall_ms(@w_task, fn -> {guard_with_token(:import), refusal_hits()} end)
        end)

      assert observed == {{:returned, {:ok, {:error, :relaxation_expired}}}, 0}
    end

    test "one shot: the second guard call in the scope runs the real path" do
      api!()

      {result, reads} =
        with_read_log(fn ->
          with_refusal(:anchor_sinks, fn ->
            with_token(:import, fn -> {guard(:import), guard(:import)} end)
          end)
        end)

      assert match?({:returned, {:ok, {{:error, :anchor_sinks}, _second}}}, result)
      assert reads.env == 1, "the second call did not run stage B exactly once"
    end

    test ":ok and non-codes cannot be armed, and fun does not run" do
      api!()
      parent = self()

      for bad <- [:ok, :bogus, "otel_env", nil, {:error, :otel_env}] do
        observed = outcome(fn -> with_refusal(bad, fn -> send(parent, {:ran, bad}) end) end)
        assert observed == {:raised, :error}, "#{inspect(bad)} was accepted by with_refusal/2"
        refute_received {:ran, ^bad}
      end
    end

    test "the scope is restored after a raise: no claim and a real path outside it" do
      api!()
      raised = outcome(fn -> with_refusal(:distributed, fn -> raise ArgumentError end) end)
      assert raised == {:raised, :error}
      assert refusal_hits() == 0
      {result, reads} = with_read_log(fn -> guard_with_token(:import) end)
      refute result == {:returned, {:ok, {:error, :distributed}}}, "the scope outlived its raise"
      assert reads.env == 1
    end

    test "the scope is restored after return, raise, throw and exit: real path outside it" do
      api!()
      observed = for leave <- leaves(), do: outcome(fn -> with_refusal(:distributed, leave) end)
      expected = [{:returned, :done}, {:raised, :error}, {:raised, :throw}, {:raised, :exit}]
      assert observed == expected

      for _left <- observed do
        assert refusal_hits() == 0
        {result, reads} = with_read_log(fn -> guard_with_token(:import) end)
        refute result == {:returned, {:ok, {:error, :distributed}}}, "the scope outlived its exit"
        assert reads.env == 1
      end
    end

    test "an inner scope's exit restores the outer binding, not an empty scope" do
      api!()

      for leave <- leaves() do
        result =
          with_refusal(:anchor_sinks, fn ->
            _ = outcome(fn -> with_refusal(:distributed, leave) end)
            {guard_with_token(:import), refusal_hits()}
          end)

        assert result == {{:returned, {:ok, {:error, :anchor_sinks}}}, 1},
               "the outer scope was not restored after the inner one left"
      end
    end

    test "one shot under contention: two children share one scope, exactly one claims it" do
      api!()

      {{verdicts, hits}, reads} =
        with_read_log(fn ->
          with_refusal(:anchor_sinks, fn ->
            tasks = for _ <- 1..2, do: Task.async(fn -> guard_with_token(:import) end)
            {Enum.map(tasks, &Task.await(&1, 10_000)), refusal_hits()}
          end)
        end)

      for verdict <- verdicts do
        assert closed_verdict?(verdict), "a child did not complete with :ok or a closed refusal"
      end

      injected = Enum.count(verdicts, &(&1 == {:returned, {:ok, {:error, :anchor_sinks}}}))
      assert injected == 1, "the one-shot claim was won #{injected} times"
      assert hits == 1
      assert reads.env == 1, "the other child did not run the real path exactly once"
    end

    test "with_wall_ms restores the real clock after return, raise, throw and exit" do
      api!()

      for leave <- leaves() do
        _ = outcome(fn -> with_wall_ms(@w_task, leave) end)
        {result, reads} = with_read_log(fn -> guard_with_token(:import) end)

        refute result == {:returned, {:ok, {:error, :relaxation_expired}}},
               "the floor outlived its call"

        assert reads.env == 1
      end
    end

    test "with_read_log counts only its own call and restores the outer log after any exit" do
      api!()

      for leave <- leaves() do
        {_, outer} =
          with_read_log(fn ->
            _ = outcome(fn -> with_read_log(fn -> {guard_with_token(:import), leave.()} end) end)
            guard_with_token(:import)
          end)

        assert outer.env == 1, "the outer log counted the inner call, or was lost"
      end
    end

    test "a scope is invisible to a process that does not name it in $callers" do
      api!()
      parent = self()

      observed =
        with_refusal(:anchor_sinks, fn ->
          spawn(fn ->
            _ = Containment.put_entry(:import)
            send(parent, {:plain, guard(:import)})
          end)

          assert_receive {:plain, verdict}, 5_000
          {verdict, refusal_hits()}
        end)

      refute match?({{:error, :anchor_sinks}, _hits}, observed), "a plain process saw the scope"
      assert elem(observed, 1) == 0
    end
  end

  describe "no output" do
    test "positive control: the three channels capture a child's output" do
      {{{_, out}, err}, log} =
        captured(fn ->
          in_child(fn ->
            IO.puts("k0-guard-control")
            IO.puts(:stderr, "k0-guard-control")
            Logger.error("k0-guard-control")
          end)
        end)

      for {name, text} <- [stdout: out, stderr: err, log: log] do
        assert String.contains?(text, "k0-guard-control"), "the #{name} capture missed the child"
      end
    end

    test "a refusal prints nothing to stdout or stderr and logs nothing" do
      api!()

      for code <- @codes do
        {{{result, out}, err}, log} =
          captured(fn -> with_refusal(code, fn -> guard_with_token(:import) end) end)

        assert result == {:returned, {:ok, {:error, code}}}
        assert out == "", "#{code}: the guard printed"
        assert err == "", "#{code}: the guard wrote to stderr"
        assert log == "", "#{code}: the guard logged"
        refute String.contains?(log, Atom.to_string(code)), "#{code}: code text reached the log"
      end
    end
  end

  describe "source rows" do
    test "only lib/sdr_agent/prototype/containment_guard.ex names the guard test seam" do
      api!()

      files =
        for path <- Path.wildcard("lib/**/*.ex"),
            String.contains?(File.read!(path), "ContainmentGuard.TestSeam"),
            do: path

      assert files == ["lib/sdr_agent/prototype/containment_guard.ex"],
             "the seam is named outside its module file: #{inspect(files)}"
    end

    test "the seam module is defined only under both compile flags" do
      api!()
      source = File.read!("lib/sdr_agent/prototype/containment_guard.ex")
      code = Regex.replace(~r/\A(#[^\n]*\n)*/, source, "")
      seam_gate = Regex.compile!(Regex.escape(@seam_if) <> "\\s*" <> Regex.escape(@seam_def))
      assert String.starts_with?(code, @authority_if), "not wholly authority gated"
      assert Regex.match?(seam_gate, source), "the TestSeam module is not directly seam gated"
    end
  end
end
