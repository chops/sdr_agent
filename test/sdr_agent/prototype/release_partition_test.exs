defmodule SdrAgent.Prototype.ReleasePartitionTest do
  @moduledoc """
  IF-4 release partition (interfaces r6; amendment items 5 and 6; Codex A1),
  D-237 slice S2.

  - **The pairs.** `:released_unverified` pairs only with
    `:owner_prototype_unverified`; `:withheld` also pairs with the new
    `:prototype_authority_refused`. No ordinary pair changes, and neither new
    value pairs with an ordinary one. S1's freeze adds the values; the pair
    rule is S2's behaviour.

  The prototype-runtime cases (a reconciled receipt is `witness_mode_mismatch`
  and never released; each refusal's exact `prototype_authority_refused`
  code; the refusal-only repeat; Recovery never releases; the lock order)
  follow once S1's runtime fixtures are GREEN.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.ModelResultRelease

  describe "the release pairs" do
    test "released_unverified pairs only with owner_prototype_unverified" do
      assert ModelResultRelease.allowed_pair?(:released_unverified, :owner_prototype_unverified),
             "{:released_unverified, :owner_prototype_unverified} is not an allowed pair"

      for reason <- [
            :reconciled,
            :calibration,
            :witness_mismatch,
            :gate_interrupted,
            :prototype_authority_refused
          ] do
        refute ModelResultRelease.allowed_pair?(:released_unverified, reason), inspect(reason)
      end

      for disposition <- [:released, :withheld, :calibration] do
        refute ModelResultRelease.allowed_pair?(disposition, :owner_prototype_unverified),
               inspect(disposition)
      end
    end

    test "withheld also pairs with prototype_authority_refused, and nothing else does" do
      assert ModelResultRelease.allowed_pair?(:withheld, :prototype_authority_refused),
             "{:withheld, :prototype_authority_refused} is not an allowed pair"

      for disposition <- [:released, :calibration] do
        refute ModelResultRelease.allowed_pair?(disposition, :prototype_authority_refused),
               inspect(disposition)
      end
    end
  end
end
