defmodule SdrAgent.Prototype.Checks.KernelMarker do
  @moduledoc """
  Policy check for the D-237 setup-only and task-entry actions (interfaces
  r6 IF-2 phase 2, IF-3): `authorize_if {SdrAgent.Prototype.Checks.KernelMarker,
  marker: :setup | :task_entry}`.

  Contract: it passes only when the request is an audit-kernel request
  (`SdrAgent.Audit.Checks.KernelContext`: a `:kernel` actor with the private
  kernel marker) AND it carries the named prototype marker, which only
  `SdrAgent.Prototype.Authority.bootstrap/1` (`:setup`) and
  `SdrAgent.Prototype.enter_session/2` (`:task_entry`) attach (`context/1`).
  No operator, user, auditor or other actor can satisfy it. In a build
  without the prototype authority (`:prototype_authority_compiled` unset,
  the production build) it never matches and has no `context/1`.

  Stage (D-237 S1 B2a): the `:setup` positive branch is implemented. The
  `:task_entry` marker still never matches (its positive branch comes with
  `PrototypeDelegation :enter`), and neither does any other marker option.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Audit.Checks.KernelContext

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl true
  def describe(opts), do: "an audit-kernel request carrying the prototype #{opts[:marker]} marker"

  if @compiled do
    @markers %{setup: :sdr_prototype_setup, task_entry: :sdr_prototype_task_entry}

    @impl true
    def match?(actor, %{subject: %{context: context}} = authorizer, opts) when is_map(context) do
      case opts[:marker] do
        :setup ->
          KernelContext.match?(actor, authorizer, []) and
            Map.get(context, @markers.setup) == true

        _not_yet_or_unknown ->
          false
      end
    end

    def match?(_actor, _authorizer, _opts), do: false

    @doc "The context a kernel request carries for `marker` (`:setup` or `:task_entry`)."
    @spec context(:setup | :task_entry) :: map()
    def context(marker) when is_map_key(@markers, marker),
      do: Map.put(KernelContext.context(), Map.fetch!(@markers, marker), true)
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end
end
