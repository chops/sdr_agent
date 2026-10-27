defmodule SdrAgent.AgentEnv.SpendReady do
  @moduledoc """
  Whether the agent environment may spend real model calls under
  `claude_cli` (plan `claude-c2star-s1-environment-plan-r2.md` section 4.6;
  AC6). Three phase hooks, each fail-closed in S1; S2 implements their
  bodies:

    * `preflight/1` — P0, pre-lease (`Launcher.check/1`, only when
      `claude_cli` is requested). Files and the compiled registry; never
      authority.
    * `at_boot/1` — P2, post-lease (`SdrAgent.AgentEnv.Boot.runtime_config!/2`
      for `claude_cli`). Files, registry, the run lease and its nonce; no
      database.
    * `at_start/1` — P3 (`SdrAgent.AgentEnv.Instance.init/1` for
      `claude_cli`). The delegated grant's consistency in the database.

  In S1 `preflight/1` returns `{:error, :authorization_unavailable}` and
  the other two `{:error, :spend_ready_unavailable}`, whatever the input,
  so `claude_cli` is refused before any lease and at every later phase.
  """

  @doc "P0: S1 always refuses (`{:error, :authorization_unavailable}`)."
  @spec preflight(map()) :: :ok | {:error, atom()}
  def preflight(_views), do: {:error, :authorization_unavailable}

  @doc "P2: S1 always refuses (`{:error, :spend_ready_unavailable}`)."
  @spec at_boot(map()) :: :ok | {:error, atom()}
  def at_boot(_views), do: {:error, :spend_ready_unavailable}

  @doc "P3: S1 always refuses (`{:error, :spend_ready_unavailable}`)."
  @spec at_start(map()) :: :ok | {:error, atom()}
  def at_start(_views), do: {:error, :spend_ready_unavailable}
end
