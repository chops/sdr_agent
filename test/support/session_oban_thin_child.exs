defmodule SdrAgent.SessionObanThinProof do
  @moduledoc """
  Fixed-source child proof of prototype Session's insert-only Oban start in
  a cold Mix VM (D-268 M7 R1): Mix has loaded test configuration but has
  not started the product app or `:oban`. The Oban options are the loaded
  ones without the test-only `:testing` key, as a dev terminal sees them.
  It inserts no job. No raw result, exception, target or process
  identifier is presented.
  """

  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.Prototype.Session
  alias SdrAgent.Prototype.SessionRepoStart
  alias SdrAgent.Repo

  @db ~r/\Asdr_agent_test(?:_c[1-9])?\z/

  @doc "Returns only a closed proof stage; arguments are target identity, not code."
  def run([database, port]) do
    with :ok <- target(database, port),
         :ok <- before_start(),
         :ok <- attach(),
         :ok <- repo(),
         :ok <- start(),
         :ok <- insert_only() do
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

  defp before_start do
    valid? =
      not List.keymember?(Application.started_applications(), :oban, 0) and
        Process.whereis(Oban.Registry) == nil and Process.whereis(Repo) == nil

    if valid?, do: :ok, else: :precondition
  end

  defp attach do
    if SafeLog.attach(file: nil) == :ok, do: :ok, else: :attach
  end

  defp repo do
    :ok = SessionRepoStart.start!()
    config = Keyword.delete(Application.fetch_env!(:sdr_agent, Oban), :testing)
    :ok = Application.put_env(:sdr_agent, Oban, config)
    :ok
  end

  defp start do
    Session.start_insert_only_oban()
  rescue
    Session.ObanStartError -> :oban
  end

  # The instance runs, with no producer, plugin or stager registered.
  defp insert_only do
    roles =
      Registry.select(Oban.Registry, [{{{Oban, :"$1"}, :_, :_}, [], [:"$1"]}])

    valid? =
      is_pid(Oban.whereis(Oban)) and
        not Enum.any?(roles, fn
          {:producer, _queue} -> true
          {:plugin, _plugin} -> true
          Oban.Stager -> true
          _role -> false
        end)

    if valid?, do: :ok, else: :roles
  end

  defp no_product_tree do
    names = [SdrAgent.Supervisor, SdrAgentWeb.Endpoint, SdrAgent.AI.ModelProvider.ClaudeCLI]

    valid? =
      not List.keymember?(Application.started_applications(), :sdr_agent, 0) and
        Enum.all?(names, &(Process.whereis(&1) == nil))

    if valid?, do: :ok, else: :tree
  end
end

stage = SdrAgent.SessionObanThinProof.run(System.argv())
IO.puts("SESSION_OBAN:#{stage}")
System.halt(if(stage == :ok, do: 0, else: 1))
