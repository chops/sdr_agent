defmodule Mix.Tasks.Sdr.Demo.Predeliver do
  @shortdoc "Runs demo lead 01 to a draft, or with --approve to a captured email (dev/test)"

  @moduledoc """
  Runs `SdrAgent.Demo.Predeliver` for `bin/demo predeliver`:

      mix sdr.demo.predeliver [--approve]

  Without `--approve`, fixture lead 01 is assigned, researched, qualified and
  drafted; the draft waits for review in the console. With `--approve`, the
  draft is approved **as the Demo Reviewer fixture operator** (recorded in
  the audit trail as that operator's approval, bound to the displayed
  recipient) and delivered to the local capture adapter — unless the send
  gate defers it (quiet hours 18:00–08:00 America/Denver).

  The application starts with Oban's queues and plugins off; the task runs
  the research and delivery jobs inline and, if a dev server is running and
  takes a job first, waits (bounded) for its outcome. Refuses outside
  `MIX_ENV=dev` or `test`. Prints ids and states only.
  """
  use Mix.Task

  alias SdrAgent.Demo.Predeliver

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [approve: :boolean])
    invalid == [] || Mix.raise("usage: mix sdr.demo.predeliver [--approve]")

    unless Mix.Tasks.Sdr.Demo.Seed.allowed_env?(Mix.env()) do
      Mix.raise("mix sdr.demo.predeliver runs only in dev and test (MIX_ENV=#{Mix.env()})")
    end

    Mix.Task.run("app.config")
    oban = Application.get_env(:sdr_agent, Oban, [])
    Application.put_env(:sdr_agent, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Mix.Task.run("app.start")

    case Predeliver.run(approve: Keyword.get(opts, :approve, false)) do
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
    do: "awaiting review (approve in the console, or re-run with --approve)"

  defp describe(:captured, delivery),
    do: "captured (delivery #{delivery.id}, #{delivery.state}); open the draft → Captured message"

  defp describe(:deferred, delivery),
    do:
      "deferred by the send gate (quiet hours) until #{DateTime.to_iso8601(delivery.not_before)}"

  defp describe(:queued, delivery), do: "queued (delivery #{delivery.id}, #{delivery.state})"
  defp describe(other, _), do: inspect(other)
end
