defmodule SdrAgent.ReleaseMigration.CampaignExit do
  @moduledoc """
  The release-migration campaign driver's exit taxonomy (C2* slice S3;
  Codex e95a7340 point 5), pure: `classify/1` maps the facts one campaign
  run established to its exit code and lease disposition. The reviewed
  driver derives its exit from this function alone; its stubbed contract is
  `SdrAgent.Agents.ReleaseMigrationHarnessTest` (no driver, no database).

  The facts are exactly four keys; anything else raises `ArgumentError`:

    * `effects`: whether any database or application effect occurred
      (`true` or `false`);
    * `test`: `:pass`, `:fail`, `:not_run`, or `:incomplete` (a child or
      the test run whose end is not confirmed);
    * `evidence`: `:complete`, `:incomplete` or `:inconsistent`;
    * `targets`: a non-empty list, one record per exact target:
      `%{database: name, owned: owned, disposition: disposition}`. An owned
      target (`true`: this run created it) is `:dropped`, `:retained` or
      `:uncertain`; an unowned one (`false`) is `:not_created` or `:foreign`
      (it already existed: a collision, never adopted); unknown ownership
      (`:unknown`) is only `:uncertain`.

  The result is `%{rc:, leases:, test:, evidence:, targets:}`: the primary
  outcome (`test`), the evidence state and every target's own record are
  kept beside the exit. The first rule that applies decides:

  | rc | when | leases |
  |---|---|---|
  | 5 | a target is uncertain, or the test is incomplete | `:keep` |
  | 4 | an owned target is retained | `:quarantine` |
  | 3 | no effect: `effects` false, no target owned, test not run | `:release` |
  | 6 | the evidence is incomplete or inconsistent | `:release` |
  | 0 | test pass, every target owned and dropped, evidence complete | `:release` |
  | 1 | otherwise: failed or not run, every owned target dropped | `:release` |

  So uncertainty never releases a lease; evidence trouble never overrides a
  retained or uncertain target; a collision after an earlier target was
  created is never "no effect" (its records are kept: rc 1 when the owned
  targets were dropped, rc 4 when one was retained); and only rc 0 means a
  passing campaign.
  """

  @evidence [:complete, :incomplete, :inconsistent]
  @keys [:effects, :evidence, :targets, :test]
  @targets [
    {true, :dropped},
    {true, :retained},
    {true, :uncertain},
    {false, :not_created},
    {false, :foreign},
    {:unknown, :uncertain}
  ]
  @tests [:pass, :fail, :not_run, :incomplete]

  @doc """
  Classifies one campaign run's `facts` (see the module documentation).
  Raises `ArgumentError` for facts that cannot be true: a missing or extra
  key, an unknown value, no target, or an ownership/disposition pair
  outside the closed set (an unowned target dropped, an owned target never
  created, unknown ownership with a known disposition).
  """
  def classify(facts) do
    unless valid?(facts) do
      raise ArgumentError, "campaign exit facts that cannot be true: #{inspect(facts)}"
    end

    {rc, leases} = decide(facts)

    %{
      rc: rc,
      leases: leases,
      test: facts.test,
      evidence: facts.evidence,
      targets: facts.targets
    }
  end

  defp decide(%{test: test, evidence: evidence, targets: targets} = facts) do
    cond do
      test == :incomplete or any?(targets, :uncertain) -> {5, :keep}
      any?(targets, :retained) -> {4, :quarantine}
      no_effect?(facts) -> {3, :release}
      evidence != :complete -> {6, :release}
      test == :pass and Enum.all?(targets, &(&1.disposition == :dropped)) -> {0, :release}
      true -> {1, :release}
    end
  end

  defp any?(targets, disposition), do: Enum.any?(targets, &(&1.disposition == disposition))

  defp no_effect?(%{effects: effects, test: test, targets: targets}),
    do: effects == false and test == :not_run and Enum.all?(targets, &(&1.owned == false))

  defp valid?(%{} = facts) do
    Enum.sort(Map.keys(facts)) == @keys and is_boolean(facts.effects) and
      facts.test in @tests and facts.evidence in @evidence and valid_targets?(facts.targets)
  end

  defp valid?(_not_a_map), do: false

  defp valid_targets?([_ | _] = targets), do: Enum.all?(targets, &valid_target?/1)
  defp valid_targets?(_none), do: false

  defp valid_target?(%{database: database, owned: owned, disposition: disposition} = target)
       when map_size(target) == 3 and is_binary(database),
       do: {owned, disposition} in @targets

  defp valid_target?(_other), do: false
end
