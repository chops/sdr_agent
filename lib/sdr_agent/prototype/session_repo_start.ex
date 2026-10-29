if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.SessionRepoStart do
    @moduledoc """
    Internal real Repo startup for prototype Session entry. The caller has
    already observed the default Repo absent through RepoState. No caller
    options, configurable connector, application-tree start or retry exists.

    The fixed SQL dependencies start first, then the real Repo starts with
    its existing configuration and the caller as its OTP parent. Only an
    `{:ok, pid}` result succeeds. Other return values, raises, throws and
    catchable exits map to one value-free error. A synchronous linked init
    exit may instead end the body process; TaskBoundary handles its body
    outcome. A concurrent winner is never adopted or stopped.
    The caller attaches SafeLog before entering; asynchronous dependency
    logs remain subject to that existing privacy boundary.
    """

    defmodule RepoStartError do
      @moduledoc """
      Fixed prototype Repo-start failure. It carries no startup cause,
      options, target, credentials or process identifier. TaskBoundary
      presents the existing fixed abort outcome.
      """
      defexception message: "prototype: repo_start_failed"
    end

    @doc "Starts the real configured Repo, or raises the fixed RepoStartError."
    @spec start!() :: :ok
    def start! do
      with {:ok, _sql_apps} <- Application.ensure_all_started(:ecto_sql),
           {:ok, _driver_apps} <- Application.ensure_all_started(:postgrex),
           {:ok, pid} when is_pid(pid) <- SdrAgent.Repo.start_link([]) do
        :ok
      else
        _not_started -> raise RepoStartError
      end
    catch
      _kind, _reason -> raise RepoStartError
    end
  end
end
