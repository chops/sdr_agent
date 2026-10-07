defmodule Mix.Tasks.Sdr.Audit.Verify do
  @moduledoc "Verifies a signed S11 audit export bundle without requiring application secrets."
  @shortdoc "Verify a signed SDR audit export bundle"
  use Mix.Task

  @impl Mix.Task
  def run([path]) do
    case SdrAgent.Audit.ExportVerifier.verify(path) do
      {:ok, report} ->
        Mix.shell().info(
          "valid assurance=#{report.assurance_level} events=#{report.events_checked}"
        )

      {:error, reason} ->
        Mix.raise("verification failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix sdr.audit.verify PATH")
end
