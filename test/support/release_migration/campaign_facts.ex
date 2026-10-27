defmodule SdrAgent.ReleaseMigration.CampaignFacts do
  @moduledoc """
  The release-migration campaign driver's decision core (C2* slice S3;
  Codex 599d9bcd rulings 1-5 and "driver authoring scope"), pure. The
  private, pinned one-attempt driver observes; this module decides. Its
  stubbed contract is `SdrAgent.Agents.ReleaseCampaignFactsTest`.

  **Inputs** (both written by the driver, both strict):

    * the observations, one `key=value` line each, every key exactly once
      (`parse_observations/1`): the three predeclared suffixes; whether the
      test command was launched and whether a signal interrupted the run;
      the driver's own evidence state; its suite verdict and the exact
      `Result:` line; for each parent-pair member its own exclusive CREATE
      outcome and its own disposal outcome; for DB #1 and DB #2 whether the
      harness evidence directory exists, the verified state of the harness
      export and the driver's post-run exact-name catalog read;
    * the test's published `RM-RECEIPT <targets|db1|db2>.<key>=<value>`
      lines (`parse_receipts/1`): a repeated key, an unknown prefix or any
      other line is malformed.

  **Four records, from positive evidence only** (`derive/3`), always in pin
  order (parent, its `_demo`, DB #1, DB #2) and checked by
  `exact_targets!/2`:

    * a parent-pair member is owned only after the driver's own CREATE
      succeeded (`created`); `collision` (42P04) is foreign; an unknown
      CREATE outcome is unknown ownership; it is dropped only with the
      driver's accepted drain, plain DROP and proven absence, retained only
      with presence proven after a refused or failed drop, and uncertain
      otherwise (absent before the driver's drop included: nothing in the
      campaign drops it);
    * a harness target is owned only with its receipt `child.claim=exit:0`
      (the claim child's exclusive create); `exit:3` is foreign; `exit:4`
      or `not_started` is not ownership; any other claim outcome is
      unknown. No evidence directory means the harness never reached its
      claim (the evidence claim precedes the folder and the database
      claim). Owned and absent is dropped only with the strict v2 drop
      receipts (`drop_result=ok`, `drop_receipt=valid`, `drop_protocol=2`,
      `blocking_before_drop=0`, `database_absent_after_drop=true`); owned
      and present is retained after a typed failure and uncertain after an
      unconfirmed child; truncated, missing or substituted receipts, an
      unknown catalog read, or receipts that say dropped against a present
      catalog are uncertain. A retrospective absence never proves
      ownership, and a filtered subset never succeeds.

  **The exit** is `SdrAgent.ReleaseMigration.CampaignExit.classify/1` of
  those facts; the test outcome, the evidence state and every record stay
  apart. **The lease plan** (`lease_plan/1`): with `leases: :keep` every
  lease is kept (uncertain); otherwise the capacity and root leases (both
  database-job slots, `heavy`, the two roots) are released, each name
  reservation is released only for a target `dropped` or `not_created`,
  kept as a collision marker for a `foreign` one and kept quarantined for
  a `retained` or `uncertain` one, and the campaign lease is released only
  when every name reservation is. Releasing execution resources never
  clears a collision marker or authorizes touching that database.
  """

  alias SdrAgent.ReleaseMigration.CampaignExit

  @parent_suffix ~r/\A_rm[0-9a-f]{10}\z/
  @target_suffix ~r/\A_wm[0-9a-f]{10}\z/
  @creates [:not_attempted, :created, :collision, :unknown]
  @disposals [:none, :dropped, :retained, :absent, :uncertain, :not_attempted]
  @closed %{
    "launch" => [:not_run, :launched],
    "interrupted" => [:no, :yes],
    "driver_evidence" => [:ok, :failed],
    "suite" => [:pass, :fail, :incomplete, :not_run],
    "parent.create" => @creates,
    "parent.disposal" => @disposals,
    "parent_demo.create" => @creates,
    "parent_demo.disposal" => @disposals,
    "db1.evidence_dir" => [:absent, :present],
    "db1.export" => [:sealed_verified, :unsealed, :mismatch, :missing],
    "db1.catalog" => [:absent, :present, :unknown],
    "db2.evidence_dir" => [:absent, :present],
    "db2.export" => [:sealed_verified, :unsealed, :mismatch, :missing],
    "db2.catalog" => [:absent, :present, :unknown]
  }
  @free ~w(pin.parent_suffix pin.db1_suffix pin.db2_suffix result_line)
  @pass_line "Result: 3 passed"
  @receipt ~r/\ARM-RECEIPT (targets|db1|db2)\.([a-z0-9_.]{1,80})=(\S{0,200})\z/
  @capacity ~w(root:new root:old slot1 slot2 heavy)

  @doc """
  The four exact names from the three predeclared suffixes (`parent`:
  `_rm<10 hex>`; `db1`, `db2`: `_wm<10 hex>`, distinct): `{:ok, %{parent:,
  parent_demo:, db1:, db2:}}` or `{:error, reason}` (`{:invalid_suffix,
  key}`, `:targets_identical`, `:invalid_pins`).
  """
  def pins(%{parent: parent, db1: db1, db2: db2} = suffixes) when map_size(suffixes) == 3 do
    cond do
      not suffix?(parent, @parent_suffix) -> {:error, {:invalid_suffix, :parent}}
      not suffix?(db1, @target_suffix) -> {:error, {:invalid_suffix, :db1}}
      not suffix?(db2, @target_suffix) -> {:error, {:invalid_suffix, :db2}}
      db1 == db2 -> {:error, :targets_identical}
      true -> {:ok, names(parent, db1, db2)}
    end
  end

  def pins(_other), do: {:error, :invalid_pins}

  defp suffix?(value, shape), do: is_binary(value) and Regex.match?(shape, value)

  defp names(parent, db1, db2) do
    %{
      parent: "sdr_agent_test" <> parent,
      parent_demo: "sdr_agent_test" <> parent <> "_demo",
      db1: "sdr_agent_test" <> db1,
      db2: "sdr_agent_test" <> db2
    }
  end

  @doc """
  Parses the driver's observations (`key=value` lines; see the module
  documentation): `{:ok, observations}` or `{:error, reason}` for a line
  that is not `key=value`, an unknown or repeated key, a value outside its
  closed set, or a missing key.
  """
  def parse_observations(text) when is_binary(text) do
    with {:ok, pairs} <- observation_pairs(lines(text)),
         :ok <- complete(pairs) do
      {:ok, observations(Map.new(pairs))}
    end
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.reject(&(&1 == ""))

  defp observation_pairs(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, pairs} ->
      case observation_pair(line) do
        {:ok, pair} -> add_pair(pair, pairs)
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp add_pair({key, _value} = pair, pairs) do
    if List.keymember?(pairs, key, 0),
      do: {:halt, {:error, {:repeated, key}}},
      else: {:cont, {:ok, [pair | pairs]}}
  end

  defp observation_pair(line) do
    with [_, key, value] <- Regex.run(~r/\A([a-z0-9_.]{1,40})=([ -~]{1,200})\z/, line),
         {:ok, parsed} <- observation_value(key, value) do
      {:ok, {key, parsed}}
    else
      nil -> {:error, {:not_key_value, line}}
      {:error, _} = error -> error
    end
  end

  defp observation_value(key, value) when key in @free, do: {:ok, value}

  defp observation_value(key, value) do
    case Map.fetch(@closed, key) do
      {:ok, atoms} ->
        case Enum.find(atoms, &(Atom.to_string(&1) == value)) do
          nil -> {:error, {:out_of_set, key}}
          atom -> {:ok, atom}
        end

      :error ->
        {:error, {:unknown_key, key}}
    end
  end

  defp complete(pairs) do
    case (Map.keys(@closed) ++ @free) -- Enum.map(pairs, &elem(&1, 0)) do
      [] -> :ok
      [key | _] -> {:error, {:missing, key}}
    end
  end

  defp observations(o) do
    %{
      suffixes: %{
        parent: o["pin.parent_suffix"],
        db1: o["pin.db1_suffix"],
        db2: o["pin.db2_suffix"]
      },
      launch: o["launch"],
      interrupted: o["interrupted"] == :yes,
      driver_evidence: o["driver_evidence"],
      suite: o["suite"],
      result_line: o["result_line"],
      parent: %{create: o["parent.create"], disposal: o["parent.disposal"]},
      parent_demo: %{create: o["parent_demo.create"], disposal: o["parent_demo.disposal"]},
      db1: harness_observation(o, "db1"),
      db2: harness_observation(o, "db2")
    }
  end

  defp harness_observation(o, prefix) do
    %{
      evidence_dir: o[prefix <> ".evidence_dir"],
      export: o[prefix <> ".export"],
      catalog: o[prefix <> ".catalog"]
    }
  end

  @doc """
  Parses the test's published receipt lines: `{:ok, %{"targets" => map,
  "db1" => map, "db2" => map}}` (each map `key => value`), or `{:error,
  reason}` for any line that is not exactly `RM-RECEIPT
  <targets|db1|db2>.<key>=<value without spaces>` or a repeated key.
  """
  def parse_receipts(text) when is_binary(text) do
    text
    |> lines()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{"targets" => %{}, "db1" => %{}, "db2" => %{}}}, &receipt/2)
  end

  defp receipt({line, n}, {:ok, acc}) do
    case Regex.run(@receipt, line) do
      [_, prefix, key, value] ->
        if Map.has_key?(acc[prefix], key),
          do: {:halt, {:error, {:repeated, prefix <> "." <> key}}},
          else: {:cont, {:ok, put_in(acc, [prefix, key], value)}}

      nil ->
        {:halt, {:error, {:malformed_line, n}}}
    end
  end

  @doc """
  The whole decision from the driver's two text files: the parsed
  observations and pins, the four records, the classification and the
  lease plan (`classify/3`), or `{:error, reason}` for unusable
  observations (the driver then keeps every lease).
  """
  def classify_text(observations_text, receipts_text) do
    with {:ok, observations} <- parse_observations(observations_text),
         {:ok, pins} <- pins(observations.suffixes) do
      classify(pins, observations, parse_receipts(receipts_text))
    end
  end

  @doc """
  `CampaignExit.classify/1` of `derive/3`'s facts, after `exact_targets!/2`,
  with the lease plan under `:plan`.
  """
  def classify(pins, observations, receipts) do
    facts = derive(pins, observations, receipts)
    :ok = exact_targets!(pins, facts.targets)
    result = CampaignExit.classify(facts)
    Map.put(result, :plan, lease_plan(result))
  end

  @doc """
  The classifier's facts (`effects`, `test`, `evidence`, `targets`) from
  the observations and the parsed receipts (`{:ok, map}` or `{:error, _}`):
  exactly four records in pin order. See the module documentation.
  """
  def derive(pins, observations, receipts) do
    published = with {:ok, map} <- receipts, do: map
    {db1, db1_issues} = harness_target(pins.db1, "db1", observations.db1, published)
    {db2, db2_issues} = harness_target(pins.db2, "db2", observations.db2, published)

    targets = [
      driver_target(pins.parent, observations.parent),
      driver_target(pins.parent_demo, observations.parent_demo),
      db1,
      db2
    ]

    %{
      effects: effects?(observations, targets),
      test: test_outcome(observations),
      evidence: evidence(observations, published, db1_issues ++ db2_issues),
      targets: targets
    }
  end

  defp record(database, owned, disposition),
    do: %{database: database, owned: owned, disposition: disposition}

  defp driver_target(name, %{create: :not_attempted}), do: record(name, false, :not_created)
  defp driver_target(name, %{create: :collision}), do: record(name, false, :foreign)
  defp driver_target(name, %{create: :unknown}), do: record(name, :unknown, :uncertain)

  defp driver_target(name, %{create: :created, disposal: :dropped}),
    do: record(name, true, :dropped)

  defp driver_target(name, %{create: :created, disposal: :retained}),
    do: record(name, true, :retained)

  defp driver_target(name, %{create: :created}), do: record(name, true, :uncertain)

  # No evidence directory: the harness never reached its evidence claim,
  # which precedes its folder and its database claim.
  defp harness_target(name, prefix, %{evidence_dir: :absent} = observed, published) do
    claimed? = is_map(published) and Map.has_key?(published[prefix], "child.claim")

    if claimed?,
      do: {record(name, :unknown, :uncertain), [:inconsistent]},
      else: {record(name, false, unclaimed(observed.catalog)), []}
  end

  defp harness_target(name, _prefix, _observed, {:error, _reason}),
    do: {record(name, :unknown, :uncertain), [:inconsistent]}

  defp harness_target(name, prefix, observed, published) do
    receipts = published[prefix]

    cond do
      not Map.has_key?(receipts, "outcome") ->
        {record(name, :unknown, :uncertain), [:incomplete]}

      receipts["target_database"] != name or substituted?(published, prefix, name) ->
        {record(name, :unknown, :uncertain), [:inconsistent]}

      true ->
        claimed(name, receipts, observed.catalog)
    end
  end

  defp substituted?(published, prefix, name) do
    case published["targets"][prefix] do
      nil -> false
      ^name -> false
      _other -> true
    end
  end

  defp claimed(name, receipts, catalog) do
    case receipts["child.claim"] do
      nil ->
        {record(name, false, unclaimed(catalog)), []}

      "exit:0" ->
        owned(name, receipts, catalog)

      "exit:3" ->
        {record(name, false, :foreign), []}

      refused when refused in ["exit:4", "not_started"] ->
        {record(name, false, unclaimed(catalog)), []}

      _unknown ->
        {record(name, :unknown, :uncertain), []}
    end
  end

  defp unclaimed(:present), do: :foreign
  defp unclaimed(_absent_or_unknown), do: :not_created

  defp owned(name, receipts, catalog) do
    proven? = drop_proven?(receipts)

    case {catalog, proven?} do
      {:absent, true} -> {record(name, true, :dropped), []}
      {:present, true} -> {record(name, true, :uncertain), [:inconsistent]}
      {:present, false} -> {record(name, true, present_disposition(receipts)), []}
      {_absent_or_unknown, false} -> {record(name, true, :uncertain), []}
      {:unknown, true} -> {record(name, true, :uncertain), []}
    end
  end

  defp drop_proven?(receipts) do
    receipts["cleanup.drop_result"] == "ok" and receipts["cleanup.drop_receipt"] == "valid" and
      receipts["cleanup.drop_protocol"] == "2" and
      receipts["cleanup.blocking_before_drop"] == "0" and
      receipts["cleanup.database_absent_after_drop"] == "true"
  end

  defp present_disposition(receipts) do
    if receipts["cleanup.temp_folder_retained_reason"] == "unconfirmed_child",
      do: :uncertain,
      else: :retained
  end

  defp effects?(observations, targets) do
    observations.launch == :launched or
      Enum.any?(
        [observations.parent, observations.parent_demo],
        &(&1.create in [:created, :unknown])
      ) or
      Enum.any?(targets, &(&1.owned != false))
  end

  defp test_outcome(%{launch: :not_run}), do: :not_run
  defp test_outcome(%{interrupted: true}), do: :incomplete
  defp test_outcome(%{suite: :pass, result_line: @pass_line}), do: :pass
  defp test_outcome(%{suite: :fail}), do: :fail
  defp test_outcome(_other), do: :incomplete

  defp evidence(observations, published, issues) do
    exports =
      for %{evidence_dir: :present, export: export} <- [observations.db1, observations.db2],
          do: export

    cond do
      :inconsistent in issues or :mismatch in exports ->
        :inconsistent

      observations.driver_evidence == :failed or :incomplete in issues or
        Enum.any?(exports, &(&1 != :sealed_verified)) or
          targets_unpublished?(observations, published) ->
        :incomplete

      true ->
        :complete
    end
  end

  defp targets_unpublished?(%{launch: :launched}, %{"targets" => targets}),
    do: map_size(targets) == 0

  defp targets_unpublished?(_observations, _published), do: false

  @doc """
  Raises `ArgumentError` unless `records` hold exactly the four pinned names,
  one record each: a missing, extra, substituted or repeated record is
  refused. Returns `:ok`.
  """
  def exact_targets!(pins, records) when is_list(records) do
    names = Enum.map(records, & &1.database)

    unless length(records) == 4 and Enum.sort(names) == Enum.sort(Map.values(pins)) do
      raise ArgumentError,
            "campaign targets are not exactly the four pinned names: #{inspect(names)}"
    end

    :ok
  end

  @doc """
  The lease plan of a classification: one `%{resource:, action:}` per lease,
  in a fixed order (`campaign`, `name:<db>` for each target, `root:new`,
  `root:old`, `slot1`, `slot2`, `heavy`), each action `:release`,
  `:keep_uncertain`, `:keep_quarantined` or `:keep_collision`. See the
  module documentation.
  """
  def lease_plan(%{leases: :keep, targets: targets}) do
    for resource <- resources(targets), do: %{resource: resource, action: :keep_uncertain}
  end

  def lease_plan(%{targets: targets}) do
    names = for t <- targets, do: %{resource: "name:" <> t.database, action: name_action(t)}

    campaign =
      if Enum.all?(names, &(&1.action == :release)), do: :release, else: :keep_quarantined

    [%{resource: "campaign", action: campaign}] ++
      names ++ for(resource <- @capacity, do: %{resource: resource, action: :release})
  end

  defp resources(targets),
    do: ["campaign"] ++ for(t <- targets, do: "name:" <> t.database) ++ @capacity

  defp name_action(%{disposition: disposition}) when disposition in [:dropped, :not_created],
    do: :release

  defp name_action(%{disposition: :foreign}), do: :keep_collision
  defp name_action(_retained_or_uncertain), do: :keep_quarantined

  @doc """
  The classification as closed lines for the driver: `rc=`, `leases=`,
  `test=`, `evidence=`, one `target=<db> owned=<..> disposition=<..>` line
  per record, one `lease=<resource> action=<..>` line per lease, then
  `end`.
  """
  def render(%{rc: rc, leases: leases, test: test, evidence: evidence} = result) do
    ["rc=#{rc}", "leases=#{leases}", "test=#{test}", "evidence=#{evidence}"] ++
      for(
        t <- result.targets,
        do: "target=#{t.database} owned=#{t.owned} disposition=#{t.disposition}"
      ) ++
      for(l <- result.plan, do: "lease=#{l.resource} action=#{l.action}") ++ ["end"]
  end
end
