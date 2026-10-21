if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.Outreach.Webhooks.TestHooks do
    @moduledoc """
    Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): one
    interleaving point inside a webhook's processing transaction (C3-02 G6;
    plan r8 section 16.6; T-K2 and T-K3).

    `with_hook(point, hook, fun)` runs `fun`; the first time the processing
    in the calling process reaches `point`, it calls the arity-0 `hook` once,
    inside the processing transaction. The hook is consumed (removed) before
    it is invoked, so a hook that re-enters the processing cannot fire
    again, and it cannot choose the processing's result. Points:

      * `:after_reply_match`: after the reply's unlocked match, before its
        target locks and revalidation;
      * `:before_unsubscribe_pass`: after the unsubscribe link's contact
        read and token check, before its key pass.

    Process-local and nested-safe: the previous hooks (or none) are restored
    in an `after` on return, raise, throw and exit. This module does not
    exist in dev or prod builds, where the webhook calls no hook.
    """

    @key {__MODULE__, :hooks}
    @points [:after_reply_match, :before_unsubscribe_pass]

    @doc "Runs `fun` with `hook` installed at `point` (see the moduledoc)."
    def with_hook(point, hook, fun)
        when point in @points and is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@key)
      Process.put(@key, Map.put(previous || %{}, point, hook))

      try do
        fun.()
      after
        if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
      end
    end

    @doc false
    # Called by the webhook at each point; always returns :ok.
    def reached(point) do
      case Process.get(@key) do
        %{^point => hook} = hooks ->
          Process.put(@key, Map.delete(hooks, point))
          hook.()
          :ok

        _none ->
          :ok
      end
    end
  end
end
