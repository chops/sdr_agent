defmodule SdrAgent.Prototype.ProvisionC2Test do
  @moduledoc """
  The C2 closure cases of D-237 provisioning (Codex a6850b13, D1-D3), over
  the real `bind/1` and owned scratch roots:

  - an identical replay with the evidence files removed returns the same
    grant and writes no grant, event or allocation (IF-2: replay needs no
    new worksheet);
  - a different worksheet, and an identical replay of a revoked grant,
    refuse `:grant_exists` and write nothing;
  - a direct `ModelCallGrant :provision_prototype` action with no worksheet,
    a worksheet that fails the check, or caller-supplied server metadata is
    refused and writes nothing (the action carries its own validation);
  - an ordinary grant named `d237-funding/1` is a conflict: provisioning
    refuses `:grant_exists`, and the operator cannot revoke it;
  - this binding's grant is found by its ORIGINAL provisioned-event
    provenance, not its mutable name (Codex 2c5af8ae must-fix 2): after an
    ordinary rename or terms change no second grant is minted (`:grant_exists`),
    and an identical replay by a later session of the same binding (another
    valid delegation) returns the original grant.

  Each direct-action test ends with the valid direct action (a positive
  control), so its negatives count only when the subject is reachable.
  Evidence file names use a safe token of `as_of` (IF-2 path grammar
  `^[A-Za-z0-9._/-]{1,200}$`, checked at construction); the worksheet keeps
  the original RFC 3339 `as_of`.

  The concurrent first-provision proof needs two real connections and is an
  `:external` harness case (closure note), not a sandbox test. Synthetic
  `.test` data only; the only files removed are this test's own.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Prototype

  @routes ~w(prototype_binding owner_dev owner_calibration hosted other_owner)
  @path_grammar ~r/\A[A-Za-z0-9._\/-]{1,200}\z/

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # A deterministic file-name token of `as_of`: every character outside the
  # IF-2 path grammar becomes "-". The worksheet keeps the original value.
  defp token(as_of), do: Regex.replace(~r/[^A-Za-z0-9.-]/, as_of, "-")

  defp evidence!(root, name) do
    assert Regex.match?(@path_grammar, name),
           "fixture: evidence path #{inspect(name)} is outside the IF-2 grammar"

    body = "counts-only receipt #{name}\n"
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o600)
    %{"path" => name, "sha256" => sha(body)}
  end

  defp worksheet_bytes(root, as_of \\ "2026-10-29T12:00:00Z") do
    routes =
      for route <- @routes do
        %{
          "route" => route,
          "basis" =>
            if(route == "prototype_binding", do: "agent_receipt", else: "owner_attestation"),
          "consumed" => 0,
          "evidence" => evidence!(root, "#{route}-#{token(as_of)}.receipt")
        }
      end

    Jason.encode!(%{
      "schema" => "d237-budget-worksheet/1",
      "shared_total" => 60,
      "window_starts_at" => "2026-10-28T02:38:32.000000Z",
      "as_of" => as_of,
      "routes" => routes,
      "previous_bindings" => %{
        "consumed" => 0,
        "evidence" => evidence!(root, "previous-#{token(as_of)}.receipt")
      }
    })
  end

  defp provision(actor, bytes, root) do
    Agents.provision_prototype_grant(%{worksheet: bytes, worksheet_sha256: sha(bytes)},
      actor: actor,
      evidence_root: root
    )
  end

  defp counts do
    q = fn sql ->
      %{rows: [[n]]} = Repo.query!(sql, [])
      n
    end

    %{
      grants: q.("SELECT count(*) FROM model_call_grants"),
      allocations: q.("SELECT count(*) FROM model_call_allocations"),
      provisioned:
        q.("SELECT count(*) FROM audit_events WHERE event_type = 'model.grant.provisioned'")
    }
  end

  defp first!(fx, root, bytes) do
    result = provision(fx.actor, bytes, root)

    assert match?({:ok, %ModelCallGrant{}}, result),
           "prerequisite: first provision: #{inspect(result)}"

    {:ok, grant} = result
    grant
  end

  setup do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)
    %{fx: fx, admin: admin, root: PrototypeFixtures.scratch_dir!()}
  end

  describe "replay and second grants (D1)" do
    test "an identical replay with the evidence files removed returns the same grant, writing nothing",
         ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      before = counts()

      for name <- File.ls!(ctx.root), do: File.rm!(Path.join(ctx.root, name))

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert match?({:ok, %{id: id}} when id == grant.id, result), "replay: #{inspect(result)}"
      assert counts() == before
    end

    test "a different worksheet refuses :grant_exists, writing nothing", ctx do
      _grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      before = counts()

      result =
        provision(ctx.fx.actor, worksheet_bytes(ctx.root, "2026-10-30T12:00:00Z"), ctx.root)

      assert result == {:error, :grant_exists}, "a different worksheet: #{inspect(result)}"
      assert counts() == before
    end

    test "an identical replay of a revoked grant refuses :grant_exists", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)

      revoked =
        Agents.revoke_grant(grant, %{expected_revision: grant.revision}, actor: ctx.fx.actor)

      assert match?({:ok, %{status: :revoked}}, revoked),
             "prerequisite: revoke: #{inspect(revoked)}"

      before = counts()

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert result == {:error, :grant_exists}, "a revoked replay: #{inspect(result)}"
      assert counts() == before
    end
  end

  describe "the action carries its own validation (raw-action boundary)" do
    defp direct(actor, args) do
      ModelCallGrant
      |> Ash.Changeset.for_create(:provision_prototype, args, actor: actor)
      |> Ash.create()
    end

    test "a direct action with no, an invalid or an unverifiable worksheet writes nothing", ctx do
      valid = worksheet_bytes(ctx.root)
      before = counts()

      cases = [
        no_worksheet: %{evidence_root: ctx.root},
        invalid_worksheet: %{worksheet: ~s({"schema":"other"}), evidence_root: ctx.root},
        no_evidence_root: %{worksheet: valid}
      ]

      for {name, args} <- cases do
        result = direct(ctx.fx.actor, args)
        assert match?({:error, _}, result), "#{name}: #{inspect(result)}"
      end

      assert counts() == before
      positive_control!(ctx, valid, before)
    end

    test "caller-supplied server metadata is refused, writing nothing", ctx do
      valid = worksheet_bytes(ctx.root)
      before = counts()

      for {name, forged} <- [
            delegation_id: Ecto.UUID.generate(),
            funding_id: "d237-funding/2",
            binding_id: Ecto.UUID.generate(),
            budget_worksheet_sha256: String.duplicate("0", 64)
          ] do
        args = Map.put(%{worksheet: valid, evidence_root: ctx.root}, name, forged)
        result = direct(ctx.fx.actor, args)

        assert match?({:error, %Ash.Error.Invalid{}}, result),
               "forged #{name}: expected Invalid, got #{inspect(result)}"
      end

      assert counts() == before
      positive_control!(ctx, valid, before)
    end

    # The valid direct action, differing from each negative above only in
    # the refused input: it must provision exactly one grant, one event and
    # one allocation set, so the negatives were refused for their own reason.
    defp positive_control!(ctx, valid, before) do
      result = direct(ctx.fx.actor, %{worksheet: valid, evidence_root: ctx.root})

      assert match?({:ok, %ModelCallGrant{}}, result),
             "positive control: the valid direct action: #{inspect(result)}"

      after_counts = counts()
      assert after_counts.grants == before.grants + 1
      assert after_counts.provisioned == before.provisioned + 1
      assert after_counts.allocations > before.allocations
    end
  end

  describe "this binding's grant by original provenance, not its name (must-fix 2)" do
    defp change_terms!(ctx, grant, changes) do
      PrototypeFixtures.leave_runtime()

      result =
        Agents.update_grant_terms(grant, Map.put(changes, :expected_revision, grant.revision),
          actor: ctx.admin
        )

      assert match?({:ok, %ModelCallGrant{}}, result),
             "prerequisite: ordinary terms change: #{inspect(result)}"

      enter!(ctx.fx)
    end

    test "after an ordinary rename, provisioning mints no second grant", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      change_terms!(ctx, grant, %{name: "renamed-after-provisioning"})
      before = counts()

      identical = provision(ctx.fx.actor, bytes, ctx.root)
      assert identical == {:error, :grant_exists}, "renamed, identical: #{inspect(identical)}"

      different =
        provision(ctx.fx.actor, worksheet_bytes(ctx.root, "2026-10-30T12:00:00Z"), ctx.root)

      assert different == {:error, :grant_exists}, "renamed, different: #{inspect(different)}"
      assert counts() == before
    end

    test "after an ordinary terms change, an identical replay refuses :grant_exists", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      change_terms!(ctx, grant, %{purpose: "changed after provisioning"})
      before = counts()

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert result == {:error, :grant_exists}, "changed terms, identical: #{inspect(result)}"
      assert counts() == before
    end

    test "a later session of the same binding replays the original grant", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)

      entered = Prototype.enter_session(:codex_cli, "codex-session:c2-replay-0002")
      assert match?({:ok, _id}, entered), "prerequisite: a later session: #{inspect(entered)}"
      {:ok, later_id} = entered
      refute later_id == ctx.fx.actor.id, "prerequisite: the later session is a new delegation"

      resolved = Prototype.operator_actor(later_id)
      assert match?({:ok, _actor}, resolved), "prerequisite: later operator: #{inspect(resolved)}"
      {:ok, later} = resolved

      for name <- File.ls!(ctx.root), do: File.rm!(Path.join(ctx.root, name))
      before = counts()

      result = provision(later, bytes, ctx.root)

      assert match?({:ok, %{id: id}} when id == grant.id, result),
             "later-session replay: #{inspect(result)}"

      assert counts() == before
    end
  end

  describe "an ordinary grant with the prototype's name (D1 conflict, D3 revoke)" do
    setup ctx do
      PrototypeFixtures.leave_runtime()

      {:ok, ordinary} =
        Agents.create_grant(
          %{
            name: "d237-funding/1",
            purpose: "ordinary grant with a conflicting name",
            profile_ids: [:claude_cli_opus],
            total_attempts: 1,
            starts_at: ~U[2026-10-28 03:00:00.000000Z],
            expires_at: ~U[2026-10-29 03:00:00.000000Z]
          },
          actor: ctx.admin
        )

      enter!(ctx.fx)
      %{ordinary: ordinary}
    end

    test "provisioning refuses :grant_exists and writes nothing", ctx do
      before = counts()
      result = provision(ctx.fx.actor, worksheet_bytes(ctx.root), ctx.root)
      assert result == {:error, :grant_exists}, "conflict: #{inspect(result)}"
      assert counts() == before
    end

    test "the operator cannot revoke it", ctx do
      result =
        Agents.revoke_grant(ctx.ordinary, %{expected_revision: ctx.ordinary.revision},
          actor: ctx.fx.actor
        )

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "operator revoke of an ordinary grant: #{inspect(result)}"
    end
  end
end
