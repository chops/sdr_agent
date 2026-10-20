defmodule SdrAgent.Repo do
  @moduledoc """
  The application's Ecto/AshPostgres repo.

  It is also the root of identity-key application scopes (ADR-0009 C3-02
  amendment item 1; plan r8 section 2.2): `prepare_transaction/2` wraps a
  transaction function opened while no transaction is open, so that it
  runs in a fresh `SdrAgent.Audit.IdentityKeys.Scope`. A transaction opened
  inside another, and any `Ecto.Multi`, is passed through unchanged (the
  nested one joins the open scope; a standalone Multi has none). `opts` are
  never changed, and a transaction that requests no key issues no extra
  statement.
  """
  use AshPostgres.Repo,
    otp_app: :sdr_agent

  alias SdrAgent.Audit.IdentityKeys.Scope

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    ["ash-functions", "citext"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def prepare_transaction(fun_or_multi, opts) when is_function(fun_or_multi) do
    if in_transaction?(), do: {fun_or_multi, opts}, else: {Scope.root(fun_or_multi), opts}
  end

  def prepare_transaction(multi, opts), do: {multi, opts}

  @impl true
  def min_pg_version do
    %Version{major: 18, minor: 2, patch: 0}
  end
end
