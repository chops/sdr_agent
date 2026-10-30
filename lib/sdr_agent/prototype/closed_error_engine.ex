# Compiled only with the prototype authority. The pinned Basic engine owns
# job lifecycle operations; the three error-bearing callbacks close only
# the new unsaved error before delegating.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ClosedErrorEngine do
    @moduledoc """
    E2 (containment packet r4 section 5): the prototype-runtime Oban engine.

    Pure helpers:
      * `closed_unsaved/1` maps `nil` to `nil` and any other value to
        `%{kind: :error, reason: %SdrAgent.Prototype.JobFailedError{}, stacktrace: []}`;
      * `delegation/0` is the reviewed table `[{callback, arity, mode}]`
        with mode `:close_then_delegate` for `discard_job/2`, `error_job/3`
        and `cancel_job/2`, and `:delegate` for the other twenty.

    Every callback of
    `Oban.Engines.Basic` (oban 2.24.0, basic.ex:29-377) delegates with
    identical arguments and returns Basic's result, and the three
    `:close_then_delegate` callbacks first replace the job's
    `unsaved_error` with `closed_unsaved/1` of it.

    Historical error arrays are unchanged. This wrapper does not close raw
    exception telemetry, start queues or change the ordinary runtime engine.
    Basic does not export the optional insert_job/5 or insert_all_jobs/5;
    Oban.Engine retains its existing fallback for those arities.
    """
    @behaviour Oban.Engine

    alias Oban.Engines.Basic
    alias SdrAgent.Prototype.JobFailedError

    @delegation [
      {:init, 2, :delegate},
      {:put_meta, 4, :delegate},
      {:check_meta, 3, :delegate},
      {:refresh, 2, :delegate},
      {:shutdown, 2, :delegate},
      {:insert_job, 3, :delegate},
      {:insert_all_jobs, 3, :delegate},
      {:fetch_jobs, 3, :delegate},
      {:stage_jobs, 3, :delegate},
      {:prune_jobs, 3, :delegate},
      {:rescue_jobs, 3, :delegate},
      {:check_available, 1, :delegate},
      {:complete_job, 2, :delegate},
      {:discard_job, 2, :close_then_delegate},
      {:error_job, 3, :close_then_delegate},
      {:snooze_job, 3, :delegate},
      {:cancel_job, 2, :close_then_delegate},
      {:cancel_all_jobs, 2, :delegate},
      {:delete_job, 2, :delegate},
      {:delete_all_jobs, 2, :delegate},
      {:retry_job, 2, :delegate},
      {:retry_all_jobs, 2, :delegate},
      {:update_job, 3, :delegate}
    ]

    @doc "Pure: the closed replacement of an `unsaved_error`; see the moduledoc."
    @spec closed_unsaved(term()) :: nil | %{kind: :error, reason: Exception.t(), stacktrace: []}
    def closed_unsaved(nil), do: nil
    def closed_unsaved(_unsaved), do: %{kind: :error, reason: %JobFailedError{}, stacktrace: []}

    @doc "Pure: the reviewed delegation table; see the moduledoc."
    @spec delegation() :: [{atom(), non_neg_integer(), :delegate | :close_then_delegate}]
    def delegation, do: @delegation

    @impl Oban.Engine
    def init(conf, opts), do: Basic.init(conf, opts)

    @impl Oban.Engine
    def put_meta(conf, meta, key, value), do: Basic.put_meta(conf, meta, key, value)

    @impl Oban.Engine
    def check_meta(conf, meta, running), do: Basic.check_meta(conf, meta, running)

    @impl Oban.Engine
    def refresh(conf, meta), do: Basic.refresh(conf, meta)

    @impl Oban.Engine
    def shutdown(conf, meta), do: Basic.shutdown(conf, meta)

    @impl Oban.Engine
    def insert_job(conf, changeset, opts), do: Basic.insert_job(conf, changeset, opts)

    @impl Oban.Engine
    def insert_all_jobs(conf, changesets, opts), do: Basic.insert_all_jobs(conf, changesets, opts)

    @impl Oban.Engine
    def fetch_jobs(conf, meta, running), do: Basic.fetch_jobs(conf, meta, running)

    @impl Oban.Engine
    def stage_jobs(conf, queryable, opts), do: Basic.stage_jobs(conf, queryable, opts)

    @impl Oban.Engine
    def prune_jobs(conf, queryable, opts), do: Basic.prune_jobs(conf, queryable, opts)

    @impl Oban.Engine
    def rescue_jobs(conf, queryable, opts), do: Basic.rescue_jobs(conf, queryable, opts)

    @impl Oban.Engine
    def check_available(conf), do: Basic.check_available(conf)

    @impl Oban.Engine
    def complete_job(conf, job), do: Basic.complete_job(conf, job)

    @impl Oban.Engine
    def discard_job(conf, %Oban.Job{} = job) do
      Basic.discard_job(conf, %{job | unsaved_error: closed_unsaved(job.unsaved_error)})
    end

    @impl Oban.Engine
    def error_job(conf, %Oban.Job{} = job, seconds) do
      Basic.error_job(conf, %{job | unsaved_error: closed_unsaved(job.unsaved_error)}, seconds)
    end

    @impl Oban.Engine
    def snooze_job(conf, job, seconds), do: Basic.snooze_job(conf, job, seconds)

    @impl Oban.Engine
    def cancel_job(conf, %Oban.Job{} = job) do
      Basic.cancel_job(conf, %{job | unsaved_error: closed_unsaved(job.unsaved_error)})
    end

    @impl Oban.Engine
    def cancel_all_jobs(conf, queryable), do: Basic.cancel_all_jobs(conf, queryable)

    @impl Oban.Engine
    def delete_job(conf, job), do: Basic.delete_job(conf, job)

    @impl Oban.Engine
    def delete_all_jobs(conf, queryable), do: Basic.delete_all_jobs(conf, queryable)

    @impl Oban.Engine
    def retry_job(conf, job), do: Basic.retry_job(conf, job)

    @impl Oban.Engine
    def retry_all_jobs(conf, queryable), do: Basic.retry_all_jobs(conf, queryable)

    @impl Oban.Engine
    def update_job(conf, job, changes), do: Basic.update_job(conf, job, changes)
  end
end
