defmodule SdrAgent.SDR.Model do
  @moduledoc """
  The SDR agent's only path to a model: one structured call through
  `SdrAgent.AI.ModelProvider` (Fake by default; Claude CLI only when the
  caller configures it), behind a deterministic budget gate.

  Before every call a `budget_reservation` Decision (deterministic, never the
  model — spec §8) checks the run's call and token budgets and the persisted
  daily limit. When a budget is exhausted the run is moved to
  `budget_exhausted` (which opens its operator-attention Failure) and the
  call is not made; the reservation inside the provider enforces the same
  limits atomically. Invalid output fails the run with
  `invalid_model_output`, a provider error with `provider_error` — Postgres
  records the outcome; the caller receives `{:error, {:halt, reason}}`.
  """

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Prompts
  alias SdrAgent.SDR.Schemas

  @rule "sdr.budget_gate"
  @rule_version "1"

  @doc """
  Calls the model for `purpose` with structured `input`; returns
  `{:ok, output, invocation}` or `{:error, {:halt, reason}}`. `subject` is the
  record the call is about (for the budget Decision).
  """
  def call(%Context{} = ctx, purpose, input, subject_id) do
    request_id = "#{ctx.run_id}:#{purpose}:#{ctx.signal_id}"

    with {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         :ok <- budget_gate(ctx, run, request_id, subject_id) do
      ctx
      |> request(run, request_id, purpose, input)
      |> ModelProvider.complete(ctx.model)
      |> settle(ctx, run)
    end
  end

  defp request(ctx, run, request_id, purpose, input) do
    prompt = Prompts.ref(purpose)
    schema = Schemas.ref(purpose)

    %{
      id: request_id,
      run: run,
      actor: ctx.actor,
      operation: "sdr.#{purpose}",
      prompt: Prompts.render(purpose, input),
      schema: Schemas.for_purpose(purpose),
      input: input,
      audit: %{
        purpose: purpose,
        parameters: %{},
        prompt_template_id: prompt.id,
        prompt_template_version: prompt.version,
        prompt_template_sha256: prompt.sha256,
        output_schema_id: schema.id,
        output_schema_version: schema.version,
        output_schema_sha256: schema.sha256
      }
    }
  end

  defp budget_gate(ctx, run, request_id, subject_id) do
    budget = run.budget
    daily = Agents.daily_model_calls(ctx.tenant_id)
    limit = Agents.daily_model_call_limit()

    outcome =
      cond do
        budget.model_calls_reserved >= budget.max_model_calls -> "run_budget_exhausted"
        budget.tokens_used >= budget.max_tokens -> "token_budget_exhausted"
        daily >= limit -> "daily_budget_exhausted"
        true -> "within_budget"
      end

    inputs = %{
      "model_calls_reserved" => budget.model_calls_reserved,
      "max_model_calls" => budget.max_model_calls,
      "tokens_used" => budget.tokens_used,
      "max_tokens" => budget.max_tokens,
      "daily_model_calls" => daily,
      "daily_limit" => limit
    }

    with {:ok, _decision} <-
           Context.decide(
             ctx,
             %{
               kind: :budget_reservation,
               mode: :deterministic,
               rule_id: @rule,
               rule_version: @rule_version,
               subject_id: subject_id,
               inputs: inputs,
               outcome: outcome
             },
             request_id,
             [run]
           ) do
      exhaust(outcome, ctx, run)
    end
  end

  defp exhaust("within_budget", _ctx, _run), do: :ok
  defp exhaust("run_budget_exhausted", ctx, run), do: halt_budget(ctx, run, :run_budget_calls)
  defp exhaust("token_budget_exhausted", ctx, run), do: halt_budget(ctx, run, :run_budget_tokens)
  defp exhaust("daily_budget_exhausted", ctx, run), do: halt_budget(ctx, run, :daily_budget)

  defp settle({:ok, %{output: output, invocation: invocation}}, _ctx, _run),
    do: {:ok, output, invocation}

  defp settle({:error, {:budget_exhausted, :daily}}, ctx, run),
    do: halt_budget(ctx, run, :daily_budget)

  defp settle({:error, %Ash.Error.Invalid{}}, ctx, run),
    do: halt_budget(ctx, run, :run_budget_calls)

  defp settle({:error, {:validation_failed, _errors}}, ctx, run),
    do: halt_fail(ctx, run, :invalid_model_output, "model output failed schema validation")

  defp settle({:error, reason}, ctx, run),
    do: halt_fail(ctx, run, :provider_error, "model provider error: #{safe(reason)}")

  defp halt_budget(ctx, run, reason) do
    with {:ok, _run} <- Agents.exhaust_run_budget(run, %{status_reason: reason}, actor: ctx.actor) do
      {:error, {:halt, reason}}
    end
  end

  @doc "Fails the run with `reason` (opening its Failure) and returns the halt."
  def halt_fail(%Context{} = ctx, run, reason, detail) do
    run =
      case run do
        nil -> elem(Agents.get_run(ctx.run_id, actor: ctx.actor), 1)
        run -> run
      end

    with {:ok, _run} <-
           Agents.fail_run(run, %{status_reason: reason, failure_reason: detail},
             actor: ctx.actor
           ) do
      {:error, {:halt, reason}}
    end
  end

  defp safe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe(_reason), do: "redacted"
end
