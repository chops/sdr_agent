defmodule Mix.Tasks.Sdr.BootstrapAdmin do
  @shortdoc "Creates the first admin of an empty deployment (prints a one-time password)"

  @moduledoc """
  Creates the first operator (role admin) of a deployment whose tenant has
  no users yet — the S2 first-admin bootstrap, run by the audit kernel:

      mix sdr.bootstrap_admin --email admin@example.test [--display-name "Ops Admin"]
      mix sdr.bootstrap_admin --email admin@example.test --password-stdin < secret

  Bootstraps the singleton tenant first if it does not exist
  (`--tenant-slug`, default `sdr`; `--tenant-name`, default `SDR Agent`).

  Without `--password-stdin` a strong random password is generated and
  printed to this terminal exactly once; it is never logged, never written
  to an audit event and stored only as a bcrypt hash. Sign in with it and
  change it. With `--password-stdin` the password is read from the first
  line of standard input and not echoed. Refuses (exits non-zero) once the
  tenant has any user; an admin then creates users in the application.
  Runs in every environment.
  """
  use Mix.Task

  alias SdrAgent.Accounts
  alias SdrAgent.Audit

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

    Mix.Task.run("app.start")

    {password, generated?} =
      if opts[:password_stdin],
        do: {read_stdin(), false},
        else: {Accounts.generate_password(), true}

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
        if generated?, do: print_once(password)

      {:error, error} ->
        Mix.raise("First-admin bootstrap refused: #{Exception.message(error)}")
    end
  end

  defp print_once(password) do
    Mix.shell().info("""
    One-time password: #{password}
    It is shown only now and stored only as a bcrypt hash. Sign in and change it.\
    """)
  end

  defp read_stdin do
    case IO.read(:stdio, :line) do
      line when is_binary(line) -> String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
      _eof -> Mix.raise("--password-stdin: no password on standard input")
    end
  end
end
