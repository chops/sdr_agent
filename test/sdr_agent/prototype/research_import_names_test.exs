defmodule SdrAgent.Prototype.ResearchImportNamesTest do
  @moduledoc """
  The Research code-interface names of the D-237 dossier import (interfaces
  r6 IF-6; supplement 1 R9): `SdrAgent.Research.record_dossier_entry/2` and
  `record_dossier_source/2` exist and refuse every actor but the resolved
  prototype operator (an admin, an agent runtime and no actor, in
  prototype runtime). The import actions' bodies, and the operator's
  successful import, are S3's (`SdrAgent.Prototype.DossierImport`).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Research

  @names [:record_dossier_entry, :record_dossier_source]

  test "both names are exported by the Research domain" do
    assert Code.ensure_loaded?(Research)

    for name <- @names do
      assert function_exported?(Research, name, 2), "Research.#{name}/2 is missing"
    end
  end

  test "both names refuse every actor but the operator, writing nothing" do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)

    count = fn table ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      n
    end

    before = {count.("dossier_entries"), count.("dossier_sources")}

    for name <- @names,
        {actor_name, actor} <- [
          admin: admin,
          agent_runtime: system_actor(:agent_runtime, fx.tenant),
          nil: nil
        ] do
      result = apply(Research, name, [%{}, [actor: actor]])

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "#{name} by #{actor_name}: expected Forbidden, got #{inspect(result)}"
    end

    assert {count.("dossier_entries"), count.("dossier_sources")} == before
  end

  test "the import shells write nothing for a valid operator until S3's bodies land" do
    fx = bound!()

    count = fn table ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      n
    end

    before = {count.("dossier_entries"), count.("dossier_sources")}

    for name <- @names do
      result = apply(Research, name, [%{}, [actor: fx.actor]])
      assert match?({:error, _}, result), "#{name} by the operator wrote: #{inspect(result)}"
    end

    assert {count.("dossier_entries"), count.("dossier_sources")} == before
  end
end
