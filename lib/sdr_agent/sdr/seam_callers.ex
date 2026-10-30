defmodule SdrAgent.SDR.SeamCallers do
  @moduledoc """
  Test-seam builds only (`:claude_cli_test_seams`, D-268): carries the
  runner's process ancestry into an `SdrAgent.SDR.Action` process.

  Jido's timeout worker is started with a bare `spawn_monitor`, so an
  action process does not inherit the runner's `$callers`. The per-process
  test seams (the prototype runtime, `SdrAgent.Clock`) follow `$callers`,
  so without this an action in a hermetic test would see ordinary runtime
  and the system clock.

  `context/0` is the runner's own ancestry (`self()` then its `$callers`),
  put in the Jido context by `SdrAgent.SDR.Runner`; `adopt/1` appends the
  pids of that ancestry the action process lacks after its own `$callers`.
  Other builds: `context/0` is `%{}` and `adopt/1` changes nothing, so no
  production runtime authority depends on it.
  """

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  if @test_seams do
    @key :sdr_seam_callers

    @doc "The calling (runner) process's ancestry, as a Jido context fragment."
    @spec context() :: map()
    def context, do: %{@key => [self() | Process.get(:"$callers", [])]}

    @doc "Appends the context's ancestry to this process's `$callers`; `:ok`."
    @spec adopt(map()) :: :ok
    def adopt(context) when is_map(context) do
      case Map.get(context, @key) do
        ancestry when is_list(ancestry) ->
          own = Process.get(:"$callers", [])
          added = Enum.filter(ancestry, &(is_pid(&1) and &1 != self() and &1 not in own))
          if added != [], do: Process.put(:"$callers", own ++ added)
          :ok

        _none ->
          :ok
      end
    end

    def adopt(_context), do: :ok
  else
    @doc "No test seams in this build: an empty context fragment."
    @spec context() :: map()
    def context, do: %{}

    @doc "No test seams in this build: changes nothing."
    @spec adopt(term()) :: :ok
    def adopt(_context), do: :ok
  end
end
