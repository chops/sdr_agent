defmodule SdrAgent.Sales.TimezoneValidationTest do
  @moduledoc """
  S8b tightens the S5 time zone check (S5 choice 14): a contact or campaign
  zone must exist in the time zone database (ADR-0011), not only be shaped
  like an IANA name.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  test "an IANA-shaped but unknown zone is refused; a real one is accepted" do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    account = F.account!(tenant)

    assert {:error, %Ash.Error.Invalid{}} =
             Sales.create_contact(F.contact_attrs(account, %{timezone: "America/Nowhere"}),
               actor: admin
             )

    assert {:ok, %{timezone: "America/Denver"}} =
             Sales.create_contact(F.contact_attrs(account, %{timezone: "America/Denver"}),
               actor: admin
             )
  end
end
