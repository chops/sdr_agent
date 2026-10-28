defmodule SdrAgent.Prototype.SeedSalesActionsTest do
  @moduledoc """
  The four Sales `:seed_prototype` creation actions of the D-237 seed (slice
  B; seed design note r1 D4-D6 as ruled in Codex b8d624fe; RED scope Codex
  66449b01): `IcpDefinition`, `Sequence`, `SequenceStep` and `Campaign`, as
  the live prototype operator.

  - **D4, fixed fields:** the ICP and the sequence are version-1 drafts;
    the step is the one fixed step (position 1, email, no delay, approval
    required, stops on reply); the campaign is a tier-0 draft named
    `"GTMscape prototype"`, with footer `"footer/1"`, the reserved sender
    `team@gtmscape.example` under the unchanged sender guard, the 17-byte
    sender name, and the resource's timezone and quiet-hour defaults.
    Server-owned fields are not inputs.
  - **D5, tenant-bound references:** a step's sequence and BOTH of a
    campaign's references (ICP and sequence) must be rows of the new row's
    own tenant, each edge refused when missing, nonexistent or foreign with
    an otherwise-valid sibling, and accepted when same-tenant. Under the
    common error rule (Codex 6d1ead6d) a returned read error of that check
    keeps its own identity and is never relabelled "is not a row of this
    tenant": one case per edge and error, each selecting exactly that edge's
    read through the test-build ImportTenant seam (Codex 683a74e6).
  - **D6, the provenance digest:** a required `seed_provenance_sha256` of
    exactly 64 lowercase hex characters at EACH action (never trimmed or
    coerced; pinned per action), recorded on that action's one
    authoritative creation event, with the delegation as the actor.
  - **Policy:** forged, foreign and non-operator callers, a previously
    resolved operator that no longer resolves (live binding drift), and
    ordinary runtime, are refused; the seeder's and an admin's ordinary
    actions are unchanged; the operator gains no other Sales permission.

  RED stage: the four actions are declared and explicitly refused for every
  caller (each has its own `forbid_if always()` policy, since the broad
  create policy authorizes always), with no body. Classifications observed
  at the RED (see the map): the D4 creates, the D5 nonexistent, foreign and
  missing-campaign-sequence cases (an ordinary campaign's sequence is
  nullable, so only the action can require it), the D6 wrong-shape digests
  and the D6 events fail first on that stub's `Forbidden`, and their later
  assertions are unexecuted; the reserved-sender guard is reached
  behavioural RED (the declaration has no sender guard); the D5
  returned-error cases fail first on the stub too: their selected read is
  never reached while the action is refused. A missing
  step sequence and a missing campaign ICP are already refused at the input
  (required attributes), as are the missing, nil and non-string digests and
  the server-owned fields (controls); the deny cases and the ordinary
  regressions pass too: the deny cases are pending-refusal controls, not
  least-privilege GREEN.

  Synthetic `.test` data in a sandboxed prototype binding. The database
  admits one tenant, so a foreign row exists only by moving a real row's
  `tenant_id` (`SdrAgent.AuditCase.tamper!/2`, as in the import policy
  tests).
  """
  use SdrAgent.PrototypeCase, async: false

  alias Ash.Error.Forbidden.ForbiddenField
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Outreach.Delivery.Message
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.IcpDefinition
  alias SdrAgent.Sales.Sequence
  alias SdrAgent.Sales.SequenceStep
  alias SdrAgent.Sales.Validations.ImportTenant

  @digest :sha256
          |> :crypto.hash("s3 slice B synthetic provenance")
          |> Base.encode16(case: :lower)
  @created [
    {IcpDefinition, "icp_definitions", "sales.icp_definition.created"},
    {Sequence, "sequences", "sales.sequence.created"},
    {SequenceStep, "sequence_steps", "sales.sequence_step.created"},
    {Campaign, "campaigns", "sales.campaign.created"}
  ]

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  defp seed_prototype(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:seed_prototype, attrs, actor: actor)
    |> Ash.create()
  end

  defp seeder(ctx), do: SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")
  defp unique, do: Integer.to_string(System.unique_integer([:positive]))
  defp campaign_file, do: F.seed_contents()["campaign.json"]

  defp icp_attrs do
    icp = campaign_file()["icp"]

    %{
      name: icp["name"],
      description: icp["description"],
      criteria: icp["criteria"],
      seed_provenance_sha256: @digest
    }
  end

  defp sequence_attrs,
    do: %{name: campaign_file()["sequence"]["name"], seed_provenance_sha256: @digest}

  defp step_attrs(sequence_id) do
    %{
      sequence_id: sequence_id,
      instructions: campaign_file()["sequence"]["step"]["instructions"],
      seed_provenance_sha256: @digest
    }
  end

  defp campaign_attrs(icp_id, sequence_id) do
    %{
      name: "GTMscape prototype",
      icp_definition_id: icp_id,
      sequence_id: sequence_id,
      sender_name: campaign_file()["sender_name"],
      sender_email: "team@gtmscape.example",
      footer_template_version: "footer/1",
      seed_provenance_sha256: @digest
    }
  end

  # Same-tenant draft prerequisites through the seeder's ordinary actions.
  defp seeder_icp!(ctx) do
    result =
      Sales.seed_icp_definition(
        %{name: "Seeded ICP " <> unique(), description: "x", criteria: %{industries: ["x"]}},
        actor: seeder(ctx)
      )

    assert match?({:ok, _}, result),
           "prerequisite: the seeder ICP returned #{inspect(outcome(result))}"

    elem(result, 1)
  end

  defp seeder_sequence!(ctx) do
    result = Sales.seed_sequence(%{name: "Seeded sequence " <> unique()}, actor: seeder(ctx))

    assert match?({:ok, _}, result),
           "prerequisite: the seeder sequence returned #{inspect(outcome(result))}"

    elem(result, 1)
  end

  # Moves a real row to another tenant id (see the moduledoc).
  defp move_to_foreign_tenant!(table, id) do
    tamper!("UPDATE #{table} SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(id)
    ])

    :ok
  end

  # The four tables' rows and their creation events.
  defp survivors(ctx) do
    Map.new(@created, fn {_resource, table, type} ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, {n, length(events_of_type(ctx.tenant, type))}}
    end)
  end

  # A value-free outcome: the module, and each error's module and field.
  defp outcome({:ok, %module{}}), do: {:ok, module}

  defp outcome({:error, %module{errors: errors}}),
    do: {:error, module, Enum.map(errors, &{&1.__struct__, Map.get(&1, :field)})}

  defp outcome(_other), do: :unknown

  defp created!(result, label) do
    assert match?({:ok, _}, result), "#{label}: #{inspect(outcome(result))}"
    elem(result, 1)
  end

  # Refused as invalid input on `field` (never as Forbidden).
  defp refused_on?({:error, %Ash.Error.Invalid{errors: errors}}, field),
    do: Enum.any?(errors, &(Map.get(&1, :field) == field))

  defp refused_on?(_result, _field), do: false

  defp forbidden?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)

  defp leaves(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &leaves/1)
  defp leaves(error), do: [error]

  # The injected leaf and its returned class, per kind.
  defp injection(:forbidden, referenced) do
    leaf = ForbiddenField.exception(resource: referenced, field: :s3_probe)
    {leaf, Ash.Error.Forbidden.exception(errors: [leaf])}
  end

  defp injection(:unknown, _referenced) do
    leaf = UnknownError.exception(error: "s3 probe: reference read")
    {leaf, Ash.Error.Unknown.exception(errors: [leaf])}
  end

  # The injected leaf exactly as a top-level :seed_prototype create returns
  # it (Ash 3.37.2 / Splode 0.3.2; the oracle r2 precedent at 62958f29 for
  # :import_prototype, measured in c3-20261028T140813Z-56517): create.ex:228-230
  # (Ash.Error.to_error_class) filters the leaf's frames with Ash.Error's
  # Splode filter ["Ash.", "Splode."], then create.ex:92-96's
  # Ash.Error.to_error_class(error, bread_crumbs: "Error returned from:
  # <resource>.<action>") prepends exactly that one crumb to the leaf's own
  # (accumulate_bread_crumbs, splode.ex:636-666). The crumb is built from the
  # action's own resource and name only, never read from a returned error;
  # every other key and value stays the injected leaf's, and == checks the
  # crumbs' exact order and multiplicity.
  defp returned(%{stacktrace: %Splode.Stacktrace{stacktrace: frames}} = leaf)
       when is_list(frames) do
    filtered = Splode.filter_stacktrace(frames, Ash.Error.__stacktrace_filters__())
    %{leaf | stacktrace: %Splode.Stacktrace{stacktrace: filtered}}
  end

  defp action_crumb(resource), do: "Error returned from: #{inspect(resource)}.seed_prototype"

  defp action_returned(injected, resource),
    do: %{returned(injected) | bread_crumbs: [action_crumb(resource) | injected.bread_crumbs]}

  # One edge's call with valid same-tenant prerequisites:
  # {resource, field, referenced resource, referenced id, attrs}.
  defp reference_edge(ctx, :step_sequence) do
    sequence = seeder_sequence!(ctx)
    {SequenceStep, :sequence_id, Sequence, sequence.id, step_attrs(sequence.id)}
  end

  defp reference_edge(ctx, :campaign_icp) do
    {icp, sequence} = {seeder_icp!(ctx), seeder_sequence!(ctx)}
    {Campaign, :icp_definition_id, IcpDefinition, icp.id, campaign_attrs(icp.id, sequence.id)}
  end

  defp reference_edge(ctx, :campaign_sequence) do
    {icp, sequence} = {seeder_icp!(ctx), seeder_sequence!(ctx)}
    {Campaign, :sequence_id, Sequence, sequence.id, campaign_attrs(icp.id, sequence.id)}
  end

  # The campaign's sequence read follows its ICP read, which succeeded.
  defp sibling_succeeded?(:campaign_sequence, reads, ref) do
    {before, _rest} = Enum.split_while(reads, &(&1 != {:reached, ref}))
    {:select, "icp_definitions", :ok} in before
  end

  defp sibling_succeeded?(_edge, _reads, _ref), do: true

  # Puts the ImportTenant scope for `fun`, then restores the prior one (or
  # its absence) on every exit.
  defp with_fault(scope, fun) do
    key = {ImportTenant, :read_fault}
    previous = Process.get(key, :__absent__)
    Process.put(key, scope)

    try do
      fun.()
    after
      if previous == :__absent__, do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  # This process's reads while `fun` runs, as {verb, table, result} with the
  # table from the reviewed Sales set only, interleaved with the seam's reach
  # messages; and `fun`'s value. Nothing else of an event is kept.
  defp reads_during(fun) do
    parent = self()
    handler = "s3-b-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:s3_b_read, read_label(metadata)})
      end,
      nil
    )

    value =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {drain_reads([]), value}
  end

  defp drain_reads(acc) do
    receive do
      {:s3_b_read, label} -> drain_reads([label | acc])
      {ImportTenant, :reached, ref} -> drain_reads([{:reached, ref} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @sales_tables ~w(icp_definitions sequences sequence_steps campaigns)

  defp read_label(%{query: "SELECT" <> _rest, source: source, result: {:ok, _result}})
       when source in @sales_tables,
       do: {:select, source, :ok}

  defp read_label(_metadata), do: :other

  # Every action with valid same-tenant prerequisites.
  defp valid_calls(ctx) do
    icp = seeder_icp!(ctx)
    sequence = seeder_sequence!(ctx)

    [
      {IcpDefinition, icp_attrs()},
      {Sequence, sequence_attrs()},
      {SequenceStep, step_attrs(sequence.id)},
      {Campaign, campaign_attrs(icp.id, sequence.id)}
    ]
  end

  describe "D4: each action creates its fixed draft (the live operator)" do
    test "IcpDefinition: a version-1 draft from the synthetic campaign file", ctx do
      icp = created!(seed_prototype(IcpDefinition, icp_attrs(), ctx.actor), "the ICP")
      assert {icp.version, icp.status, icp.tenant_id} == {1, :draft, ctx.tenant.id}
      assert byte_size(icp.criteria_sha256) == 32
    end

    test "Sequence: a version-1 draft", ctx do
      sequence = created!(seed_prototype(Sequence, sequence_attrs(), ctx.actor), "the sequence")
      assert {sequence.version, sequence.status, sequence.tenant_id} == {1, :draft, ctx.tenant.id}
    end

    test "SequenceStep: the one fixed step of a same-tenant draft sequence", ctx do
      sequence = seeder_sequence!(ctx)

      step =
        created!(seed_prototype(SequenceStep, step_attrs(sequence.id), ctx.actor), "the step")

      assert {step.sequence_id, step.position, step.channel, step.delay_days,
              step.requires_approval, step.stop_on_reply, step.tenant_id} ==
               {sequence.id, 1, :email, 0, true, true, ctx.tenant.id}
    end

    test "Campaign: a tier-0 draft with the D4 constants and the resource defaults", ctx do
      icp = seeder_icp!(ctx)
      sequence = seeder_sequence!(ctx)

      campaign =
        created!(
          seed_prototype(Campaign, campaign_attrs(icp.id, sequence.id), ctx.actor),
          "the campaign"
        )

      assert campaign.name == "GTMscape prototype"
      assert campaign.footer_template_version == "footer/1"
      assert "footer/1" in Message.footer_versions()
      assert to_string(campaign.sender_email) == "team@gtmscape.example"
      assert campaign.sender_name == "the GTMscape team"
      assert byte_size(campaign.sender_name) == 17

      assert {campaign.status, campaign.autonomy_tier, campaign.timezone,
              campaign.quiet_hours_start, campaign.quiet_hours_end} ==
               {:draft, 0, "America/Denver", ~T[18:00:00], ~T[08:00:00]}

      assert {campaign.icp_definition_id, campaign.sequence_id, campaign.tenant_id} ==
               {icp.id, sequence.id, ctx.tenant.id}
    end

    test "the reserved-name guard stays on the campaign sender address", ctx do
      attrs = %{
        campaign_attrs(Ecto.UUID.generate(), Ecto.UUID.generate())
        | sender_email: "team@gtmscape.com"
      }

      changeset = Ash.Changeset.for_create(Campaign, :seed_prototype, attrs, actor: ctx.actor)

      assert Enum.any?(changeset.errors, &(Map.get(&1, :field) == :sender_email)),
             "a non-reserved sender address passed: #{inspect(Enum.map(changeset.errors, &{&1.__struct__, Map.get(&1, :field)}))}"
    end

    test "server-owned fields are not inputs of any of the four actions", ctx do
      id = Ecto.UUID.generate()

      cases = [
        {IcpDefinition, icp_attrs(),
         [id: id, tenant_id: id, status: :active, version: 2, criteria_sha256: <<0::256>>]},
        {Sequence, sequence_attrs(), [id: id, tenant_id: id, status: :active, version: 2]},
        {SequenceStep, step_attrs(id),
         [
           id: id,
           tenant_id: id,
           position: 2,
           channel: :email,
           delay_days: 3,
           requires_approval: false,
           stop_on_reply: false
         ]},
        {Campaign, campaign_attrs(id, id),
         [
           id: id,
           tenant_id: id,
           status: :active,
           autonomy_tier: 1,
           timezone: "UTC",
           quiet_hours_start: ~T[00:00:00],
           quiet_hours_end: ~T[01:00:00]
         ]}
      ]

      for {resource, base, fields} <- cases, {field, value} <- fields do
        changeset =
          Ash.Changeset.for_create(resource, :seed_prototype, Map.put(base, field, value),
            actor: ctx.actor
          )

        refute changeset.valid?, "#{inspect(resource)}: #{field} was accepted"

        assert Enum.any?(changeset.errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1)),
               "#{inspect(resource)}: #{field} was not refused as an input"
      end
    end
  end

  describe "D5: the step's and the campaign's references are rows of this tenant" do
    test "a step's sequence: missing, nonexistent or foreign is refused on sequence_id, writing nothing",
         ctx do
      foreign = seeder_sequence!(ctx)
      :ok = move_to_foreign_tenant!("sequences", foreign.id)
      before = survivors(ctx)

      for {label, sequence_id} <- [
            missing: nil,
            nonexistent: Ecto.UUID.generate(),
            foreign: foreign.id
          ] do
        result = seed_prototype(SequenceStep, step_attrs(sequence_id), ctx.actor)

        assert refused_on?(result, :sequence_id),
               "#{label} sequence: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end

    test "a campaign's ICP: missing, nonexistent or foreign is refused on icp_definition_id, with a valid sequence",
         ctx do
      sequence = seeder_sequence!(ctx)
      foreign = seeder_icp!(ctx)
      :ok = move_to_foreign_tenant!("icp_definitions", foreign.id)
      before = survivors(ctx)

      for {label, icp_id} <- [
            missing: nil,
            nonexistent: Ecto.UUID.generate(),
            foreign: foreign.id
          ] do
        result = seed_prototype(Campaign, campaign_attrs(icp_id, sequence.id), ctx.actor)

        assert refused_on?(result, :icp_definition_id),
               "#{label} ICP: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end

    test "a campaign's sequence: missing, nonexistent or foreign is refused on sequence_id, with a valid ICP",
         ctx do
      icp = seeder_icp!(ctx)
      foreign = seeder_sequence!(ctx)
      :ok = move_to_foreign_tenant!("sequences", foreign.id)
      before = survivors(ctx)

      for {label, sequence_id} <- [
            missing: nil,
            nonexistent: Ecto.UUID.generate(),
            foreign: foreign.id
          ] do
        result = seed_prototype(Campaign, campaign_attrs(icp.id, sequence_id), ctx.actor)

        assert refused_on?(result, :sequence_id),
               "#{label} sequence: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end

    # Codex 6d1ead6d, 66449b01 and 683a74e6: a returned read error of a
    # reference check is not evidence of absence. Each case selects exactly
    # one edge (the test-build ImportTenant seam's `%{field:, resource:,
    # id:, tenant_id:}` selector, with a fresh ref; the prior scope is saved
    # and restored), asserts that read is reached once (the campaign's
    # sequence read after its ICP read succeeded), that nothing survives,
    # and that the injected leaf keeps its identity. While the B actions stay
    # deny-only, the stub refuses before ImportTenant runs.
    for {edge, kind} <- [
          step_sequence: :forbidden,
          step_sequence: :unknown,
          campaign_icp: :forbidden,
          campaign_icp: :unknown,
          campaign_sequence: :forbidden,
          campaign_sequence: :unknown
        ] do
      test "#{edge}, returned #{kind}: reached once at that read, never relabelled as absence",
           ctx do
        {resource, field, referenced, id, attrs} = reference_edge(ctx, unquote(edge))
        {injected, class} = injection(unquote(kind), referenced)
        ref = make_ref()
        before = survivors(ctx)
        selector = %{field: field, resource: referenced, id: id, tenant_id: ctx.tenant.id}

        {reads, result} =
          with_fault({selector, ref, {:error, class}}, fn ->
            reads_during(fn -> seed_prototype(resource, attrs, ctx.actor) end)
          end)

        assert {:reached, ref} in reads,
               "#{inspect(resource)}.#{field}: the read was not reached; #{inspect(outcome(result))}"

        assert Enum.count(reads, &(&1 == {:reached, ref})) == 1

        assert sibling_succeeded?(unquote(edge), reads, ref),
               "the earlier sibling read did not succeed"

        assert survivors(ctx) == before

        refute refused_on?(result, field),
               "#{inspect(resource)}.#{field}: a read error was relabelled as absence"

        assert match?({:error, _}, result) and
                 action_returned(injected, resource) in leaves(elem(result, 1)),
               "#{inspect(resource)}.#{field}: the injected leaf is not in #{inspect(outcome(result))}"
      end
    end
  end

  describe "D6: the provenance digest at each action" do
    test "a missing, nil or non-string digest is refused at the input of each action, writing nothing",
         ctx do
      calls = valid_calls(ctx)
      before = survivors(ctx)

      for {resource, attrs} <- calls,
          {label, change} <- [
            missing: &Map.delete(&1, :seed_provenance_sha256),
            nil: &Map.put(&1, :seed_provenance_sha256, nil),
            integer: &Map.put(&1, :seed_provenance_sha256, 123),
            list: &Map.put(&1, :seed_provenance_sha256, [@digest])
          ] do
        result = seed_prototype(resource, change.(attrs), ctx.actor)

        assert refused_on?(result, :seed_provenance_sha256),
               "#{inspect(resource)} #{label}: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end

    # Pinned at EACH action (Codex 683a74e6): the non-string values first
    # (refused at the input today), then every wrong-shape string, never
    # trimmed or coerced (GREEN: trim? false and \A[0-9a-f]{64}\z).
    for resource <- [IcpDefinition, Sequence, SequenceStep, Campaign] do
      test "#{inspect(resource)}: a non-string or wrong-shape digest is refused, never trimmed or coerced, writing nothing",
           ctx do
        resource = unquote(resource)
        {^resource, attrs} = List.keyfind(valid_calls(ctx), resource, 0)
        before = survivors(ctx)

        shapes = [
          integer: 123,
          list: [@digest],
          short_63: String.slice(@digest, 0, 63),
          long_65: @digest <> "0",
          uppercase: String.upcase(@digest),
          non_hex: String.duplicate("g", 64),
          leading_space: " " <> @digest,
          trailing_space: @digest <> " ",
          trailing_newline: @digest <> "\n",
          leading_newline: "\n" <> @digest,
          prefixed: "0x" <> String.slice(@digest, 0, 62),
          half: String.slice(@digest, 0, 32)
        ]

        for {label, digest} <- shapes do
          result =
            seed_prototype(resource, Map.put(attrs, :seed_provenance_sha256, digest), ctx.actor)

          assert refused_on?(result, :seed_provenance_sha256),
                 "#{inspect(resource)} #{label}: #{inspect(outcome(result))}"
        end

        assert survivors(ctx) == before
      end
    end

    test "each action records exactly one creation event with the validated digest, as the delegation",
         ctx do
      icp = created!(seed_prototype(IcpDefinition, icp_attrs(), ctx.actor), "the ICP")
      sequence = created!(seed_prototype(Sequence, sequence_attrs(), ctx.actor), "the sequence")

      step =
        created!(seed_prototype(SequenceStep, step_attrs(sequence.id), ctx.actor), "the step")

      campaign =
        created!(
          seed_prototype(Campaign, campaign_attrs(icp.id, sequence.id), ctx.actor),
          "the campaign"
        )

      for {row, {resource, _table, type}} <- Enum.zip([icp, sequence, step, campaign], @created) do
        assert [event] =
                 Enum.filter(events_of_type(ctx.tenant, type), &(&1.subject_id == row.id))

        assert {event.action, event.subject_resource, event.tenant_id} ==
                 {"seed_prototype", inspect(resource), ctx.tenant.id}

        assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
        assert event.payload["arguments"] == %{"seed_provenance_sha256" => @digest}
      end
    end
  end

  describe "policy" do
    test "a previously resolved operator that no longer resolves (live binding drift) is Forbidden on all four, writing nothing",
         ctx do
      calls = valid_calls(ctx)
      before = survivors(ctx)
      assert SdrAgent.Prototype.operator_actor(ctx.actor.id) == {:ok, ctx.actor}
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1})

      try do
        refute SdrAgent.Prototype.operator_actor(ctx.actor.id) == {:ok, ctx.actor}

        for {resource, attrs} <- calls do
          result = seed_prototype(resource, attrs, ctx.actor)
          assert forbidden?(result), "stale on #{inspect(resource)}: #{inspect(outcome(result))}"
        end
      after
        :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})
      end

      assert survivors(ctx) == before
    end

    test "forged, foreign and non-operator callers are Forbidden on all four, writing nothing",
         ctx do
      calls = valid_calls(ctx)
      before = survivors(ctx)

      for {label, actor} <- [
            forged_delegation: %{ctx.actor | id: Ecto.UUID.generate()},
            foreign_tenant: %{ctx.actor | tenant_id: Ecto.UUID.generate()},
            seeder: seeder(ctx),
            agent_runtime: SdrAgent.Actor.system(:agent_runtime, ctx.tenant.id)
          ],
          {resource, attrs} <- calls do
        result = seed_prototype(resource, attrs, actor)
        assert forbidden?(result), "#{label} on #{inspect(resource)}: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end

    test "ordinary runtime refuses the operator on all four, writing nothing", ctx do
      calls = valid_calls(ctx)
      before = survivors(ctx)
      :ok = SdrAgent.PrototypeFixtures.leave_runtime()

      for {resource, attrs} <- calls do
        result = seed_prototype(resource, attrs, ctx.actor)
        assert forbidden?(result), "#{inspect(resource)}: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end

    test "the seeder's ordinary :seed actions are unchanged", ctx do
      icp = seeder_icp!(ctx)
      sequence = seeder_sequence!(ctx)

      step =
        Sales.seed_sequence_step(
          %{
            sequence_id: sequence.id,
            position: 1,
            channel: :email,
            delay_days: 0,
            instructions: "x"
          },
          actor: seeder(ctx)
        )

      assert match?({:ok, %SequenceStep{}}, step), "the seeder step: #{inspect(outcome(step))}"

      campaign =
        Sales.seed_campaign(
          %{
            name: "Seeded campaign " <> unique(),
            icp_definition_id: icp.id,
            sequence_id: sequence.id,
            footer_template_version: "footer/1"
          },
          actor: seeder(ctx)
        )

      assert match?({:ok, %Campaign{}}, campaign),
             "the seeder campaign: #{inspect(outcome(campaign))}"
    end

    test "an admin's ordinary :create is unchanged, in ordinary runtime", ctx do
      :ok = SdrAgent.PrototypeFixtures.leave_runtime()
      admin = new_human(:admin, ctx.tenant)

      result =
        Sales.create_icp_definition(
          %{name: "Admin ICP " <> unique(), description: "x", criteria: %{industries: ["x"]}},
          actor: admin
        )

      assert match?({:ok, %IcpDefinition{}}, result), "the admin ICP: #{inspect(outcome(result))}"
    end

    test "the operator gains no other Sales permission", ctx do
      icp = seeder_icp!(ctx)

      assert forbidden?(
               Sales.create_icp_definition(
                 %{
                   name: "Operator ICP " <> unique(),
                   description: "x",
                   criteria: %{industries: ["x"]}
                 },
                 actor: ctx.actor
               )
             )

      assert forbidden?(Sales.update(icp, :update, %{description: "y"}, actor: ctx.actor))
      assert forbidden?(Sales.update(icp, :activate, %{}, actor: ctx.actor))

      listed = Sales.list_records(IcpDefinition, actor: ctx.actor)

      assert listed == {:ok, []} or forbidden?(listed),
             "the operator read #{inspect(outcome(listed))}"
    end
  end
end
