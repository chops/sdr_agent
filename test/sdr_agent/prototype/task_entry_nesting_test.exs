defmodule SdrAgent.Prototype.TaskEntryNestingTest do
  @moduledoc """
  Codex f3036a14 must-fix G-R6: the task entry (`SdrAgent.Prototype.Session.enter/1`)
  refuses a call made inside an already-open transaction. It does so before
  the boot check or any database work, with the code that
  `enter_session/2`'s own nesting refusal already uses (`:binding_mismatch`,
  Codex a95a89fb).

  The refusal leaves everything as it was: the caller's transaction (its
  transaction-local setting survives and a `SELECT 1` still works), the
  fixed runtime and the delegations. No rollback throw is caught or turned
  into success.

  Both builds are covered. The test build calls the real module. For the
  production branch, a twin is compiled in this VM from the exact bytes of
  `lib/sdr_agent/prototype/session.ex`, with only the module name rewritten
  and the two prototype flags false for that one compile. The twin's boot
  step calls this VM's test-build `BootCheck`, so only the twin's own order
  is under test. The twin is branch coverage of the source, not the
  production artifact.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.Authority.TestSeam
  alias SdrAgent.Prototype.Session

  @source "lib/sdr_agent/prototype/session.ex"
  @subject "SdrAgent.Prototype.Session"
  @twin SdrAgent.Prototype.SessionProductionTwin
  @flags [:prototype_authority_compiled, :prototype_test_seams]

  setup_all do
    compile_twin!()
    :ok
  end

  # Compiles the production-branch twin, then restores both flags.
  # Construction checks: the subject name is fully rewritten, the compile
  # emits no diagnostic, it defines exactly the twin, and the twin names no
  # authority module.
  defp compile_twin! do
    source = File.read!(@source)
    twin_source = String.replace(source, @subject, inspect(@twin))

    assert twin_source =~ "defmodule #{inspect(@twin)} do"
    refute twin_source =~ ~r/SdrAgent\.Prototype\.Session(?!ProductionTwin)/

    previous = Map.new(@flags, &{&1, Application.fetch_env(:sdr_agent, &1)})

    {modules, diagnostics} =
      try do
        Enum.each(@flags, &Application.put_env(:sdr_agent, &1, false))

        Code.with_diagnostics(fn ->
          Code.compile_string(twin_source, "session_production_twin.ex")
        end)
      after
        Enum.each(previous, fn
          {flag, {:ok, value}} -> Application.put_env(:sdr_agent, flag, value)
          {flag, :error} -> Application.delete_env(:sdr_agent, flag)
        end)
      end

    assert diagnostics == [], "the twin compile emitted #{inspect(diagnostics)}"
    assert Enum.map(modules, &elem(&1, 0)) == [@twin]

    [{@twin, binary}] = modules
    {:ok, {@twin, [atoms: atoms]}} = :beam_lib.chunks(binary, [:atoms])

    authority =
      for {_index, atom} <- atoms,
          String.starts_with?(Atom.to_string(atom), "Elixir.SdrAgent.Prototype.Authority"),
          do: atom

    assert authority == [], "the twin names #{inspect(authority)}"
  end

  defp twin_enter(opts), do: Function.capture(@twin, :enter, 1).(opts)

  defp runtime_state, do: TestSeam.lookup({SdrAgent.Prototype, :runtime})

  defp delegations do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM prototype_delegations", [])
    n
  end

  @doc false
  def handle_query(_event, _measurements, metadata, pid),
    do: send(pid, {:entry_query, metadata[:source]})

  # The sources (nil for raw SQL) of the Repo queries `fun` issues in this
  # process.
  defp query_sources(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:sdr_agent, :repo, :query], &__MODULE__.handle_query/4, self())

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(sources) do
    receive do
      {:entry_query, source} -> drain([source | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  # Calls `entry` inside a caller transaction that has already done its own
  # work (a transaction-local setting), then reads that work back and runs
  # `SELECT 1` in the same transaction. The caller's function returns
  # normally, so `Repo.transaction/1` returns `{:ok, observed}` only if no
  # rollback was thrown.
  defp inside_caller_transaction(entry) do
    Repo.transaction(fn ->
      Repo.query!("SELECT set_config('sdr.g_r6_caller', 'kept', true)", [])
      {result, sources} = query_sources(entry)

      %{rows: [[marker]]} =
        Repo.query!("SELECT current_setting('sdr.g_r6_caller', true)", [])

      %{rows: [[one]]} = Repo.query!("SELECT 1", [])
      %{result: result, sources: sources, marker: marker, one: one, runtime: runtime_state()}
    end)
  end

  test "test build: an open caller transaction is refused before the boot check or any query" do
    fx = bound!(enter_runtime: false)
    assert TestSeam.clear() == :ok
    assert PrototypeFixtures.put_boot_switch(PrototypeFixtures.switch(fx)) == :ok
    assert runtime_state() == nil
    before = delegations()

    result =
      inside_caller_transaction(fn ->
        Session.enter(agent: "codex_cli", session_correlation: "task-entry-nested-0001")
      end)

    assert match?({:ok, %{}}, result), "the caller's transaction gave #{inspect(result)}"
    {:ok, observed} = result

    assert observed.sources == [],
           "the task entry issued Repo queries with sources #{inspect(observed.sources)}"

    assert observed.runtime == nil, "the task entry fixed #{inspect(observed.runtime)}"
    assert observed.result == {:error, :binding_mismatch}
    assert {observed.marker, observed.one} == {"kept", 1}
    assert runtime_state() == nil
    assert delegations() == before
  end

  test "test build: at top level the same entry still boots and enters (control)" do
    fx = bound!(enter_runtime: false)
    assert TestSeam.clear() == :ok
    assert PrototypeFixtures.put_boot_switch(PrototypeFixtures.switch(fx)) == :ok
    before = delegations()

    result = Session.enter(agent: "codex_cli", session_correlation: "task-entry-nested-0002")
    assert match?({:ok, %{}}, result), "task entry: #{inspect(result)}"
    assert SdrAgent.Prototype.runtime() == :prototype
    assert delegations() == before + 1
  end

  test "production branch: an open caller transaction is refused before the boot check or any query" do
    assert TestSeam.clear() == :ok
    assert runtime_state() == nil

    result =
      inside_caller_transaction(fn ->
        twin_enter(agent: "codex_cli", session_correlation: "task-entry-nested-0003")
      end)

    assert match?({:ok, %{}}, result), "the caller's transaction gave #{inspect(result)}"
    {:ok, observed} = result

    assert observed.sources == [],
           "the task entry issued Repo queries with sources #{inspect(observed.sources)}"

    assert observed.runtime == nil, "the task entry fixed #{inspect(observed.runtime)}"
    assert observed.result == {:error, :binding_mismatch}
    assert {observed.marker, observed.one} == {"kept", 1}
  end

  test "production branch: at top level the entry boots, then refuses outside prototype runtime (control)" do
    assert TestSeam.clear() == :ok

    {result, sources} =
      query_sources(fn ->
        twin_enter(agent: "codex_cli", session_correlation: "task-entry-nested-0004")
      end)

    assert "prototype_database_bindings" in sources,
           "prerequisite: the boot read was not observed, sources #{inspect(sources)}"

    assert result == {:error, :not_prototype_runtime}
  end
end
