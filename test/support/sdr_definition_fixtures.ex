defmodule SdrAgent.SDRDefinitionFixtures do
  @moduledoc """
  The frozen `SDRAgent` v3 AgentDefinition body for the B1 definition
  upgrade tests (plan `claude-b1-research-draft-plan-r2.md`, Codex r1 M1).

  `test/fixtures/sdr_agent/sdr_agent_definition_v3.json` is the canonical
  body `SdrAgent.SDR.SDRAgent.definition_body/0` produced at base
  `4343dbef` (version 3), as a used database holds it; `v3_body/0` checks
  it against its pinned `Canonical.sha256` before returning it, so the
  fixture cannot drift. `register_v3!/1` registers it through the domain
  API as the kernel, exactly as `SDRAgent.register/1` did before the
  upgrade.

  B1-R1 forward version (`claude-b1-r1-version-route-r1.md`): v4 is frozen
  the same way. `test/fixtures/sdr_agent/sdr_agent_definition_v4.json` is
  the canonical body `definition_body/0` produced at PR #234's GREEN
  `5e4c82da` (version 4; `lib/`, `priv/` and `config/` unchanged through
  `2cf691fb`, where it was generated), as a store that registered v4 would
  hold it; `v4_body/0` checks its pinned hash and `register_v4!/1`
  registers it. Neither fixture is ever rewritten.
  """

  import ExUnit.Assertions

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit.Canonical

  @path Path.expand("../fixtures/sdr_agent/sdr_agent_definition_v3.json", __DIR__)
  @external_resource @path
  @v3_sha256 "f490cb2e012c2cbc2fbe4ea9a6620d71cf3b9317b1f697201f2f2d2ef048bdeb"
  @v4_path Path.expand("../fixtures/sdr_agent/sdr_agent_definition_v4.json", __DIR__)
  @external_resource @v4_path
  @v4_sha256 "98296763f635f9fb93b37809ca87e4bb7355a6450a5fcc8a55a8ab1c89acf255"

  @doc "The frozen v3 body, verified against its pinned hash."
  def v3_body do
    body = @path |> File.read!() |> JSON.decode!()

    assert body |> Canonical.sha256() |> Base.encode16(case: :lower) == @v3_sha256,
           "the frozen SDRAgent v3 body drifted from its pinned hash"

    body
  end

  @doc "The pinned lowercase-hex `Canonical.sha256` of the v3 body."
  def v3_sha256, do: @v3_sha256

  @doc "Registers the frozen v3 body as `SDRAgent` version 3 for `tenant_id` (KRN)."
  def register_v3!(tenant_id) do
    result =
      Agents.register_definition(
        %{
          name: "SDRAgent",
          version: 3,
          module: "SdrAgent.SDR.SDRAgent",
          definition: v3_body()
        },
        actor: Actor.system(:kernel, tenant_id)
      )

    assert match?({:ok, %{version: 3}}, result),
           "setup: registering the frozen SDRAgent v3 body failed: " <>
             inspect(result, limit: 8, printable_limit: 200)

    {:ok, definition} = result
    definition
  end

  @doc "The frozen v4 body (PR #234 GREEN `5e4c82da`), verified against its pinned hash."
  def v4_body do
    body = @v4_path |> File.read!() |> JSON.decode!()

    assert body |> Canonical.sha256() |> Base.encode16(case: :lower) == @v4_sha256,
           "the frozen SDRAgent v4 body drifted from its pinned hash"

    body
  end

  @doc "The pinned lowercase-hex `Canonical.sha256` of the v4 body."
  def v4_sha256, do: @v4_sha256

  @doc "Registers the frozen v4 body as `SDRAgent` version 4 for `tenant_id` (KRN)."
  def register_v4!(tenant_id) do
    result =
      Agents.register_definition(
        %{
          name: "SDRAgent",
          version: 4,
          module: "SdrAgent.SDR.SDRAgent",
          definition: v4_body()
        },
        actor: Actor.system(:kernel, tenant_id)
      )

    assert match?({:ok, %{version: 4}}, result),
           "setup: registering the frozen SDRAgent v4 body failed: " <>
             inspect(result, limit: 8, printable_limit: 200)

    {:ok, definition} = result
    definition
  end

  @doc "The declared version of action `module` (a string) in a definition body, or nil."
  def action_version(body, module) do
    Enum.find_value(body["allowed_actions"], fn
      %{"module" => ^module, "version" => version} -> version
      _other -> nil
    end)
  end

  @doc "The prompt or schema ref of `purpose` in a body section (`\"prompt_templates\"`, ...)."
  def ref(body, section, purpose) do
    id = "sdr.#{purpose}"
    Enum.find(body[section], &(&1["id"] == id))
  end
end
