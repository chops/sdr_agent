defmodule SdrAgent.Prototype.Checks.KernelMarker do
  @moduledoc """
  Policy check for the D-237 setup-only and task-entry actions (interfaces
  r6 IF-2 phase 2, IF-3): `authorize_if {SdrAgent.Prototype.Checks.KernelMarker,
  marker: :setup | :task_entry | :relocation | :mac_worker}`.

  Contract: it passes only when the request is an audit-kernel request
  (`SdrAgent.Audit.Checks.KernelContext`: a `:kernel` actor with the private
  kernel marker) AND it carries the named prototype marker, which only
  `SdrAgent.Prototype.Authority.bootstrap/1` (`:setup`) and
  `SdrAgent.Prototype.enter_session/2` (`:task_entry`) attach, and that the
  owner-run relocation steps (`:relocation`, ADR-0024 decision 1) attach
  for the `SdrAgent.Prototype.Relocation` and
  `SdrAgent.Prototype.RelocationEvent` writes (`context/1`). No operator, user, auditor or other actor can
  satisfy it. In a build
  without the prototype authority (`:prototype_authority_compiled` unset,
  the production build) it never matches and has no `context/1`.

  Stage (D-237 S1): the `:setup` (B2a) and `:task_entry` (session) positive
  branches, S-B1's `:relocation` branch and S-B2's `:mac_worker` branch
  (the owner-run `SdrAgent.Operations.MacWorker` `:enrol`, `:disable` and
  `:set_intake`) are implemented; any other marker option never matches.
  """
  use Ash.Policy.SimpleCheck

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl true
  def describe(opts), do: "an audit-kernel request carrying the prototype #{opts[:marker]} marker"

  if @compiled do
    # Aliased inside the compiled branch only: the production branch never
    # names the kernel check (no unused alias under --warnings-as-errors).
    alias SdrAgent.Audit.Checks.KernelContext

    @markers %{
      setup: :sdr_prototype_setup,
      task_entry: :sdr_prototype_task_entry,
      relocation: :sdr_prototype_relocation,
      mac_worker: :sdr_prototype_mac_worker
    }

    @impl true
    def match?(actor, %{subject: %{context: context}} = authorizer, opts) when is_map(context) do
      case opts[:marker] do
        marker when is_map_key(@markers, marker) ->
          KernelContext.match?(actor, authorizer, []) and
            Map.get(context, Map.fetch!(@markers, marker)) == true

        _unknown ->
          false
      end
    end

    def match?(_actor, _authorizer, _opts), do: false

    @doc "The context a kernel request carries for `marker` (`:setup`, `:task_entry`, `:relocation` or `:mac_worker`)."
    @spec context(:setup | :task_entry | :relocation | :mac_worker) :: map()
    def context(marker) when is_map_key(@markers, marker),
      do: Map.put(KernelContext.context(), Map.fetch!(@markers, marker), true)
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end
end
