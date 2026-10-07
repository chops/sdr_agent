defmodule Mix.Tasks.Sdr.BootstrapAdmin do
  @shortdoc "Creates the first admin of an empty deployment (password on stdin)"

  @moduledoc """
  Creates the first operator (role admin) of a deployment whose tenant has
  no users yet — the S2 first-admin bootstrap, run by the audit kernel. The
  password is read from the first line of standard input, which must be
  supplied without echoing it, e.g.:

      read -rs ADMIN_PASSWORD
      printf '%s\\n' "$ADMIN_PASSWORD" | \\
        mix sdr.bootstrap_admin --email admin@example.test --display-name "Ops Admin" --password-stdin
      unset ADMIN_PASSWORD

  `--password-stdin` is required: the task never generates, prints or logs a
  password (ADR-0001: never print, log, commit or transmit secret values),
  and the password is stored only as a bcrypt hash. It must have at least 16
  characters; empty and whitespace-only input is refused.

  Bootstraps the singleton tenant first if it does not exist
  (`--tenant-slug`, default `sdr`; `--tenant-name`, default `SDR Agent`).
  Every refusal — missing option, weak password, or a tenant that already
  has users — exits non-zero before anything is created. Runs in every
  environment; further users are created by an admin in the application.
  """
  use Mix.Task

  alias SdrAgent.Accounts
  alias SdrAgent.Audit

  @min_length 16
  @switches [
    email: :string,
    display_name: :string,
    password_stdin: :boolean,
    tenant_slug: :string,
    tenant_name: :string
  ]

  @doc false
  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [],
      do: Mix.raise("unknown options: #{inspect(Enum.map(invalid, &elem(&1, 0)))}")

    email = opts[:email] || Mix.raise("--email is required")

    unless opts[:password_stdin] do
      Mix.raise(
        "--password-stdin is required: pipe the first admin's password (at least " <>
          "#{@min_length} characters) on standard input without echoing it, e.g. " <>
          "`read -rs PW; printf '%s\\n' \"$PW\" | mix sdr.bootstrap_admin --email … --password-stdin`"
      )
    end

    password = read_password()

    Mix.Task.run("app.start")

    {:ok, _tenant} =
      Audit.bootstrap(
        slug: Keyword.get(opts, :tenant_slug, "sdr"),
        name: Keyword.get(opts, :tenant_name, "SDR Agent")
      )

    attrs = %{
      email: email,
      display_name: Keyword.get(opts, :display_name, "Administrator"),
      password: password,
      password_confirmation: password
    }

    case Accounts.bootstrap_admin(attrs) do
      {:ok, admin} ->
        Mix.shell().info("Created the first admin #{email} (#{admin.id}).")

      {:error, error} ->
        Mix.raise("First-admin bootstrap refused: #{Exception.message(error)}")
    end
  end

  # Reads one line; the password itself never appears in any message.
  defp read_password do
    line =
      case IO.read(:stdio, :line) do
        line when is_binary(line) ->
          line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

        _eof ->
          ""
      end

    cond do
      String.trim(line) == "" ->
        Mix.raise("refused: the password on standard input is empty")

      String.length(line) < @min_length ->
        Mix.raise("refused: the password must have at least #{@min_length} characters")

      true ->
        line
    end
  end
end
