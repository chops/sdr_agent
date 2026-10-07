defmodule Mix.Tasks.Sdr.BootstrapAdminTest do
  @moduledoc """
  `mix sdr.bootstrap_admin`: creates the first admin in any environment,
  prints a generated one-time password exactly once (or reads one from
  stdin), and refuses when users already exist.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Mix.Tasks.Sdr.BootstrapAdmin
  alias SdrAgent.Accounts
  alias SdrAgent.Audit.Kernel

  defp tenant do
    {:ok, id} = Kernel.singleton_tenant_id()
    %{id: id}
  end

  test "bootstraps the tenant and the first admin and prints a generated password once" do
    log =
      capture_log(fn ->
        send(
          self(),
          {:out,
           capture_io(fn ->
             BootstrapAdmin.run(["--email", "ops@example.test", "--display-name", "Ops Admin"])
           end)}
        )
      end)

    assert_received {:out, out}
    assert [_, password] = Regex.run(~r/One-time password: (\S+)/, out)
    assert length(String.split(out, password)) == 2, "the password is printed exactly once"
    assert String.length(password) >= 32
    refute log =~ password

    assert {:ok, admin} = Accounts.sign_in("ops@example.test", password)
    assert admin.role == :admin
    assert admin.display_name == "Ops Admin"
    for event <- events(tenant()), do: refute(event.canonical_bytes =~ password)

    assert_raise Mix.Error, ~r/refused/, fn ->
      capture_io(fn -> BootstrapAdmin.run(["--email", "again@example.test"]) end)
    end
  end

  test "reads the password from stdin with --password-stdin and does not echo it" do
    password = "stdin-password-0123456789"

    out =
      capture_io(password <> "\n", fn ->
        BootstrapAdmin.run(["--email", "ops@example.test", "--password-stdin"])
      end)

    refute out =~ password
    assert {:ok, _} = Accounts.sign_in("ops@example.test", password)
  end

  test "requires --email" do
    assert_raise Mix.Error, ~r/--email/, fn -> capture_io(fn -> BootstrapAdmin.run([]) end) end
  end
end
