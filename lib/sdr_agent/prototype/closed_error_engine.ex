# Containment pure GREEN (proposal r1). The pure functions are implemented;
# every engine callback stays deny-only: none delegates to
# Oban.Engines.Basic in this stage (delegating would execute production
# behaviour that no pure test covers). Compiled only with the prototype
# authority.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ClosedErrorEngine do
    @moduledoc """
    E2 (containment packet r4 section 5): the prototype-runtime Oban engine.

    Pure (this stage):
      * `closed_unsaved/1` maps `nil` to `nil` and any other value to
        `%{kind: :error, reason: %SdrAgent.Prototype.JobFailedError{}, stacktrace: []}`;
      * `delegation/0` is the reviewed table `[{callback, arity, mode}]`
        with mode `:close_then_delegate` for `discard_job/2`, `error_job/3`
        and `cancel_job/2`, and `:delegate` for the other twenty.

    Held (a later, separately granted IT-2 GREEN): every callback of
    `Oban.Engines.Basic` (oban 2.24.0, basic.ex:29-377) delegates with
    identical arguments and returns Basic's result, and the three
    `:close_then_delegate` callbacks first replace the job's
    `unsaved_error` with `closed_unsaved/1` of it.

    Stage: pure GREEN. Every callback returns `{:error, :not_implemented}`.
    """
    @behaviour Oban.Engine

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

    # Deny-only callback result (held for IT-2), typed dynamic() so callers
    # compile against it.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
