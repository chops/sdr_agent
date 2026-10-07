defmodule Mix.Tasks.Sdr.BootstrapAdminTest do
  @moduledoc """
  `mix sdr.bootstrap_admin`: creates the first admin in any environment from
  a password read from non-echoing standard input (`--password-stdin`); it
  never generates, prints or logs a password (ADR-0001: never print, log,
  commit or transmit secret values), and refuses weak or missing passwords
  and deployments that already have users — creating nothing.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Mix.Tasks.Sdr.BootstrapAdmin
  alias SdrAgent.Accounts
  alias SdrAgent.Audit.Kernel

  @password "stdin-password-0123456789"

  defp run_task(argv, stdin) do
    parent = self()

    log =
      capture_log([level: :debug], fn ->
        stderr =
          capture_io(:stderr, fn ->
            stdout = capture_io(stdin, fn -> send(parent, {:result, run_catching(argv)}) end)
            send(parent, {:stdout, stdout})
          end)

        send(parent, {:stderr, stderr})
      end)

    assert_received {:result, result}
    assert_received {:stdout, stdout}
    assert_received {:stderr, stderr}
    %{result: result, output: stdout <> stderr <> log}
  end

  defp run_catching(argv) do
    BootstrapAdmin.run(argv)
  rescue
    error in Mix.Error -> {:raised, Exception.message(error)}
  end

  defp nothing_created do
    case Kernel.singleton_tenant_id() do
      {:error, :tenant_not_bootstrapped} ->
        true

      {:ok, tenant_id} ->
        seeder = struct(SdrAgent.Actor, type: :seeder, tenant_id: tenant_id)
        {:ok, users} = Accounts.list_users(actor: seeder)
        users == []
    end
  end

  test "creates the first admin from stdin; the password is never printed, logged or audited" do
    %{result: result, output: output} =
      run_task(
        ["--email", "ops@example.test", "--display-name", "Ops Admin", "--password-stdin"],
        @password <> "\n"
      )

    refute match?({:raised, _}, result), inspect(result)
    assert output =~ "ops@example.test"
    refute output =~ @password

    assert {:ok, admin} = Accounts.sign_in("ops@example.test", @password)
    assert {admin.role, admin.display_name} == {:admin, "Ops Admin"}

    {:ok, tenant_id} = Kernel.singleton_tenant_id()
    for event <- events(%{id: tenant_id}), do: refute(event.canonical_bytes =~ @password)
  end

  test "refuses a second bootstrap once users exist" do
    run_task(["--email", "ops@example.test", "--password-stdin"], @password <> "\n")

    %{result: result, output: output} =
      run_task(["--email", "again@example.test", "--password-stdin"], @password <> "-2\n")

    assert {:raised, message} = result
    assert message =~ "refused"
    refute output =~ @password
    assert {:error, _} = Accounts.sign_in("again@example.test", @password <> "-2")
  end

  test "without --password-stdin it refuses, explains how, and creates nothing" do
    %{result: result} = run_task(["--email", "ops@example.test"], "")

    assert {:raised, message} = result
    assert message =~ "--password-stdin"
    assert nothing_created()
  end

  test "refuses empty, whitespace-only and short passwords and creates nothing" do
    for stdin <- ["", "\n", "                    \n", "short-pass-15ch\n"] do
      %{result: result, output: output} =
        run_task(["--email", "ops@example.test", "--password-stdin"], stdin)

      assert {:raised, message} = result, inspect(stdin)
      assert message =~ "password"
      secret = String.trim(stdin)
      if secret != "", do: refute(output =~ secret)
      assert nothing_created()
    end
  end

  test "requires --email" do
    assert %{result: {:raised, message}} = run_task(["--password-stdin"], @password <> "\n")
    assert message =~ "--email"
    assert nothing_created()
  end

  test "generates no passwords" do
    refute function_exported?(Accounts, :generate_password, 0)
  end
end
