defmodule SdrAgent.SessionStartupThinProof do
  @moduledoc """
  Fixed-source child proof of prototype Session's actual absent-Repo path.
  Mix has loaded test configuration but has not started the product app.
  No raw result, exception, target or process identifier is presented.
  """

  alias SdrAgent.Prototype.RepoState
  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.Prototype.Session
  alias SdrAgent.Repo

  @db ~r/\Asdr_agent_test(?:_c[1-9])?\z/

  @doc "Returns only a closed proof stage; arguments are target identity, not code."
  def run([database, port]) do
    with :ok <- target(database, port),
         :ok <- before_entry(),
         :ok <- attach(),
         :ok <- enter(),
         :ok <- after_entry() do
      no_product_tree()
    end
  catch
    _kind, _reason -> :failed
  end

  def run(_args), do: :scope

  defp target(database, port) do
    config = Application.get_env(:sdr_agent, Repo, [])

    valid? =
      Regex.match?(@db, database) and Keyword.get(config, :database) == database and
        Integer.to_string(Keyword.get(config, :port, 0)) == port and
        Keyword.get(config, :hostname) in ["localhost", "127.0.0.1"] and
        Keyword.get(config, :socket_dir) == nil

    if valid?, do: :ok, else: :scope
  end

  defp before_entry do
    valid? =
      not List.keymember?(Application.started_applications(), :ecto, 0) and
        Process.whereis(Repo) == nil and RepoState.repo_state() == :not_started

    if valid?, do: :ok, else: :precondition
  end

  defp attach do
    if SafeLog.attach(file: nil) == :ok, do: :ok, else: :attach
  end

  defp enter do
    result = Session.enter(agent: "codex_cli", session_correlation: "thin-first-start-0001")
    if result == {:error, :not_prototype_runtime}, do: :ok, else: :entry
  end

  defp after_entry do
    case Process.whereis(Repo) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) and parent?(pid) and RepoState.repo_state() == {:started, false},
          do: :ok,
          else: :parent

      _absent ->
        :parent
    end
  end

  defp parent?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> first_parent?(Keyword.get(dictionary, :"$ancestors", []))
      _unavailable -> false
    end
  end

  defp first_parent?([parent | _]) when is_pid(parent), do: parent == self()
  defp first_parent?([parent | _]) when is_atom(parent), do: Process.whereis(parent) == self()
  defp first_parent?(_other), do: false

  defp no_product_tree do
    names = [SdrAgent.Supervisor, SdrAgentWeb.Endpoint, SdrAgent.AI.ModelProvider.ClaudeCLI]

    valid? =
      not List.keymember?(Application.started_applications(), :sdr_agent, 0) and
        Enum.all?(names, &(Process.whereis(&1) == nil))

    if valid?, do: :ok, else: :tree
  end
end

stage = SdrAgent.SessionStartupThinProof.run(System.argv())
IO.puts("SESSION_THIN:#{stage}")
System.halt(if(stage == :ok, do: 0, else: 1))
