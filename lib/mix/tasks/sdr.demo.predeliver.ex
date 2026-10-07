defmodule Mix.Tasks.Sdr.Demo.Predeliver do
  @shortdoc "Runs demo lead 01 to a draft awaiting human review (dev/test)"

  @moduledoc """
  Runs `SdrAgent.Demo.Predeliver` for `bin/demo predeliver`:

      mix sdr.demo.predeliver

  Fixture lead 01 is assigned, researched, qualified and drafted; the draft
  waits for a human approval in the console (the task never approves —
  ADR-0001 Tier 0). Prints the lead and draft paths and the current stage
  (after a human approval: queued, deferred by quiet hours, or captured).

  The application starts with Oban's queues and plugins off; the research
  job runs inline and, if a dev server is running and takes it first, the
  task waits (bounded) for its outcome. Refuses outside `MIX_ENV=dev` or
  `test`, and refuses any option. Prints ids and states only.
  """
  use Mix.Task

  alias SdrAgent.Demo.Predeliver

  @doc false
  @impl Mix.Task
  def run(args) do
    args == [] || Mix.raise("usage: mix sdr.demo.predeliver (it takes no options)")

    unless Mix.Tasks.Sdr.Demo.Seed.allowed_env?(Mix.env()) do
      Mix.raise("mix sdr.demo.predeliver runs only in dev and test (MIX_ENV=#{Mix.env()})")
    end

    Mix.Task.run("app.config")
    oban = Application.get_env(:sdr_agent, Oban, [])
    Application.put_env(:sdr_agent, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Mix.Task.run("app.start")

    case Predeliver.run() do
      {:ok, result} -> Enum.each(lines(result), fn line -> Mix.shell().info(line) end)
      {:error, reason} -> Mix.raise("predeliver stopped: #{inspect(reason)}")
    end
  end

  defp lines(%{stage: stage, lead_id: lead_id, draft_id: draft_id, delivery: delivery}) do
    [
      "lead 01: /leads/#{lead_id}",
      "draft: /drafts/#{draft_id}",
      "stage: #{describe(stage, delivery)}"
    ]
  end

  defp describe(:awaiting_review, _),
    do: "awaiting review (approve it in the console as a reviewer)"

  defp describe(:captured, delivery),
    do: "captured (delivery #{delivery.id}, #{delivery.state}); open the draft → Captured message"

  defp describe(:deferred, delivery),
    do:
      "deferred by the send gate (quiet hours) until #{DateTime.to_iso8601(delivery.not_before)}"

  defp describe(:queued, delivery), do: "queued (delivery #{delivery.id}, #{delivery.state})"
  defp describe(other, _), do: inspect(other)
end
