defmodule SdrAgent.Accounts do
  @moduledoc """
  Accounts bounded context: operator identity and authentication (S2 rows
  User, Token; ADR-0009 "Roles and actors").

  Owns `SdrAgent.Accounts.User` (password auth, roles admin / reviewer /
  auditor, status, tenant) and `SdrAgent.Accounts.Token` (AshAuthentication
  token store). Sits above Audit (User → Tenant FK) and below every other
  domain, which hold FKs to users (approver, author, owner, …).

  Public API (every write takes `actor:` and runs through
  `SdrAgent.Audit.Guard`; user creation and role/status changes are
  *guarded actions*, so every refusal of them is audited):

    * `create_user/2` (ADM), `seed_user/2` (SEED, dev/test only),
      `bootstrap_admin/2` (KRN: the first admin of a tenant with no users;
      `mix sdr.bootstrap_admin`);
    * `change_role/3`, `change_status/3` (ADM);
    * `change_password/3` (ADM, REV — own user, with the current password),
      `set_password/3` (ADM — another user, incl. auditors);
    * `sign_in/2` — password sign-in (audited success/failure; returns the
      user with a session token in `__metadata__.token`),
      `record_signed_out/1` — appends `auth.signed_out`;
    * reads: `get_user/2`, `list_users/2`.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  alias SdrAgent.Accounts.User
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel

  resources do
    resource SdrAgent.Accounts.Token
    resource SdrAgent.Accounts.User
  end

  @doc "ADM: creates an operator (`email`, `display_name`, `role`, `password`, `password_confirmation`)."
  def create_user(attrs, opts), do: GuardedCall.create(User, :create_user, attrs, guarded(opts))

  @doc """
  KRN: creates the first admin (`email`, `display_name`, `password` of at
  least 16 characters, `password_confirmation`) of the singleton tenant (or
  `tenant_id:`). The password is supplied by the operator; nothing here
  generates, prints or logs one. Works in
  every environment but only while the tenant has no users; audited as
  `user.created` by the kernel, without the password.
  """
  def bootstrap_admin(attrs, opts \\ []) do
    with {:ok, tenant_id} <- tenant(opts) do
      User
      |> Ash.Changeset.for_create(:bootstrap_admin, attrs, Kernel.opts(tenant_id))
      |> Ash.create()
    end
  end

  @doc "SEED (dev/test only): creates an operator with a fixture `id`."
  def seed_user(attrs, opts), do: GuardedCall.create(User, :seed, attrs, opts)

  @doc "ADM: changes `user`'s role; the last active admin cannot be demoted."
  def change_role(user, role, opts),
    do: GuardedCall.update(user, :change_role, %{role: role}, guarded(opts))

  @doc "ADM: enables or disables `user`; disabling revokes its sessions."
  def change_status(user, status, opts),
    do: GuardedCall.update(user, :change_status, %{status: status}, guarded(opts))

  @doc "ADM, REV: changes the actor's own password (`current_password`, `password`, `password_confirmation`)."
  def change_password(user, attrs, opts),
    do: GuardedCall.update(user, :change_password, attrs, opts)

  @doc "ADM: sets another user's password (`password`, `password_confirmation`)."
  def set_password(user, attrs, opts), do: GuardedCall.update(user, :set_password, attrs, opts)

  @doc """
  Password sign-in through the AshAuthentication strategy. Every attempt is
  audited; only active users sign in.
  """
  def sign_in(email, password) do
    User
    |> AshAuthentication.Info.strategy!(:password)
    |> AshAuthentication.Strategy.action(:sign_in, %{"email" => email, "password" => password})
  end

  @doc "Records that `user` signed out (`auth.signed_out`)."
  def record_signed_out(%User{} = user) do
    Kernel.append(
      %{
        event_type: "auth.signed_out",
        category: :auth,
        subject_resource: inspect(User),
        subject_id: user.id,
        action: "sign_out"
      },
      actor: user
    )
  end

  @doc "Reads one user visible to the actor."
  def get_user(id, opts), do: GuardedCall.get(User, id, opts)

  @doc "Lists the users visible to the actor (AUR sees others' display name and role only)."
  def list_users(opts), do: GuardedCall.list(User, opts)

  defp guarded(opts), do: Keyword.put(opts, :guarded?, true)

  defp tenant(opts) do
    case Keyword.get(opts, :tenant_id) do
      nil -> Kernel.singleton_tenant_id()
      tenant_id -> {:ok, tenant_id}
    end
  end
end
