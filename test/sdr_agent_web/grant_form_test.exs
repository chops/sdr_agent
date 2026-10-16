defmodule SdrAgentWeb.GrantFormTest do
  @moduledoc """
  C9-05: the admin budget form's pure parsing. Wall times are entered in
  America/Denver and converted to UTC explicitly (both shown on review);
  user input becomes only known atoms; an edit is the exact difference from
  the loaded grant, sent with its revision.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgentWeb.GrantForm

  defp g_r0_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "G-R0",
        "purpose" => "Calibration of the two R0 profiles",
        "profile_ids" => ["claude_cli_opus", "claude_cli_sonnet"],
        "total_attempts" => "4",
        "per_utc_day_attempts" => "",
        "starts_at" => "2026-10-12T00:00",
        "expires_at" => "2026-10-18T23:59",
        "allocations" => %{
          "0" => %{
            "key" => "proof",
            "profile_id" => "claude_cli_opus",
            "applies_to" => ["proof"],
            "attempts" => "2",
            "available_from" => "",
            "available_until" => ""
          },
          "1" => %{
            "key" => "proof",
            "profile_id" => "claude_cli_sonnet",
            "applies_to" => ["proof"],
            "attempts" => "2",
            "available_from" => "",
            "available_until" => ""
          }
        }
      },
      overrides
    )
  end

  describe "parse/1" do
    test "G-R0 parses to known atoms and UTC instants" do
      assert {:ok, terms} = GrantForm.parse(g_r0_params())

      assert terms.name == "G-R0"
      assert terms.profile_ids == [:claude_cli_opus, :claude_cli_sonnet]
      assert terms.total_attempts == 4
      assert terms.per_utc_day_attempts == nil
      # MDT (UTC-6)
      assert terms.starts_at == ~U[2026-10-12 06:00:00.000000Z]
      assert terms.expires_at == ~U[2026-10-19 05:59:00.000000Z]

      assert [
               %{key: :proof, profile_id: :claude_cli_opus, applies_to: [:proof], attempts: 2},
               %{key: :proof, profile_id: :claude_cli_sonnet, applies_to: [:proof], attempts: 2}
             ] = terms.allocations

      assert Enum.all?(
               terms.allocations,
               &(is_nil(&1.available_from) and is_nil(&1.available_until))
             )
    end

    test "Denver wall times convert across the Nov 1 2026 DST boundary" do
      params =
        g_r0_params(%{"starts_at" => "2026-10-31T12:00", "expires_at" => "2026-11-02T12:00"})

      assert {:ok, terms} = GrantForm.parse(params)
      # MDT (UTC-6) before, MST (UTC-7) after.
      assert terms.starts_at == ~U[2026-10-31 18:00:00.000000Z]
      assert terms.expires_at == ~U[2026-11-02 19:00:00.000000Z]
      assert terms.notes == []
    end

    test "a wall time in the fall-back fold resolves to the earlier instant, with a note" do
      params = g_r0_params(%{"expires_at" => "2026-11-01T01:30"})

      assert {:ok, terms} = GrantForm.parse(params)
      assert terms.expires_at == ~U[2026-11-01 07:30:00.000000Z]
      assert [note] = terms.notes
      assert note =~ "occurs twice"
    end

    test "a wall time in the spring-forward gap is refused" do
      params = g_r0_params(%{"expires_at" => "2027-03-14T02:30"})

      assert {:error, errors} = GrantForm.parse(params)
      assert [message] = errors[:expires_at]
      assert message =~ "does not exist"
    end

    test "unparseable and missing input is reported per field" do
      params =
        g_r0_params(%{
          "name" => " ",
          "total_attempts" => "four",
          "per_utc_day_attempts" => "1.5",
          "starts_at" => "",
          "expires_at" => "tomorrow",
          "profile_ids" => ["claude_cli_opus", "claude_cli_gpt"],
          "allocations" => %{
            "0" => %{"key" => "b9", "applies_to" => ["b1", "zz"], "attempts" => "x"}
          }
        })

      assert {:error, errors} = GrantForm.parse(params)
      assert errors[:name] == ["is required"]
      assert errors[:total_attempts] == ["must be a whole number"]
      assert errors[:per_utc_day_attempts] == ["must be a whole number"]
      assert errors[:starts_at] == ["is required"]
      assert errors[:expires_at] == ["must be a date and time"]
      assert errors[:profile_ids] == ["includes an unknown profile"]
      assert [_ | _] = errors[{:allocation, "0"}]
    end

    test "no profile chosen is refused on review, not by the domain" do
      for profile_ids <- [[], [""], nil] do
        params =
          if profile_ids,
            do: g_r0_params(%{"profile_ids" => profile_ids}),
            else: Map.delete(g_r0_params(), "profile_ids")

        result = GrantForm.parse(params)

        assert match?({:error, %{profile_ids: ["choose at least one profile"]}}, result),
               "C9 follow-up: profile_ids #{inspect(profile_ids)} must be refused on review; got #{inspect(result)}"
      end
    end

    test "never creates atoms from input" do
      params = g_r0_params(%{"profile_ids" => ["not_an_atom_#{System.unique_integer()}"]})
      assert {:error, %{profile_ids: _}} = GrantForm.parse(params)
    end
  end

  describe "create_attrs/1" do
    test "is what Agents.create_grant/2 takes" do
      {:ok, terms} = GrantForm.parse(g_r0_params())
      attrs = GrantForm.create_attrs(terms)

      refute Map.has_key?(attrs, :notes)
      assert attrs.total_attempts == 4
      assert length(attrs.allocations) == 2
      assert Enum.all?(attrs.allocations, &(not Map.has_key?(&1, :index)))
    end
  end

  describe "edit" do
    defp grant do
      %ModelCallGrant{
        id: "g1",
        name: "G-R0",
        purpose: "Calibration",
        status: :active,
        profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
        total_attempts: 4,
        per_utc_day_attempts: nil,
        starts_at: ~U[2026-10-12 06:00:00.000000Z],
        expires_at: ~U[2026-10-19 05:59:00.000000Z],
        revision: 3,
        allocations: [
          %ModelCallAllocation{
            key: :proof,
            profile_id: :claude_cli_opus,
            applies_to: [:proof],
            attempts: 2
          },
          %ModelCallAllocation{
            key: :proof,
            profile_id: :claude_cli_sonnet,
            applies_to: [:proof],
            attempts: 2
          }
        ]
      }
    end

    test "params_for/1 shows the grant's times as Denver wall times" do
      params = GrantForm.params_for(grant())
      assert params["starts_at"] == "2026-10-12T00:00"
      assert params["expires_at"] == "2026-10-18T23:59"
      assert params["total_attempts"] == "4"
      assert map_size(params["allocations"]) == 2
    end

    test "an unchanged form is no change" do
      grant = grant()
      {:ok, terms} = grant |> GrantForm.params_for() |> GrantForm.parse()
      assert GrantForm.changes(grant, terms) == %{terms: [], allocations: []}
    end

    test "changes/2 and update_attrs/2 carry only the difference and the revision" do
      grant = grant()

      params =
        grant
        |> GrantForm.params_for()
        |> Map.put("total_attempts", "6")
        |> put_in(["allocations", "0", "attempts"], "4")
        |> put_in(["allocations", "9"], %{
          "key" => "b1",
          "profile_id" => "",
          "applies_to" => ["b1"],
          "attempts" => "1",
          "available_from" => "",
          "available_until" => ""
        })

      {:ok, terms} = GrantForm.parse(params)
      changes = GrantForm.changes(grant, terms)

      assert changes.terms == [{:total_attempts, 4, 6}]

      assert [
               {:update, %{key: :proof, profile_id: :claude_cli_opus}, [{:attempts, 2, 4}]},
               {:create, %{key: :b1, profile_id: nil, attempts: 1}}
             ] = changes.allocations

      attrs = GrantForm.update_attrs(grant, changes)
      assert attrs.expected_revision == 3
      assert attrs.total_attempts == 6
      refute Map.has_key?(attrs, :name)

      assert attrs.allocations == [
               %{key: :proof, profile_id: :claude_cli_opus, attempts: 4},
               %{
                 key: :b1,
                 profile_id: nil,
                 applies_to: [:b1],
                 attempts: 1,
                 available_from: nil,
                 available_until: nil
               }
             ]
    end
  end

  describe "edit keeps untouched stored instants (Codex review of PR #134)" do
    @later_fold ~U[2026-11-01 08:30:00.000000Z]

    defp fold_grant do
      %ModelCallGrant{
        id: "g2",
        name: "G-FOLD",
        purpose: "Fold",
        status: :active,
        profile_ids: [:claude_cli_opus],
        total_attempts: 4,
        per_utc_day_attempts: nil,
        starts_at: ~U[2026-10-12 06:00:00.123456Z],
        expires_at: @later_fold,
        revision: 5,
        allocations: [
          %ModelCallAllocation{
            key: :b1,
            profile_id: nil,
            applies_to: [:b1],
            attempts: 2,
            available_from: ~U[2026-10-13 07:15:30.654321Z],
            available_until: @later_fold
          }
        ]
      }
    end

    test "an unchanged form is no change, whatever the stored instants" do
      grant = fold_grant()
      params = GrantForm.params_for(grant)
      assert params["expires_at"] == "2026-11-01T01:30"

      {:ok, terms} = GrantForm.parse(params, GrantForm.originals(grant))
      assert terms.expires_at == @later_fold
      assert terms.starts_at == grant.starts_at
      assert terms.notes == []

      changes = GrantForm.changes(grant, terms)
      assert changes == %{terms: [], allocations: []}
      assert GrantForm.update_attrs(grant, changes) == %{expected_revision: 5}
    end

    test "changing one term sends only that term" do
      grant = fold_grant()
      params = grant |> GrantForm.params_for() |> Map.put("total_attempts", "6")

      {:ok, terms} = GrantForm.parse(params, GrantForm.originals(grant))
      [allocation] = terms.allocations
      assert allocation.available_until == @later_fold
      assert allocation.available_from == ~U[2026-10-13 07:15:30.654321Z]

      assert GrantForm.update_attrs(grant, GrantForm.changes(grant, terms)) ==
               %{expected_revision: 5, total_attempts: 6}
    end

    test "a changed wall time is parsed (fold: the earlier instant, noted)" do
      grant = fold_grant()
      params = grant |> GrantForm.params_for() |> Map.put("expires_at", "2026-11-01T01:45")

      {:ok, terms} = GrantForm.parse(params, GrantForm.originals(grant))
      assert terms.expires_at == ~U[2026-11-01 07:45:00.000000Z]
      assert [_note] = terms.notes
    end

    test "an original applies only to its own allocation" do
      grant = fold_grant()

      params =
        grant
        |> GrantForm.params_for()
        |> put_in(["allocations", "1"], %{
          "key" => "b2",
          "profile_id" => "",
          "applies_to" => ["b2"],
          "attempts" => "1",
          "available_from" => "",
          "available_until" => "2026-11-01T01:30"
        })

      {:ok, terms} = GrantForm.parse(params, GrantForm.originals(grant))
      b2 = Enum.find(terms.allocations, &(&1.key == :b2))
      # A new row is parsed: the earlier instant, with its note.
      assert b2.available_until == ~U[2026-11-01 07:30:00.000000Z]
      assert [_note] = terms.notes
    end

    test "preview shows the stored instant for an untouched value" do
      grant = fold_grant()
      original = grant.expires_at

      assert GrantForm.preview("2026-11-01T01:30", original) == "Nov 1, 2026 08:30 UTC"
      assert GrantForm.preview("2026-11-01T01:30") =~ "07:30 UTC (the earlier of two)"
    end
  end

  describe "display" do
    test "shows Denver with its zone abbreviation and UTC" do
      assert GrantForm.denver(~U[2026-10-31 18:00:00Z]) == "Oct 31, 2026 12:00 MDT"
      assert GrantForm.denver(~U[2026-11-02 19:00:00Z]) == "Nov 2, 2026 12:00 MST"
      assert GrantForm.utc(~U[2026-11-02 19:00:00Z]) == "Nov 2, 2026 19:00 UTC"
    end

    test "shows seconds and microseconds when present, so distinct instants never look equal" do
      assert GrantForm.utc(~U[2026-10-31 12:00:59Z]) == "Oct 31, 2026 12:00:59 UTC"
      assert GrantForm.utc(~U[2026-10-31 12:00:00.000000Z]) == "Oct 31, 2026 12:00 UTC"

      assert GrantForm.utc(~U[2026-10-31 12:00:00.123456Z]) ==
               "Oct 31, 2026 12:00:00.123456 UTC"

      assert GrantForm.denver(~U[2026-10-31 18:00:59Z]) == "Oct 31, 2026 12:00:59 MDT"
      refute GrantForm.utc(~U[2026-10-31 12:00:00Z]) == GrantForm.utc(~U[2026-10-31 12:00:59Z])
    end
  end

  describe "normalize/1 (Codex review of af2733b)" do
    test "keeps only the form's shape: known keys, string or string-list values, map rows" do
      raw = %{
        "name" => "G",
        "total_attempts" => %{"x" => 1},
        "profile_ids" => ["claude_cli_opus", 7, %{}],
        "colour" => "blue",
        "allocations" => %{
          "0" => "x",
          "1" => %{"key" => "b1", "colour" => "blue", "attempts" => ["2"], "applies_to" => "b1"},
          "two" => %{"key" => "b2"}
        }
      }

      params = GrantForm.normalize(raw)

      assert params["name"] == "G"
      assert params["total_attempts"] == ""
      assert params["profile_ids"] == ["claude_cli_opus"]
      refute Map.has_key?(params, "colour")
      assert Map.keys(params["allocations"]) == ["1"]

      assert params["allocations"]["1"] == %{
               "key" => "b1",
               "profile_id" => "",
               "applies_to" => [],
               "attempts" => "",
               "available_from" => "",
               "available_until" => ""
             }
    end

    test "a non-map allocations value or payload becomes an empty form" do
      assert GrantForm.normalize(%{"allocations" => "x"})["allocations"] == %{}
      assert GrantForm.normalize("x") == GrantForm.new_params()
    end
  end
end
