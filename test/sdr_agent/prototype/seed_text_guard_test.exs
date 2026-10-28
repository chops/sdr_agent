defmodule SdrAgent.Prototype.SeedTextGuardTest do
  @moduledoc """
  The content guard of the four Sales `:seed_prototype` actions of the D-237
  seed (owned debt; text-guard RED r2, Codex daf5f34e and 8e749d09 T1/T2).
  Every accepted RAW text input of a guarded field, and its stored value,
  must pass the unchanged `SdrAgent.Agents.RunSettings.ContentRules.text/1`.
  The raw input is checked before Ash's default `trim?: true` can remove an
  edge character, so a carriage return at an edge is refused, never trimmed
  away, and a raw input that casts to nil is not taken as safe.

  Guarded: IcpDefinition `name`, `description` and every string of the four
  embedded criteria lists; Sequence `name`; SequenceStep `instructions`;
  Campaign `name`, `sender_name`, `sender_email` and
  `footer_template_version`. A refusal is invalid input on that field (on
  `criteria` for a list string) whose `rule` var is the ContentRules rule;
  the presented error never carries the value. Authorization comes first:
  an unauthorized caller stays Forbidden. The guard runs before the
  ImportTenant reference read; the ordering cases prove only that the
  exact instrumented read was not reached, not that no other read or lock
  happened.

  RED stage (eca7925): no guard exists. The malformed and key-alias cases
  are created today (an edge carriage return is trimmed away first), and the
  ordering cases reach the instrumented read: each fails at its first
  assertion. The allowed-text, nil, required and authorization cases are
  controls. The invalid UTF-8 cases are discovery: their outcome today is
  classified at the run and not credited as behavioural RED.

  Synthetic `.test` data only. Every malformed value but the lone carriage
  return carries the sentinel `S3SENTINEL`, and failure messages print
  value-free outcomes only (a raise is reduced to its module).
  """
  use SdrAgent.PrototypeCase, async: false

  alias Ash.Error.Forbidden.ForbiddenField
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.IcpDefinition
  alias SdrAgent.Sales.Sequence
  alias SdrAgent.Sales.SequenceStep
  alias SdrAgent.Sales.Validations.ImportTenant

  @digest :sha256
          |> :crypto.hash("s3 text guard synthetic provenance")
          |> Base.encode16(case: :lower)
  @created [
    {IcpDefinition, "icp_definitions", "sales.icp_definition.created"},
    {Sequence, "sequences", "sales.sequence.created"},
    {SequenceStep, "sequence_steps", "sales.sequence_step.created"},
    {Campaign, "campaigns", "sales.campaign.created"}
  ]
  # {resource, target, label}: every guarded input; a criteria target is one
  # embedded list.
  @targets [
    {IcpDefinition, :name, "IcpDefinition name"},
    {IcpDefinition, :description, "IcpDefinition description"},
    {IcpDefinition, {:criteria, :industries}, "IcpDefinition criteria.industries"},
    {IcpDefinition, {:criteria, :geographies}, "IcpDefinition criteria.geographies"},
    {IcpDefinition, {:criteria, :personas}, "IcpDefinition criteria.personas"},
    {IcpDefinition, {:criteria, :triggers}, "IcpDefinition criteria.triggers"},
    {Sequence, :name, "Sequence name"},
    {SequenceStep, :instructions, "SequenceStep instructions"},
    {Campaign, :name, "Campaign name"},
    {Campaign, :sender_name, "Campaign sender_name"},
    {Campaign, :sender_email, "Campaign sender_email"},
    {Campaign, :footer_template_version, "Campaign footer_template_version"}
  ]
  # {kind, the ContentRules rule it breaks}.
  @kinds [
    bell_inside: :control_character,
    cr_leading: :control_character,
    cr_trailing: :control_character,
    secret_shaped: :secret_shaped
  ]
  @hex32 String.duplicate("a1b2", 8)
  @full [limit: :infinity, printable_limit: :infinity]

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  # The create's result, or {:raised, module}: never an exception's text.
  defp seed_prototype(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:seed_prototype, attrs, actor: actor)
    |> Ash.create()
  rescue
    error -> {:raised, error.__struct__}
  end

  defp seeder(ctx), do: SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")
  defp unique, do: Integer.to_string(System.unique_integer([:positive]))
  defp campaign_file, do: F.seed_contents()["campaign.json"]

  # Valid input of each action; the step and the campaign reference fresh
  # same-tenant seeder drafts.
  defp valid_attrs(_ctx, IcpDefinition) do
    icp = campaign_file()["icp"]

    %{
      name: icp["name"],
      description: icp["description"],
      criteria: icp["criteria"],
      seed_provenance_sha256: @digest
    }
  end

  defp valid_attrs(_ctx, Sequence),
    do: %{name: campaign_file()["sequence"]["name"], seed_provenance_sha256: @digest}

  defp valid_attrs(ctx, SequenceStep) do
    %{
      sequence_id: seeder_sequence!(ctx).id,
      instructions: campaign_file()["sequence"]["step"]["instructions"],
      seed_provenance_sha256: @digest
    }
  end

  defp valid_attrs(ctx, Campaign) do
    %{
      name: "GTMscape prototype",
      icp_definition_id: seeder_icp!(ctx).id,
      sequence_id: seeder_sequence!(ctx).id,
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

  defp field_of({:criteria, _list}), do: :criteria
  defp field_of(field), do: field

  defp put_value(attrs, {:criteria, list}, value),
    do: Map.update!(attrs, :criteria, &Map.put(&1, Atom.to_string(list), [value]))

  defp put_value(attrs, field, value), do: Map.put(attrs, field, value)

  # One defect each; an address keeps its reserved domain.
  defp malformed(:sender_email, :bell_inside), do: "S3SENTINEL\a@gtmscape.example"
  defp malformed(:sender_email, :cr_leading), do: "\rS3SENTINEL@gtmscape.example"
  defp malformed(:sender_email, :cr_trailing), do: "S3SENTINEL@gtmscape.example\r"

  defp malformed(:sender_email, :secret_shaped),
    do: "S3SENTINEL." <> @hex32 <> "@gtmscape.example"

  defp malformed(:sender_email, :invalid_utf8),
    do: <<0xFF, 0xFE>> <> "S3SENTINEL@gtmscape.example"

  defp malformed(_field, :bell_inside), do: "S3SENTINEL bell\a inside"
  defp malformed(_field, :cr_leading), do: "\rS3SENTINEL edge"
  defp malformed(_field, :cr_trailing), do: "S3SENTINEL edge\r"
  defp malformed(_field, :secret_shaped), do: "S3SENTINEL " <> @hex32
  defp malformed(_field, :invalid_utf8), do: <<0xFF, 0xFE>> <> "S3SENTINEL bytes"

  # Allowed by ContentRules: a tab and a newline, inside and at the edges.
  defp allowed(:sender_email), do: "S3ALLOWED@gtmscape.example"
  defp allowed(_field), do: "\tS3ALLOWED line one\n\tline two\n"

  defp stored(record, {:criteria, list}), do: Map.fetch!(record.criteria, list)
  defp stored(record, :sender_email), do: to_string(record.sender_email)
  defp stored(record, field), do: Map.fetch!(record, field)

  defp expected_stored({:criteria, _list}, raw), do: [String.trim(raw)]
  defp expected_stored(_field, raw), do: String.trim(raw)

  defp event_type(resource),
    do: Enum.find_value(@created, fn {r, _table, type} -> if r == resource, do: type end)

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

  defp outcome({:raised, module}), do: {:raised, module}
  defp outcome(_other), do: :unknown

  defp created!(result, label) do
    assert match?({:ok, _}, result), "#{label}: #{inspect(outcome(result))}"
    elem(result, 1)
  end

  defp refused_on?({:error, %Ash.Error.Invalid{errors: errors}}, field),
    do: Enum.any?(errors, &(Map.get(&1, :field) == field))

  defp refused_on?(_result, _field), do: false

  defp forbidden?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)

  # The `rule` var of every invalid-input error on `field`.
  defp rules({:error, %Ash.Error.Invalid{errors: errors}}, field) do
    for error <- errors, Map.get(error, :field) == field do
      error |> Map.get(:vars, []) |> Keyword.get(:rule)
    end
  end

  defp rules(_result, _field), do: :not_invalid

  # Whether the presented error (its inspection and message) carries the
  # sentinel or the exact value.
  defp leaked?(result, value) do
    text = presented(result)
    String.contains?(text, "S3SENTINEL") or String.contains?(text, inspect(value, @full))
  end

  defp presented({:error, error}) when is_exception(error),
    do: inspect(error, @full) <> "\n" <> Exception.message(error)

  defp presented(other), do: inspect(other, @full)

  # Refused as invalid input on `field` with exactly `rule`, nothing
  # written, and the presented error does not carry the value.
  defp assert_refused(ctx, resource, attrs, field, rule, value) do
    before = survivors(ctx)
    result = seed_prototype(resource, attrs, ctx.actor)

    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "not refused as invalid input: #{inspect(outcome(result))}"

    assert rules(result, field) == [rule], "rules on #{field}: #{inspect(rules(result, field))}"
    assert survivors(ctx) == before
    refute leaked?(result, value), "the presented error carries the value"
  end

  # One malformed input per action and per edge kind, with valid same-tenant
  # references.
  defp malformed_calls(ctx) do
    for {resource, field} <- [
          {IcpDefinition, :name},
          {Sequence, :name},
          {SequenceStep, :instructions},
          {Campaign, :name}
        ],
        kind <- [:bell_inside, :cr_leading] do
      {resource, put_value(valid_attrs(ctx, resource), field, malformed(field, kind))}
    end
  end

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

  # Whether the instrumented read of `ref` was reached (its seam message).
  defp reached?(ref) do
    receive do
      {ImportTenant, :reached, ^ref} -> true
    after
      0 -> false
    end
  end

  # A malformed text input with that exact reference read instrumented to
  # return an injected Forbidden (no SQL): the guard refuses first, so the
  # read is not reached.
  defp assert_text_first(ctx, resource, attrs, edge, field) do
    ref = make_ref()
    leaf = ForbiddenField.exception(resource: edge.resource, field: :s3_text_probe)
    scope = {edge, ref, {:error, Ash.Error.Forbidden.exception(errors: [leaf])}}
    before = survivors(ctx)

    result = with_fault(scope, fn -> seed_prototype(resource, attrs, ctx.actor) end)

    refute reached?(ref),
           "the #{edge.field} read was reached before the text guard: #{inspect(outcome(result))}"

    assert rules(result, field) == [:control_character],
           "rules on #{field}: #{inspect(rules(result, field))}"

    assert survivors(ctx) == before
    refute leaked?(result, Map.fetch!(attrs, field)), "the presented error carries the value"
  end

  describe "malformed raw text is refused (the live operator)" do
    for {resource, target, label} <- @targets, {kind, rule} <- @kinds do
      test "#{label}, #{kind}: refused #{rule} on the raw input, value-free, writing nothing",
           ctx do
        target = unquote(Macro.escape(target))
        value = malformed(field_of(target), unquote(kind))
        attrs = put_value(valid_attrs(ctx, unquote(resource)), target, value)

        assert_refused(ctx, unquote(resource), attrs, field_of(target), unquote(rule), value)
      end
    end

    test "IcpDefinition description, a lone carriage return: refused, never stored as nil", ctx do
      attrs = put_value(valid_attrs(ctx, IcpDefinition), :description, "\r")
      assert_refused(ctx, IcpDefinition, attrs, :description, :control_character, "\r")
    end
  end

  describe "allowed text and nil (controls)" do
    for {resource, target, label} <- @targets do
      test "#{label}: a tab and a newline are allowed; the stored value is the trimmed raw input",
           ctx do
        resource = unquote(resource)
        target = unquote(Macro.escape(target))
        raw = allowed(field_of(target))
        attrs = put_value(valid_attrs(ctx, resource), target, raw)
        type = event_type(resource)
        events_before = length(events_of_type(ctx.tenant, type))

        record = created!(seed_prototype(resource, attrs, ctx.actor), unquote(label))

        assert stored(record, target) == expected_stored(target, raw)
        assert length(events_of_type(ctx.tenant, type)) == events_before + 1
      end
    end

    test "IcpDefinition description: nil stays allowed and is stored as nil", ctx do
      attrs = put_value(valid_attrs(ctx, IcpDefinition), :description, nil)
      record = created!(seed_prototype(IcpDefinition, attrs, ctx.actor), "the ICP")
      assert record.description == nil
    end

    test "Sequence name, a lone carriage return: refused at the input as required (unchanged), writing nothing",
         ctx do
      attrs = put_value(valid_attrs(ctx, Sequence), :name, "\r")
      before = survivors(ctx)
      result = seed_prototype(Sequence, attrs, ctx.actor)

      assert refused_on?(result, :name), "not refused on name: #{inspect(outcome(result))}"
      assert survivors(ctx) == before
    end
  end

  describe "invalid UTF-8 (discovery at RED; refused invalid_utf8 at GREEN)" do
    for {resource, target, label} <- @targets do
      test "#{label}, invalid UTF-8: refused invalid_utf8, value-free, writing nothing", ctx do
        target = unquote(Macro.escape(target))
        value = malformed(field_of(target), :invalid_utf8)
        attrs = put_value(valid_attrs(ctx, unquote(resource)), target, value)

        assert_refused(ctx, unquote(resource), attrs, field_of(target), :invalid_utf8, value)
      end
    end
  end

  describe "authorization comes first (controls)" do
    test "forged, foreign and non-operator callers are Forbidden, never Invalid, for malformed text on all four",
         ctx do
      calls = malformed_calls(ctx)
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

    test "a previously resolved operator that no longer resolves is Forbidden for malformed text on all four",
         ctx do
      calls = malformed_calls(ctx)
      before = survivors(ctx)
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1})

      try do
        for {resource, attrs} <- calls do
          result = seed_prototype(resource, attrs, ctx.actor)
          assert forbidden?(result), "stale on #{inspect(resource)}: #{inspect(outcome(result))}"
        end
      after
        :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})
      end

      assert survivors(ctx) == before
    end

    test "ordinary runtime refuses the operator for malformed text on all four", ctx do
      calls = malformed_calls(ctx)
      before = survivors(ctx)
      :ok = SdrAgent.PrototypeFixtures.leave_runtime()

      for {resource, attrs} <- calls do
        result = seed_prototype(resource, attrs, ctx.actor)
        assert forbidden?(result), "#{inspect(resource)}: #{inspect(outcome(result))}"
      end

      assert survivors(ctx) == before
    end
  end

  describe "the guard precedes the ImportTenant reference read" do
    test "SequenceStep: a malformed instruction is refused before its sequence's instrumented read",
         ctx do
      attrs = valid_attrs(ctx, SequenceStep)
      attrs = put_value(attrs, :instructions, malformed(:instructions, :bell_inside))

      edge = %{
        field: :sequence_id,
        resource: Sequence,
        id: attrs.sequence_id,
        tenant_id: ctx.tenant.id
      }

      assert_text_first(ctx, SequenceStep, attrs, edge, :instructions)
    end

    test "Campaign: a malformed name is refused before its ICP's instrumented read", ctx do
      attrs = put_value(valid_attrs(ctx, Campaign), :name, malformed(:name, :bell_inside))

      edge = %{
        field: :icp_definition_id,
        resource: IcpDefinition,
        id: attrs.icp_definition_id,
        tenant_id: ctx.tenant.id
      }

      assert_text_first(ctx, Campaign, attrs, edge, :name)
    end
  end

  describe "every raw input key is checked" do
    test "Sequence name under a string key: a leading carriage return is refused", ctx do
      value = malformed(:name, :cr_leading)
      attrs = %{"name" => value, "seed_provenance_sha256" => @digest}
      assert_refused(ctx, Sequence, attrs, :name, :control_character, value)
    end

    test "Sequence name under both an atom and a string key: every raw input is checked", ctx do
      value = malformed(:name, :cr_leading)

      attrs = %{:name => "S3ALLOWED name", :seed_provenance_sha256 => @digest, "name" => value}
      assert_refused(ctx, Sequence, attrs, :name, :control_character, value)
    end
  end
end
