defmodule SdrAgent.Test.DemoExceptionSource do
  @moduledoc """
  Test-only `SdrAgent.Agents.DemoException.Source` (C2* S3 plan r2 §4.3).
  It is compiled only into test builds (`test/support`), and
  `SdrAgent.Agents.DemoException.source/0` selects it only in test-seam
  builds, only while its Application env is set:

      Application.put_env(:sdr_agent, SdrAgent.Test.DemoExceptionSource,
        attestation: {:ok, attestation},
        live_binding?: true,
        authorization: fn id -> {:ok, authorization} end,
        delegated_grant?: true,
        authorization_id: "test-only-authorization-1"
      )

  The env is read on every call; nothing is cached. Each callback key
  (`:attestation`, `:live_binding?`, `:authorization`, `:delegated_grant?`)
  holds a static answer or a function of the callback's arguments, evaluated
  per call in the calling process. An absent key gives the inert
  `Unattested` answer (`:none`, `false`, `:error`, `false`).
  `:authorization_id` is read by `DemoException.entry/0`, not here.

  Optional instrumentation:

    * `call_log: agent` (an `Agent` holding a list): each call appends
      `{callback, self()}`;
    * `gate_sql: pid`: each call sends `{:gate_sql, "-- source:<callback>"}`
      to `pid`, so a `GateFixtures.capture/1` trace shows where the call
      happened among the statements.

  Tests that set the env are `async: false` and restore it in `on_exit`.
  """

  @behaviour SdrAgent.Agents.DemoException.Source

  @impl true
  def attestation, do: answer(:attestation, [], :none)

  @impl true
  def live_binding?(attestation, tenant_id),
    do: answer(:live_binding?, [attestation, tenant_id], false)

  @impl true
  def authorization(id), do: answer(:authorization, [id], :error)

  @impl true
  def delegated_grant?(grant, authorization),
    do: answer(:delegated_grant?, [grant, authorization], false)

  defp answer(callback, args, inert) do
    config = Application.get_env(:sdr_agent, __MODULE__, [])
    instrument(config, callback)

    case Keyword.get(config, callback, inert) do
      fun when is_function(fun, length(args)) ->
        apply(fun, args)

      fun when is_function(fun) ->
        raise ArgumentError, "#{callback} answers with a function of #{length(args)} arguments"

      value ->
        value
    end
  end

  defp instrument(config, callback) do
    case Keyword.get(config, :call_log) do
      nil -> :ok
      log -> Agent.update(log, &(&1 ++ [{callback, self()}]))
    end

    case Keyword.get(config, :gate_sql) do
      nil -> :ok
      pid -> send(pid, {:gate_sql, "-- source:#{callback}"})
    end

    :ok
  end
end
