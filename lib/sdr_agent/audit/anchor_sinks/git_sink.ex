defmodule SdrAgent.Audit.AnchorSinks.GitSink do
  @moduledoc "Publishes a signed statement to the protected private anchor Git repository."
  @behaviour SdrAgent.Audit.AnchorSink

  defmodule SystemRunner do
    @moduledoc false
    def run(args) do
      {output, status} = System.cmd("git", args, stderr_to_stdout: true)
      {:ok, output, status}
    end
  end

  @impl true
  def publish(statement, opts) do
    runner = Keyword.get(opts, :runner, SystemRunner)
    repository = Keyword.fetch!(opts, :repository)
    number = Keyword.fetch!(opts, :anchor_number)
    tmp = Path.join(System.tmp_dir!(), "sdr-git-anchor-#{System.unique_integer([:positive])}")

    if runner == SystemRunner do
      publish_system(statement, repository, number, tmp)
    else
      publish_injected(statement, repository, number, tmp, runner)
    end
  end

  defp publish_injected(statement, repository, number, tmp, runner) do
    file = Path.join(tmp, "anchor.json")

    try do
      File.mkdir_p!(tmp)
      File.write!(file, statement, [:binary, :exclusive])

      with {:ok, _, 0} <- runner.run(["init", "--bare", repository]),
           {:ok, blob, 0} <- runner.run(["hash-object", "-w", file]),
           {:ok, commit, 0} <-
             runner.run(["commit-tree", String.trim(blob), "-m", "audit anchor #{number}"]),
           {:ok, _, 0} <-
             runner.run(["push", repository, String.trim(commit) <> ":refs/heads/main"]) do
        {:ok,
         %{
           status: :confirmed,
           repository: repository,
           commit_id: String.trim(commit),
           blob_id: String.trim(blob)
         }}
      else
        {:ok, _output, status} -> {:error, {:git_exit, status}}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp publish_system(statement, repository, number, tmp) do
    do_publish_system(statement, repository, number, tmp)
  after
    File.rm_rf(tmp)
  end

  defp do_publish_system(statement, repository, number, tmp) do
    with {_, 0} <- System.cmd("git", ["clone", repository, tmp], stderr_to_stdout: true),
         path = Path.join(tmp, "anchors/#{String.pad_leading(to_string(number), 12, "0")}.json"),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, statement, [:binary, :exclusive]),
         {_, 0} <-
           System.cmd("git", ["add", Path.relative_to(path, tmp)],
             cd: tmp,
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd(
             "git",
             [
               "-c",
               "user.name=sdr_agent anchorer",
               "-c",
               "user.email=sdr-agent@localhost",
               "commit",
               "-m",
               "audit anchor #{number}"
             ],
             cd: tmp,
             stderr_to_stdout: true
           ),
         {commit, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"], cd: tmp, stderr_to_stdout: true),
         {blob, 0} <- System.cmd("git", ["hash-object", path], cd: tmp, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["push", "origin", "HEAD:main"], cd: tmp, stderr_to_stdout: true) do
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
end
