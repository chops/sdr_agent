defmodule SdrAgent.Repo.AshRequiredV7Test do
  @moduledoc """
  ADR-0008 addendum (2026-10-26): the generated ash-functions version-7
  migration (`priv/repo/migrations/20261026033738_ash_functions_v7_extensions_1.exs`)
  redefines the database helper `ash_required(value anycompatible, payload jsonb)`
  in place so that a NULL value raises its `ash_error: <payload>` exception
  directly, instead of delegating to the unqualified helper `ash_raise_error/2`
  under an empty `search_path` as the 2026-10-06 initialization migration did.

  Four focused checks (Codex 01a17653, ADV-A2):

    1. a typed non-NULL input is returned unchanged;
    2. a typed NULL input raises `Postgrex.Error` with SQLSTATE P0001
       (`:raise_exception`) and the exact `ash_error: ` payload message, and the
       connection stays usable afterwards (the sandbox supplies a savepoint per
       query outside an explicit transaction; no explicit transaction is opened
       here);
    3. the installed definition carries the direct raise and no helper call, with
       the preserved signature, `STABLE` and the empty `search_path`;
    4. a serial, sandboxed version-6 → version-7 model: the exact historical
       version-6 body (extracted from the initialization migration, which is
       bound to its SHA-256) is installed and its baseline confirmed, then the
       actual tracked version-7 migration's SQL (extracted from the migration
       file, bound to its SHA-256) is applied and checks 1–3 re-asserted; the
       sandbox transaction reverts the replacement when the test ends.

  Limits: not a migration-runner upgrade/downgrade test and not an execution
  against any database but the test partition; a fresh install is proven by the
  gate's own `ash.setup` on a new partition database together with check 3.
  """
  use SdrAgent.DataCase, async: false

  @v6_migration "priv/repo/migrations/20261006212538_initialize_extensions_1.exs"
  @v6_sha256 "56555cde14069d6af791204e66a902fd9746be0034f360b4ff41b36327145adc"
  @v7_migration "priv/repo/migrations/20261026033738_ash_functions_v7_extensions_1.exs"
  @v7_sha256 "ef92569076b536f95cf984dcefaf58d31302fc4e945a8d5e11c1e0ddb1978d59"

  @payload ~s({"k":"v"})
  @expected_message ~s(ash_error: {"k": "v"})
  @select_non_null "SELECT ash_required($1::integer, $2::text::jsonb)"
  @select_null "SELECT ash_required(NULL::integer, $1::text::jsonb)"
  @select_definition "SELECT pg_get_functiondef('ash_required(anycompatible, jsonb)'::regprocedure)"

  test "a typed non-NULL value is returned unchanged" do
    assert %{rows: [[1]]} = Repo.query!(@select_non_null, [1, @payload])

    assert %{rows: [["x"]]} =
             Repo.query!("SELECT ash_required($1::text, $2::text::jsonb)", ["x", @payload])
  end

  test "a typed NULL value raises the ash_error payload exception and the connection stays usable" do
    assert_null_raises()
    assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
  end

  test "the installed definition raises directly, calls no helper, and keeps signature, STABLE and search_path" do
    assert_v7_definition(definition())
  end

  test "version 6 → version 7: the tracked migration's SQL replaces the historical body in place" do
    Repo.query!(v6_body_sql(), [])
    v6 = definition()
    assert v6 =~ "RETURN ash_raise_error(payload, value);"
    refute v6 =~ "RAISE EXCEPTION"

    Repo.query!(v7_migration_sql(), [])
    assert_v7_definition(definition())
    assert %{rows: [[1]]} = Repo.query!(@select_non_null, [1, @payload])
    assert_null_raises()
    assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
  end

  defp assert_null_raises do
    assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception, message: message}}} =
             Repo.query(@select_null, [@payload])

    assert message == @expected_message
  end

  defp assert_v7_definition(definition_text) do
    assert definition_text =~
             "CREATE OR REPLACE FUNCTION public.ash_required(value anycompatible, payload jsonb)"

    assert definition_text =~ "RETURNS anycompatible"
    assert definition_text =~ "RAISE EXCEPTION 'ash_error: %', payload::text;"
    refute definition_text =~ "ash_raise_error"
    assert definition_text =~ "STABLE"
    assert definition_text =~ ~r/SET search_path (TO|=) ''/
  end

  defp definition do
    %{rows: [[definition_text]]} = Repo.query!(@select_definition, [])
    definition_text
  end

  # The exact historical version-6 body, taken from the tracked initialization
  # migration (bound to its SHA-256), never retyped.
  defp v6_body_sql do
    assert sha256(File.read!(@v6_migration)) == @v6_sha256

    [sql] =
      @v6_migration
      |> execute_blocks()
      |> Enum.filter(&(&1 =~ "FUNCTION ash_required("))

    assert sql =~ "RETURN ash_raise_error(payload, value);"
    sql
  end

  # The actual tracked version-7 migration's SQL (bound to its SHA-256), not a
  # hand-written substitute.
  defp v7_migration_sql do
    assert sha256(File.read!(@v7_migration)) == @v7_sha256
    [sql] = execute_blocks(@v7_migration)
    assert sql =~ "RAISE EXCEPTION 'ash_error: %', payload::text;"
    sql
  end

  defp execute_blocks(file) do
    ~r/execute\("""\n(.*?)\n\s*"""\)/s
    |> Regex.scan(File.read!(file), capture: :all_but_first)
    |> List.flatten()
  end

  defp sha256(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end
end
