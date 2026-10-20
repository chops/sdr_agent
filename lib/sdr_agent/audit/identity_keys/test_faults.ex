if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.Audit.IdentityKeys.TestFaults do
    @moduledoc """
    Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): the
    acquisition fault points of plan r8 section 2.5. While `fun` runs in the
    calling process, the identity pass raises at `point`:
    `:before_first_lock`, `{:after_locks, k}` (after the k-th lock of the
    pass) or `:at_publication` (before the record is published). A fault
    raises; it never changes a decision. This module does not exist in dev
    or prod builds.
    """

    @key {__MODULE__, :point}

    @doc "Runs `fun` with the fault `point` armed in the calling process."
    def with_fault(point, fun) when is_function(fun, 0) do
      previous = Process.put(@key, point)

      try do
        fun.()
      after
        if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
      end
    end

    @doc false
    # Called by IdentityKeys at each fault point.
    def trip!(point) do
      if Process.get(@key) == point, do: raise("C3-02 identity key test fault"), else: :ok
    end
  end
end
