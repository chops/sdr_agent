defmodule Mix.Tasks.Sdr.MacAgent do
  @moduledoc """
  Run the outbound Mac subscription-CLI worker without starting SDR or a DB.

      mix sdr.mac_agent --config /absolute/private/settings.json [--once]

  Settings must be a 0600 JSON file containing `base_url` (an HTTPS origin),
  `token` (the worker enrollment token, never a provider credential),
  `executable` (the reviewed Nix CLI path), `profile_id` and `journal_dir`
  (a private persistent directory unique to this enrollment). Never put the
  token in argv. Enrollment/deployment require their separate owner approvals.

  The task starts HTTP/TLS only, not SDR, Repo, Oban or Endpoint. While idle
  it polls every five seconds. Authorization loss stops it. Unknown launch
  outcomes are reported as status atoms; model calls are never relaunched.
  Only delivery of the same in-memory result can retry, within its deadline.
  """
  use Mix.Task

  alias SdrAgent.MacAgent.Agent
  alias SdrAgent.MacAgent.Config

  @shortdoc "Run the standalone outbound Mac worker (no SDR application boot)"

  @doc "Start only the HTTP/TLS dependency tree, never the SDR application."
  def bootstrap do
    Enum.each([:crypto, :ssl, :req], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, _} -> Mix.raise("mac agent HTTP bootstrap failed")
      end
    end)

    :ok
  end

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [config: :string, once: :boolean])

    unless rest == [] and invalid == [] and is_binary(opts[:config]) and
             length(Keyword.get_values(opts, :config)) == 1 do
      Mix.raise("invalid mac agent options")
    end

    Mix.Task.run("app.config")
    :ok = bootstrap()

    case Config.load(opts[:config]) do
      {:ok, config} -> loop(config, opts[:once] == true)
      {:error, reason} -> Mix.raise("mac agent settings refused: #{reason}")
    end
  end

  defp loop(config, once) do
    result = Agent.run_once(config)
    report(result)

    case {once, result} do
      {true, _} ->
        :ok

      {_, {:error, :unauthorized}} ->
        :ok

      {_, {:error, :unsafe_journal}} ->
        :ok

      _ ->
        Process.sleep(5_000)
        loop(config, once)
    end
  end

  defp report({:ok, status}), do: Mix.shell().info("mac agent: #{status}")
  defp report({:error, status}), do: Mix.shell().error("mac agent: #{status}")
end
