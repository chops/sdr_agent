defmodule SdrAgent.SDR.Preconditions do
  @moduledoc """
  Fail-closed preconditions of the SDR actions that B1-04/B1-05 changed
  (plan `claude-b1-research-draft-plan-r2.md` section 3):

    * `declared/2` — the run's pinned AgentDefinition must declare the
      executing action at its current `sdr_action_version/0`. A run pinned
      to an older definition (a queued pre-v4 run, or an operator retry,
      which keeps its pin) is stopped `:crash` with the fixed reason
      `#{inspect("the run's agent definition does not declare this action version")}`
      before any settings read, model call or write: new action semantics
      never run under an old admission record;
    * `settings/1` — the run's resolved settings snapshot
      (`SdrAgent.Agents.run_settings/2`, never the current revisions). Any
      refusal stops the run `:crash` with the fixed reason
      `"run settings unavailable"`; the refusal term is never forwarded, so
      no settings text can reach a failure, log or event;
    * `brief/1`, `writing_guide/1`, `offering/1` — the settings content as
      plain atom-keyed maps for model input (no booking link: B1 Q1).

  Each stop returns `{:error, {:halt, :crash}}`, the halt every SDR action
  passes on.
  """

  alias SdrAgent.Agents
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.SDRAgent

  @undeclared "the run's agent definition does not declare this action version"
  @unavailable "run settings unavailable"

  @doc "`:ok` when the run's pinned definition declares `module` at its version; else the stop."
  @spec declared(Context.t(), module()) :: :ok | {:error, {:halt, :crash}}
  def declared(%Context{} = ctx, module) do
    with {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         {:ok, definition} <- Agents.get_definition(run.agent_definition_id, actor: ctx.actor),
         true <- SDRAgent.declares?(definition.definition, module) do
      :ok
    else
      _ -> Model.halt_fail(ctx, nil, :crash, @undeclared)
    end
  end

  @doc "The resolved settings of the run's snapshot, or the fixed stop."
  @spec settings(Context.t()) :: {:ok, map()} | {:error, {:halt, :crash}}
  def settings(%Context{} = ctx) do
    with {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         {:ok, settings} <- Agents.run_settings(run, actor: ctx.actor) do
      {:ok, settings}
    else
      _ -> unavailable(ctx)
    end
  end

  @doc "The fixed settings stop (`:crash`, `\"run settings unavailable\"`)."
  @spec unavailable(Context.t()) :: {:error, {:halt, :crash}}
  def unavailable(%Context{} = ctx), do: Model.halt_fail(ctx, nil, :crash, @unavailable)

  @doc "The research brief slot as `%{guidance, depth}`, or `:error`."
  def brief(settings) do
    case content(settings, :research_brief) do
      %{guidance: guidance, depth: depth} when is_binary(guidance) ->
        {:ok, %{guidance: guidance, depth: depth}}

      _ ->
        :error
    end
  end

  @doc "The writing guide slot as `%{text}`, or `:error`."
  def writing_guide(settings) do
    case content(settings, :writing_guide) do
      %{text: text} when is_binary(text) -> {:ok, %{text: text}}
      _ -> :error
    end
  end

  @doc "The offering profile slot as `%{name, summary, audience, items}`, or `:error`."
  def offering(settings) do
    case content(settings, :offering_profile) do
      %{name: name, summary: summary, items: items} = profile when is_list(items) ->
        {:ok,
         %{
           name: name,
           summary: summary,
           audience: Map.get(profile, :audience),
           items: Enum.map(items, &%{id: &1.id, kind: &1.kind, text: &1.text})
         }}

      _ ->
        :error
    end
  end

  defp content(settings, kind) do
    case Map.get(settings, kind) do
      %{content: content} when is_map(content) -> content
      _ -> nil
    end
  end
end
