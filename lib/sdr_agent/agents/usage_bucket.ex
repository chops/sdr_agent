defmodule SdrAgent.Agents.UsageBucket do
  @moduledoc """
  The trusted usage bucket of a model call (C9; R0 readiness packet,
  owner-approved mapping D-104): where the run started
  (`AgentRun.usage_origin`, set by server code at `:create`) plus what the
  call does (`ModelInvocation.purpose`). Callers never supply a bucket.

  | origin        | bucket                                          |
  |---------------|-------------------------------------------------|
  | `:assignment` | `:b1` for every purpose                         |
  | `:referral`   | `:b1`, except `:outreach_proposal` → `:b5`      |
  | `:reply`      | `:b5`                                           |
  | `:followup`   | `:b4`                                           |
  | `:discovery`  | `:b2`                                           |
  | `:channel`    | `:b3`                                           |
  | `:proof`      | `:proof`                                        |

  A run without an origin (created before R0) has no bucket, and a real
  reservation for it is refused (`:no_usage_origin`).
  """

  @origins [:assignment, :referral, :reply, :followup, :discovery, :channel, :proof]

  @doc "The closed set of run usage origins."
  def origins, do: @origins

  @doc "The usage bucket of a call with `purpose` in a run started from `origin`."
  def bucket(:assignment, _purpose), do: :b1
  def bucket(:referral, :outreach_proposal), do: :b5
  def bucket(:referral, _purpose), do: :b1
  def bucket(:reply, _purpose), do: :b5
  def bucket(:followup, _purpose), do: :b4
  def bucket(:discovery, _purpose), do: :b2
  def bucket(:channel, _purpose), do: :b3
  def bucket(:proof, _purpose), do: :proof
  def bucket(nil, _purpose), do: nil
end
