defmodule SdrAgent.Agents.Validations.InvocationProfile do
  @moduledoc """
  `ModelInvocation :reserve` (C9): the recorded model profile matches the
  provider — `:fake` for the Fake, a reviewed real profile
  (`SdrAgent.Agents.ModelCallGrant.real_profiles/0`) for ClaudeCLI, none
  for any other provider — and only a ClaudeCLI call carries a grant and
  allocation.
  """
  use Ash.Resource.Validation

  alias SdrAgent.Agents.ModelCallGrant

  @impl true
  def validate(changeset, _opts, _context) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    cond do
      not profile_matches?(get.(:provider), get.(:profile_id)) ->
        {:error, field: :profile_id, message: "does not match the provider"}

      get.(:provider) != :claude_cli and (get.(:grant_id) || get.(:allocation_id)) ->
        {:error, field: :grant_id, message: "only a real-model call is charged to a grant"}

      true ->
        :ok
    end
  end

  defp profile_matches?(:fake, profile), do: profile == :fake
  defp profile_matches?(:claude_cli, profile), do: profile in ModelCallGrant.real_profiles()
  defp profile_matches?(_provider, profile), do: is_nil(profile)
end
