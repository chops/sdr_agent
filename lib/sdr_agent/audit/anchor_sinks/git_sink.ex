defmodule SdrAgent.Audit.AnchorSinks.GitSink do
  @moduledoc "Publishes a signed statement to the protected private anchor Git repository."
  @behaviour SdrAgent.Audit.AnchorSink

  alias SdrAgent.ChildEnv

  @repository "git@github.com:chops/sdr_agent-audit-anchors.git"
  # SSH agent/command and TLS roots for the push; nothing else of the
  # parent environment (SdrAgent.ChildEnv).
  @git_allow ~w(SSH_AUTH_SOCK SSH_AGENT_PID GIT_SSH GIT_SSH_COMMAND SSL_CERT_FILE NIX_SSL_CERT_FILE)
  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_TERMINAL_PROMPT", "0"}
  ]

  @impl true
  def publish(statement, opts) do
    command = Keyword.get(opts, :command, &ChildEnv.system_cmd/3)
    repository = Keyword.fetch!(opts, :repository)
    allowed_repository = Keyword.get(opts, :allowed_repository, @repository)
    number = Keyword.fetch!(opts, :anchor_number)
    tmp = Path.join(System.tmp_dir!(), "sdr-git-anchor-#{System.unique_integer([:positive])}")

    if repository != allowed_repository do
      {:error, :repository_not_allowed}
    else
      publish_system(statement, repository, number, tmp, command)
    end
  end

  defp publish_system(statement, repository, number, tmp, command) do
    do_publish_system(statement, repository, number, tmp, command)
  after
    File.rm_rf(tmp)
  end

  defp do_publish_system(statement, repository, number, tmp, command) do
    with {_, 0} <- git(["clone", "--", repository, tmp], [], command),
         path = Path.join(tmp, "anchors/#{String.pad_leading(to_string(number), 12, "0")}.json"),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, created?} <- write_statement(path, statement),
         :ok <- commit_statement(created?, path, number, tmp, command),
         {commit, 0} <-
           git(
             ["log", "-1", "--format=%H", "--", Path.relative_to(path, tmp)],
             [cd: tmp],
             command
           ),
         {blob, 0} <- git(["hash-object", path], [cd: tmp], command),
         {_, 0} <- git(["push", "origin", "HEAD:main"], [cd: tmp], command) do
      {:ok,
       %{
         status: :confirmed,
         repository: repository,
         commit_id: String.trim(commit),
         blob_id: String.trim(blob)
       }}
    else
      {_output, status} when is_integer(status) -> {:error, {:git_exit, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_statement(path, statement) do
    case File.read(path) do
      {:ok, ^statement} ->
        {:ok, false}

      {:ok, _different} ->
        {:error, :conflicting_anchor}

      {:error, :enoent} ->
        with :ok <- File.write(path, statement, [:binary, :exclusive]), do: {:ok, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_statement(false, _path, _number, _tmp, _command), do: :ok

  defp commit_statement(true, path, number, tmp, command) do
    with {_, 0} <-
           git(["add", "--", Path.relative_to(path, tmp)], [cd: tmp], command),
         {_, 0} <-
           git(
             [
               "-c",
               "user.name=sdr_agent anchorer",
               "-c",
               "user.email=sdr-agent@localhost",
               "-c",
               "commit.gpgsign=false",
               "-c",
               "core.hooksPath=/dev/null",
               "commit",
               "-m",
               "audit anchor #{number}"
             ],
             [cd: tmp],
             command
           ) do
      :ok
    else
      {_output, status} when is_integer(status) -> {:error, {:git_exit, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(args, opts, command) do
    # Only an explicit allowlist reaches Git (no anchor signing key or other
    # secret; SdrAgent.ChildEnv). Hooks export local Git variables; none may
    # escape into the scratch clone either.
    {names, 0} =
      System.cmd("git", ["rev-parse", "--local-env-vars"], env: ChildEnv.cmd(@git_allow))

    clean_env = names |> String.split("\n", trim: true) |> Enum.map(&{&1, nil})

    command.(
      "git",
      args,
      Keyword.merge(
        [stderr_to_stdout: true, env: clean_env ++ ChildEnv.cmd(@git_allow, @git_env)],
        opts
      )
    )
  end
end
