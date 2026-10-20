if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.SDR.Admission.TestHooks do
    @moduledoc """
    Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): the
    lead admission's real-data guard observer (C3-02 G4, T-F11).

    `observe_guard(observer, fun)` runs `fun`; while it runs, every
    real-data guard check the admission makes in the calling process (step 4
    on the normalized input, `:input`; step 9 on the resolved stored values
    after the locks, `:resolved`) also calls `observer.(stage, domain,
    email)`, right before the check decides. The observer sees the values
    the check receives and cannot choose a verdict. Process-local and
    nested-safe: the caller's previous observer (or none) is restored on
    return, raise, throw and exit. This module does not exist in dev or
    prod builds, where the admission calls no observer.
    """

    @key {__MODULE__, :guard_observer}

    @doc "Runs `fun` with `observer` called at each guard check (see the moduledoc)."
    def observe_guard(observer, fun) when is_function(observer, 3) and is_function(fun, 0) do
      previous = Process.put(@key, observer)

      try do
        fun.()
      after
        if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
      end
    end

    @doc false
    # Called by the admission at each guard check; returns :ok whatever the observer does.
    def checked(stage, domain, email) do
      case Process.get(@key) do
        observer when is_function(observer, 3) -> observer.(stage, domain, email)
        _none -> :ok
      end

      :ok
    end
  end
end
