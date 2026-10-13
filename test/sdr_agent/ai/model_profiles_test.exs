defmodule SdrAgent.AI.ModelProfilesTest do
  @moduledoc """
  R0-03 (ADR-0004 R0 amendment, item 2; R0 readiness packet, ModelProfile):
  the closed, reviewed profile registry. Exactly `:fake`,
  `:claude_cli_opus` and `:claude_cli_sonnet` exist, both real profiles on
  the one reviewed CLI version; there is no free-text model, and an unknown
  id (or a string, alias or resolved model id) is refused, never resolved.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProfiles.Profile
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake

  test "the registry is closed: exactly the three reviewed profiles" do
    assert ModelProfiles.ids() == [:fake, :claude_cli_opus, :claude_cli_sonnet]
    assert ModelProfiles.real_ids() == [:claude_cli_opus, :claude_cli_sonnet]
    assert Enum.map(ModelProfiles.all(), & &1.id) == ModelProfiles.ids()
  end

  test "the real profiles share the one reviewed CLI version, with their alias and model" do
    version = ModelProfiles.cli_version()
    # R0-08: aligned to the app-owned pin (2.1.294).
    assert version == "2.1.294"

    assert {:ok,
            %Profile{
              id: :claude_cli_opus,
              adapter: ClaudeCLI,
              cli_alias: "opus",
              resolved_model: "claude-opus-5-5",
              cli_version: ^version,
              witness_disposition: :captured_inferred
            }} = ModelProfiles.fetch(:claude_cli_opus)

    assert {:ok,
            %Profile{
              id: :claude_cli_sonnet,
              adapter: ClaudeCLI,
              cli_alias: "sonnet",
              resolved_model: "claude-sonnet-5-5",
              cli_version: ^version,
              witness_disposition: :captured_inferred
            }} = ModelProfiles.fetch(:claude_cli_sonnet)
  end

  test "the Fake is a profile of its own adapter, never a real one" do
    assert {:ok, %Profile{id: :fake, adapter: Fake, cli_alias: nil, cli_version: nil}} =
             ModelProfiles.fetch(:fake)

    refute :fake in ModelProfiles.real_ids()
    assert {:error, :not_a_real_profile} = ModelProfiles.fetch_real(:fake)
  end

  test "unknown ids, strings, aliases and model ids are refused, never resolved" do
    for id <- [
          :claude_cli_haiku,
          :opus,
          nil,
          "claude_cli_opus",
          "opus",
          "sonnet",
          "claude-opus-5-5",
          ~c"claude_cli_opus",
          %{id: :claude_cli_opus}
        ] do
      assert {:error, :unknown_profile} = ModelProfiles.fetch(id), inspect(id)
      assert {:error, :unknown_profile} = ModelProfiles.fetch_real(id), inspect(id)
      refute ModelProfiles.real?(id), inspect(id)
    end

    assert {:ok, %Profile{id: :claude_cli_sonnet}} = ModelProfiles.fetch_real(:claude_cli_sonnet)
    assert ModelProfiles.real?(:claude_cli_opus)
  end

  test "the default real profile is Opus" do
    assert ModelProfiles.default_real() == :claude_cli_opus
  end

  test "grants, allocations and invocations read their profile sets from the registry" do
    assert ModelCallGrant.real_profiles() == ModelProfiles.real_ids()

    assert one_of(ModelInvocation, :profile_id) == ModelProfiles.ids()
    assert one_of(ModelCallAllocation, :profile_id) == ModelProfiles.real_ids()

    assert Ash.Resource.Info.attribute(ModelCallGrant, :profile_ids).constraints[:items][:one_of] ==
             ModelProfiles.real_ids()
  end

  defp one_of(resource, attribute),
    do: Ash.Resource.Info.attribute(resource, attribute).constraints[:one_of]
end
