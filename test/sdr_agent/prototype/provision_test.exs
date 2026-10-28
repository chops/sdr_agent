defmodule SdrAgent.Prototype.ProvisionTest do
  @moduledoc """
  IF-2 provisioning (interfaces r6; F7): the counts-only budget worksheet
  with byte-resolved evidence, and the one `:provision_prototype` grant with
  the exact `d237-funding/1` terms, the anchor as creator and updater, a
  replay, a refused second grant, and no term change, release or ordinary
  creation in prototype runtime.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents

  @authority SdrAgent.Prototype.Authority
  @routes ~w(prototype_binding owner_dev owner_calibration hosted other_owner)

  # An exclusive, unpredictable, owned 0700 root (Codex 39a6fd61 R1).
  defp scratch_dir!, do: PrototypeFixtures.scratch_dir!()

  defp evidence!(root, name, body \\ "counts-only receipt\n") do
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o600)
    %{"path" => name, "sha256" => sha(body)}
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp basis("prototype_binding"), do: "agent_receipt"
  defp basis(_owner_route), do: "owner_attestation"

  defp worksheet(root, overrides \\ %{}) do
    routes =
      for route <- @routes do
        %{
          "route" => route,
          "basis" => basis(route),
          "consumed" => 0,
          "evidence" => evidence!(root, "#{route}.receipt")
        }
      end

    Map.merge(
      %{
        "schema" => "d237-budget-worksheet/1",
        "shared_total" => 60,
        "window_starts_at" => "2026-10-28T02:38:32.000000Z",
        "as_of" => "2026-10-29T12:00:00Z",
        "routes" => routes,
        "previous_bindings" => %{
          "consumed" => 0,
          "evidence" => evidence!(root, "previous.receipt")
        }
      },
      overrides
    )
  end

  defp provision(ctx, actor \\ nil) do
    call(Agents, :provision_prototype_grant, [
      %{worksheet: ctx.bytes, worksheet_sha256: ctx.digest},
      [actor: actor || ctx.fx.actor, evidence_root: ctx.root]
    ])
  end

  defp check(root, map) do
    bytes = Jason.encode!(map)
    call(@authority, :check_worksheet, [bytes, sha(bytes), root])
  end

  describe "the budget worksheet" do
    test "a complete worksheet with resolvable evidence passes" do
      root = scratch_dir!()
      result = check(root, worksheet(root))
      assert match?({:ok, %{remaining: 60}}, result), "worksheet: #{inspect(result)}"
    end

    test "a missing, duplicated or owner-route agent receipt is budget_unbounded" do
      root = scratch_dir!()
      base = worksheet(root)
      [first | rest] = base["routes"]

      cases = [
        missing: %{base | "routes" => rest},
        duplicated: %{base | "routes" => [first, first | tl(rest)]},
        owner_agent_receipt: %{
          base
          | "routes" =>
              Enum.map(base["routes"], fn
                %{"route" => "owner_dev"} = r -> %{r | "basis" => "agent_receipt"}
                r -> r
              end)
        },
        hosted_agent_receipt: %{
          base
          | "routes" =>
              Enum.map(base["routes"], fn
                %{"route" => "hosted"} = r -> %{r | "basis" => "agent_receipt"}
                r -> r
              end)
        }
      ]

      for {name, map} <- cases do
        assert check(root, map) == {:error, :budget_unbounded}, "#{name} was not budget_unbounded"
      end
    end

    test "evidence that does not resolve to the recorded bytes is budget_unbounded" do
      root = scratch_dir!()
      base = worksheet(root)
      [first | rest] = base["routes"]
      wide = evidence!(root, "wide.receipt")
      File.chmod!(Path.join(root, "wide.receipt"), 0o644)
      File.ln_s!(Path.join(root, "owner_dev.receipt"), Path.join(root, "link.receipt"))

      bad_evidence = [
        invented: %{"path" => "invented.receipt", "sha256" => sha("x")},
        hash_mismatch: %{first["evidence"] | "sha256" => sha("other bytes")},
        traversal: %{"path" => "../outside.receipt", "sha256" => sha("x")},
        wide_mode: wide,
        symlink: %{"path" => "link.receipt", "sha256" => first["evidence"]["sha256"]}
      ]

      for {name, evidence} <- bad_evidence do
        map = %{base | "routes" => [%{first | "evidence" => evidence} | rest]}
        assert check(root, map) == {:error, :budget_unbounded}, "#{name} evidence was accepted"
      end
    end

    test "less than the 50-attempt ceiling remaining is budget_below_ceiling" do
      root = scratch_dir!()
      base = worksheet(root)

      routes =
        Enum.map(base["routes"], fn
          %{"route" => "owner_dev"} = r -> %{r | "consumed" => 5}
          r -> r
        end)

      map = %{
        base
        | "routes" => routes,
          "previous_bindings" => %{base["previous_bindings"] | "consumed" => 6}
      }

      assert check(root, map) == {:error, :budget_below_ceiling}

      exact = %{map | "previous_bindings" => %{base["previous_bindings"] | "consumed" => 5}}
      assert match?({:ok, %{remaining: 50}}, check(root, exact))
    end

    test "a wrong digest, an unknown key or a bad window is worksheet_invalid" do
      root = scratch_dir!()
      base = worksheet(root)
      bytes = Jason.encode!(base)

      assert call(@authority, :check_worksheet, [bytes, sha("other"), root]) ==
               {:error, :worksheet_invalid}

      assert check(root, Map.put(base, "extra", 1)) == {:error, :worksheet_invalid}

      assert check(root, %{base | "as_of" => "2026-10-27T00:00:00Z"}) ==
               {:error, :worksheet_invalid}

      assert check(root, %{base | "shared_total" => 61}) == {:error, :worksheet_invalid}
    end
  end

  describe "provisioning" do
    setup do
      # Users are arranged before prototype runtime, which refuses user administration.
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      enter!(fx)
      root = scratch_dir!()
      bytes = Jason.encode!(worksheet(root))
      %{fx: fx, admin: admin, root: root, bytes: bytes, digest: sha(bytes)}
    end

    test "the operator provisions exactly the entry's terms, with the anchor as creator and updater",
         ctx do
      result = provision(ctx)
      assert match?({:ok, _}, result), "provision: #{inspect(result)}"
      {:ok, grant} = result

      assert grant.total_attempts == 50
      assert grant.starts_at == ~U[2026-10-28 02:38:32.000000Z]
      assert grant.expires_at == ~U[2026-11-07 07:00:00.000000Z]
      assert grant.profile_ids == [:claude_cli_opus]
      assert grant.created_by_id == ctx.fx.anchor.id
      assert grant.updated_by_id == ctx.fx.anchor.id

      [event] = events_of_type(ctx.fx.tenant, "model.grant.provisioned")
      assert event.actor_type == :prototype_operator
      assert event.actor_id == ctx.fx.delegation.id
      assert event.payload["arguments"]["funding_id"] == "d237-funding/1"
      assert event.payload["arguments"]["budget_worksheet_sha256"] == ctx.digest
      assert event.payload["arguments"]["delegation_id"] == ctx.fx.delegation.id
    end

    test "an identical replay returns the same grant; no second grant is created", ctx do
      {:ok, grant} = provision(ctx)
      assert match?({:ok, %{id: id}} when id == grant.id, provision(ctx))

      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM model_call_grants", [])
      assert n == 1
    end

    test "a non-operator cannot provision", ctx do
      assert match?({:error, _}, provision(ctx, ctx.admin))
      assert match?({:error, _}, provision(ctx, system_actor(:agent_runtime, ctx.fx.tenant)))
    end

    test "in prototype runtime grant creation, term changes and releases are refused; revoke is the operator's",
         ctx do
      {:ok, grant} = provision(ctx)
      admin = ctx.admin

      created =
        Agents.create_grant(
          %{
            name: "ordinary",
            purpose: "ordinary",
            profile_ids: [:claude_cli_opus],
            total_attempts: 1,
            starts_at: ~U[2026-10-28 03:00:00.000000Z],
            expires_at: ~U[2026-10-29 03:00:00.000000Z]
          },
          actor: admin
        )

      terms =
        Agents.update_grant_terms(grant, %{expected_revision: grant.revision, total_attempts: 40},
          actor: admin
        )

      released =
        Agents.release_allocation(grant, %{expected_revision: grant.revision, key: :b1},
          actor: admin
        )

      for {name, result} <- [create: created, update_terms: terms, release: released] do
        assert match?({:error, %Ash.Error.Forbidden{}}, result), "#{name} was not forbidden"
      end

      assert match?(
               {:ok, %{status: :revoked}},
               Agents.revoke_grant(grant, %{expected_revision: grant.revision},
                 actor: ctx.fx.actor
               )
             )
    end
  end
end
