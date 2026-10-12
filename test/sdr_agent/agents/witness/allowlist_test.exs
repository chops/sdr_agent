defmodule SdrAgent.Agents.Witness.AllowlistTest do
  @moduledoc """
  R0-07 REQ-07-1 (ADR-0005 R0 amendment, item 1; R0-07 entity PASS at
  1da747a): an allowlist entry names exactly `(provider, cli_version,
  profile_id, model_id, projection_version, method)` and nothing else. It is
  matched against the invocation's recorded identity together with the
  projection and method evaluated for the exchange. `profile_id: nil` exists
  only for generation-1 rows (written before R0, which carry no profile),
  and a profiled entry matches only generation-2 rows of that profile. The
  shipped 2.1.291 entry is that generation-1 entry; there is no shipped
  `:calibration` stage.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.Witness

  @v3 "claude-message-json/3+prompt-builder/1"

  @gen1_entry %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    profile_id: nil,
    model_id: "claude-opus-5-5",
    projection_version: @v3,
    method: :propagated_id
  }

  @opus_entry %{@gen1_entry | profile_id: :claude_cli_opus}
  @sonnet_entry %{@gen1_entry | profile_id: :claude_cli_sonnet, model_id: "claude-sonnet-5-5"}

  setup do
    config = Application.get_env(:sdr_agent, Witness)
    on_exit(fn -> Application.put_env(:sdr_agent, Witness, config) end)
    :ok
  end

  defp put_entries(entries) do
    Application.put_env(
      :sdr_agent,
      Witness,
      Keyword.put(Application.get_env(:sdr_agent, Witness, []), :reconciled_methods, entries)
    )
  end

  defp invocation(overrides) do
    struct(
      ModelInvocation,
      Map.merge(
        %{
          provider: :claude_cli,
          provider_version: "2.1.291",
          profile_id: :claude_cli_opus,
          model_id: "claude-opus-5-5",
          ledger_generation: 2
        },
        Map.new(overrides)
      )
    )
  end

  defp gen1, do: invocation(profile_id: nil, ledger_generation: 1)
  defp opus, do: invocation([])
  defp sonnet, do: invocation(profile_id: :claude_cli_sonnet, model_id: "claude-sonnet-5-5")

  defp allowlisted?(invocation, projection \\ @v3, method \\ :propagated_id),
    do: call(:allowlisted?, [invocation, projection, method])

  describe "entry shape: exactly six keys" do
    test "only six-key entries survive; the old four-key shape and extra keys are dropped" do
      four_key = Map.drop(@gen1_entry, [:profile_id, :model_id])

      put_entries([
        @opus_entry,
        four_key,
        Map.put(@opus_entry, :stage, :calibration),
        Map.delete(@opus_entry, :model_id),
        Map.delete(@opus_entry, :profile_id),
        %{@opus_entry | profile_id: "claude_cli_opus"},
        %{@opus_entry | model_id: :"claude-opus-5-5"},
        %{@opus_entry | cli_version: nil},
        :propagated_id
      ])

      assert Witness.reconciled_methods() == [@opus_entry]
    end

    test "a dropped entry never matches, even for the identity it names" do
      put_entries([Map.put(@opus_entry, :stage, :calibration)])
      refute allowlisted?(opus())

      put_entries([Map.drop(@gen1_entry, [:profile_id, :model_id])])
      refute allowlisted?(gen1())
      refute allowlisted?(opus())
    end

    test "every key is compared: changing any one of them stops the match" do
      put_entries([@opus_entry])
      assert allowlisted?(opus())

      refute allowlisted?(invocation(provider: :fake))
      refute allowlisted?(invocation(provider_version: "2.1.294"))
      refute allowlisted?(invocation(profile_id: :claude_cli_sonnet))
      refute allowlisted?(invocation(model_id: "claude-opus-5-6"))
      refute allowlisted?(opus(), "claude-message-json/2+prompt-builder/1")
      refute allowlisted?(opus(), @v3, :time_window)
    end
  end

  describe "profiles" do
    test "Sonnet never matches an Opus entry, and Opus never matches a Sonnet entry" do
      put_entries([@opus_entry])
      assert allowlisted?(opus())
      refute allowlisted?(sonnet())

      put_entries([@sonnet_entry])
      assert allowlisted?(sonnet())
      refute allowlisted?(opus())

      # A crossed entry (Opus profile, Sonnet model) matches neither.
      put_entries([%{@opus_entry | model_id: "claude-sonnet-5-5"}])
      refute allowlisted?(opus())
      refute allowlisted?(sonnet())
    end

    test "the generation-1 entry matches only profile-nil generation-1 rows" do
      put_entries([@gen1_entry])
      assert allowlisted?(gen1())
      refute allowlisted?(opus())
      refute allowlisted?(sonnet())
      # A generation-2 row can never carry a nil profile; even so it is refused.
      refute allowlisted?(invocation(profile_id: nil))
      # A generation-1 row with a profile is not what the entry names.
      refute allowlisted?(invocation(ledger_generation: 1))
    end

    test "a profiled entry never matches a generation-1 row" do
      put_entries([@opus_entry])
      refute allowlisted?(gen1())
      refute allowlisted?(invocation(ledger_generation: 1))
    end
  end

  describe "shipped allowlist" do
    test "dev and prod ship exactly the generation-1 2.1.291 entry; no calibration stage" do
      for env <- [:dev, :prod] do
        config =
          Config.Reader.read!("config/config.exs", env: env, target: :host)
          |> Keyword.fetch!(:sdr_agent)
          |> Keyword.fetch!(Witness)

        assert Keyword.fetch!(config, :reconciled_methods) == [@gen1_entry], inspect(env)
        refute Keyword.has_key?(config, :stage), inspect(env)
        refute Keyword.has_key?(config, :calibration), inspect(env)

        for entry <- Keyword.fetch!(config, :reconciled_methods) do
          assert map_size(entry) == 6, inspect(entry)
        end
      end

      assert Keyword.get(Application.get_env(:sdr_agent, Witness, []), :reconciled_methods) == []
    end
  end

  # A missing interface fails the scenario's own assertion (RED).
  defp call(function, args) do
    Code.ensure_loaded(Witness)

    if function_exported?(Witness, function, length(args)),
      do: apply(Witness, function, args),
      else: flunk("Witness.#{function}/#{length(args)} is not implemented")
  end
end
