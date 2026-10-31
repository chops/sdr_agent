defmodule SdrAgent.Audit.HumanMetadataAuthorityTest do
  @moduledoc """
  M1 R1 RED: lower metadata policies must consume the lower-owned interface.
  Resource reads prove owner/legacy controls and revoked/unavailable refusal.
  A temporary compiled deny provider is restored byte-for-byte in `after`;
  no runtime configuration can replace production's compiled provider.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts.User
  alias SdrAgent.Audit.HumanAuthority
  alias SdrAgent.Audit.ProvenanceSnapshot
  alias SdrAgent.Audit.Tenant
  alias SdrAgent.HostedOwnerFixtures, as: H

  @ordinary SdrAgent.Audit.HumanAuthority.Ordinary
  @unavailable SdrAgent.Audit.HumanAuthority.Unavailable

  test "both new callbacks preserve ordinary User reads and unavailable refusal" do
    user = %User{}
    assert call(@ordinary, :human_read?, [user])
    refute call(@ordinary, :human_read?, [%{role: :reviewer}])
    refute call(@ordinary, :hosted_owner?, [user])
    refute call(@unavailable, :human_read?, [user])
    refute call(@unavailable, :hosted_owner?, [user])
  end

  test "all Audit source names only lower-owned human policy checks" do
    for path <- Path.wildcard("lib/sdr_agent/audit/**/*.ex") do
      source = File.read!(path)
      refute source =~ "SdrAgent.Operations", path
      refute source =~ "SdrAgent.Prototype.Checks", path
    end
  end

  test "actual nonempty metadata reads retain fresh owner and legacy nonowner behavior" do
    ctx = H.activated!()
    legacy = human(:reviewer, ctx.fx.tenant)
    enrolled = H.enrol!(ctx)
    H.enter!(ctx)
    assert function_exported?(HumanAuthority, :human_read?, 1), "missing lower human_read?/1"

    for resource <- [Tenant, ProvenanceSnapshot], actor <- [enrolled.user, legacy] do
      assert {:ok, [_ | _]} = Ash.read(resource, actor: actor)
    end

    assert {:ok, _} = H.disable(ctx, enrolled.owner.id, actor: enrolled.user)

    for resource <- [Tenant, ProvenanceSnapshot] do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(resource, actor: enrolled.user)
      assert {:ok, [_ | _]} = Ash.read(resource, actor: legacy)
    end
  end

  test "an unavailable compiled provider denies actual Tenant and Provenance reads" do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    H.enter!(ctx)
    assert function_exported?(HumanAuthority, :human_read?, 1), "missing lower human_read?/1"
    assert {:ok, [_ | _]} = Ash.read(Tenant, actor: enrolled.user)
    {HumanAuthority, original, filename} = :code.get_object_code(HumanAuthority)
    compiler_options = Code.compiler_options()

    try do
      Code.compiler_options(ignore_module_conflict: true)

      Code.compile_quoted(
        quote do
          defmodule SdrAgent.Audit.HumanAuthority do
            @moduledoc false
            def role_allowed?(actor),
              do: SdrAgent.Audit.HumanAuthority.Unavailable.role_allowed?(actor)

            def valid_write_scope?(actor, subject),
              do: SdrAgent.Audit.HumanAuthority.Unavailable.valid_write_scope?(actor, subject)

            def human_read?(actor),
              do: SdrAgent.Audit.HumanAuthority.Unavailable.human_read?(actor)

            def hosted_owner?(actor),
              do: SdrAgent.Audit.HumanAuthority.Unavailable.hosted_owner?(actor)
          end
        end
      )

      for resource <- [Tenant, ProvenanceSnapshot] do
        assert {:error, %Ash.Error.Forbidden{}} = Ash.read(resource, actor: enrolled.user)
      end
    after
      assert {:module, HumanAuthority} = :code.load_binary(HumanAuthority, filename, original)
      Code.compiler_options(Map.to_list(compiler_options))
    end

    assert {:ok, [_ | _]} = Ash.read(Tenant, actor: enrolled.user)
  end
end
