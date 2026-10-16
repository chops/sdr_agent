defmodule SdrAgent.Workers.ErrorBoundary do
  @moduledoc """
  The Oban worker error boundary (ADR-0005 C4 amendment, "Error boundaries
  and automatic reports"): no raw Postgrex, DBConnection or Ash error
  reaches Oban's error renderer or `oban_jobs.errors`.

  `use SdrAgent.Workers.ErrorBoundary` (after `use Oban.Worker`) wraps the
  worker's own `perform/1`: every job runs through `perform/3`, and the
  module gains the inventory marker `__sdr_error_boundary__/0`. Worker
  options, `max_attempts`, scheduling and dispositions are unchanged.

  `run/1` runs one job body:

    * a safe result — `:ok`, `{:ok, value}`, `{:snooze, n}`, or `{:error,
      reason}` / `{:cancel, reason}` / `{:discard, reason}` whose reason
      holds no raw error — is returned as it is;
    * a returned `{:error | :cancel | :discard, reason}` whose reason holds a
      raw error struct (nested too) keeps its tag, with the reason replaced
      by the sanitized summary (`SdrAgent.Repo.SafeMetadata.error_summary/1`);
    * a raised exception that is, or holds, a raw error struct becomes
      `{:error, summary}` (Oban retries an error as it retries a raise);
      any other exception is re-raised unchanged;
    * a reason or exception too large for the bounded scan fails closed: it
      is summarized as `"scan_limit"` under its tag (`{:error,
      "scan_limit"}` for a raise).

  It adds no retry, spend or model authority, and treats an unknown model
  outcome no differently: the body's own handling runs first.

  Test-seam builds only (`:claude_cli_test_seams`): `config :sdr_agent,
  :worker_boundary_faults, %{worker => fun}` makes `perform/3` run
  `fun.(job)` *instead of* the worker body, inside the same `run/1`
  boundary — a failure-injection point for the boundary tests. Builds
  without the seam do not compile that branch and ignore the setting.
  """

  alias SdrAgent.Repo.SafeMetadata

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @tagged [:error, :cancel, :discard]

  defmacro __using__(_opts) do
    quote do
      @before_compile SdrAgent.Workers.ErrorBoundary

      @doc false
      def __sdr_error_boundary__, do: true
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable perform: 1

      @impl Oban.Worker
      def perform(job),
        do: SdrAgent.Workers.ErrorBoundary.perform(__MODULE__, job, fn job -> super(job) end)
    end
  end

  @doc "Runs `fun` inside the boundary (see the moduledoc)."
  @spec run((-> term())) :: term()
  def run(fun) when is_function(fun, 0) do
    fun.() |> result()
  rescue
    exception ->
      case SafeMetadata.find_raw_error(exception) do
        nil -> reraise exception, __STACKTRACE__
        error -> {:error, SafeMetadata.error_summary(error)}
      end
  end

  defp result({tag, reason} = result) when tag in @tagged do
    case SafeMetadata.find_raw_error(reason) do
      nil -> result
      error -> {tag, SafeMetadata.error_summary(error)}
    end
  end

  defp result(result), do: result

  if @test_seams do
    @doc false
    # Test-seam builds only: an injected fault replaces the body, inside
    # the boundary.
    def perform(worker, job, body) do
      case Application.get_env(:sdr_agent, :worker_boundary_faults) do
        %{^worker => fault} when is_function(fault, 1) -> run(fn -> fault.(job) end)
        _none -> run(fn -> body.(job) end)
      end
    end
  else
    @doc false
    def perform(_worker, job, body), do: run(fn -> body.(job) end)
  end
end
