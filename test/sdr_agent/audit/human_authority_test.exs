defmodule SdrAgent.Audit.HumanAuthorityTest do
  @moduledoc """
  S-B5 M1 dependency-inversion RED. The lowest domain owns the policy
  interface; build configuration, never request/runtime input, selects its
  implementation. Existing prototype identity/write-scope tests remain the
  behavioral controls for the Operations implementation.
  """
  use SdrAgent.PrototypeCase, async: false

  @authority SdrAgent.Audit.HumanAuthority
  @ordinary SdrAgent.Audit.HumanAuthority.Ordinary
  @unavailable SdrAgent.Audit.HumanAuthority.Unavailable

  defmodule RuntimeReplacement do
    @moduledoc "Runtime configuration replacement that must never be called."
    def role_allowed?(_actor), do: false
    def valid_write_scope?(_actor, _subject), do: true
  end

  test "the lower authority interface exposes only its two narrow checks" do
    loaded!(@authority)
    assert function_exported?(@authority, :role_allowed?, 1)
    assert function_exported?(@authority, :valid_write_scope?, 2)
    refute function_exported?(@authority, :with_scope, 1)
  end

  test "ordinary role semantics remain while scoped hosted User writes stay closed" do
    for role <- [:admin, :reviewer, :auditor] do
      assert call(@ordinary, :role_allowed?, [%{role: role}])
    end

    refute call(@ordinary, :role_allowed?, [%{role: nil}])
    refute call(@ordinary, :role_allowed?, [nil])
    refute call(@ordinary, :valid_write_scope?, [%{role: :admin}, %{context: %{}}])
  end

  test "an unavailable prototype provider grants neither roles nor scoped writes" do
    for actor <- [%{role: :admin}, %{role: :reviewer}, nil] do
      refute call(@unavailable, :role_allowed?, [actor])
      refute call(@unavailable, :valid_write_scope?, [actor, %{context: %{}}])
    end
  end

  test "runtime configuration cannot replace the compiled provider or manufacture a write scope" do
    loaded!(@authority)
    previous = Application.fetch_env(:sdr_agent, :human_authority_provider)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :human_authority_provider, value)
        :error -> Application.delete_env(:sdr_agent, :human_authority_provider)
      end
    end)

    assert call(@authority, :role_allowed?, [%{role: :reviewer}])
    Application.put_env(:sdr_agent, :human_authority_provider, RuntimeReplacement)
    assert call(@authority, :role_allowed?, [%{role: :reviewer}])
    refute call(@authority, :valid_write_scope?, [%{role: :reviewer}, %{context: %{}}])
  end

  test "ActorRole and Accounts.User do not name the upper owner persistence implementation" do
    role_source = File.read!("lib/sdr_agent/audit/checks/actor_role.ex")
    user_source = File.read!("lib/sdr_agent/accounts/user.ex")
    refute role_source =~ "SdrAgent.Operations"
    refute role_source =~ "SdrAgent.Prototype"
    refute user_source =~ "SdrAgent.Operations"
    assert role_source =~ "HumanAuthority"
    assert user_source =~ "HostedOwnerWriteScope"
  end
end
