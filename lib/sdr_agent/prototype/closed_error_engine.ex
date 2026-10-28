# DRAFT r4 (outside the repository; review only; NOT formatted, compiled or
# run). Deny-only declarations: no callback delegates to Oban.Engines.Basic
# in this stage (a delegating stub would execute production behaviour).
# Compiled only with the prototype authority.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ClosedErrorEngine do
    @moduledoc """
    E2 (containment packet r4 section 5): the prototype-runtime Oban engine.

    GREEN contract (not this stage):
      * every callback of `Oban.Engines.Basic` (oban 2.24.0, basic.ex:29-377)
        delegates with identical arguments and returns Basic's result;
      * `discard_job/2`, `error_job/3` and `cancel_job/2` first replace the
        job's `unsaved_error` with `closed_unsaved/1` of it;
      * `closed_unsaved/1` maps any map to
        `%{kind: :error, reason: %SdrAgent.Prototype.JobFailed{}, stacktrace: []}`
        and `nil` to `nil`;
      * `delegation/0` is the reviewed table `[{callback, arity, mode}]`
        with mode `:close_then_delegate` for the three above and
        `:delegate` for the other twenty.

    Stage: deny-only. Every callback returns `{:error, :not_implemented}`.
    """
    @behaviour Oban.Engine

    @doc "Pure: the closed replacement of an `unsaved_error`; see the moduledoc."
    def closed_unsaved(_unsaved), do: red({:error, :not_implemented})

    @doc "Pure: the reviewed delegation table; see the moduledoc."
    def delegation, do: red({:error, :not_implemented})

    @impl Oban.Engine
    def init(_conf, _opts), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def put_meta(_conf, _meta, _key, _value), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def check_meta(_conf, _meta, _running), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def refresh(_conf, _meta), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def shutdown(_conf, _meta), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def insert_job(_conf, _changeset, _opts), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def insert_all_jobs(_conf, _changesets, _opts), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def fetch_jobs(_conf, _meta, _running), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def stage_jobs(_conf, _queryable, _opts), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def prune_jobs(_conf, _queryable, _opts), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def rescue_jobs(_conf, _queryable, _opts), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def check_available(_conf), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def complete_job(_conf, _job), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def discard_job(_conf, _job), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def error_job(_conf, _job, _seconds), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def snooze_job(_conf, _job, _seconds), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def cancel_job(_conf, _job), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def cancel_all_jobs(_conf, _queryable), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def delete_job(_conf, _job), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def delete_all_jobs(_conf, _queryable), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def retry_job(_conf, _job), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def retry_all_jobs(_conf, _queryable), do: red({:error, :not_implemented})

    @impl Oban.Engine
    def update_job(_conf, _job, _changes), do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so callers compile against it.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
