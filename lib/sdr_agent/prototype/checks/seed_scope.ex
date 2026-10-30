defmodule SdrAgent.Prototype.Checks.SeedScope do
  @moduledoc """
  The narrow D-268 seed-run activation allowance for ICP, sequence and
  campaign. Only a complete, registered, transaction-live SeedScope may
  authorize its corresponding stored member for the freshly resolved
  operator. The private context is supplied by Seed, not a public domain
  API. Existing lifecycle checks and all other policies remain in force.
  In production this check always refuses and references no authority.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the live operator activates this registered seed run's exact member"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def match?(actor, %{subject: %Ash.Changeset{context: context} = changeset}, _opts)
        when is_map(context) do
      SdrAgent.Prototype.SeedScope.valid?(
        Map.get(context, :sdr_prototype_seed_scope),
        changeset,
        actor
      )
    end

    def match?(_actor, _authorizer, _opts), do: false
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end
end
