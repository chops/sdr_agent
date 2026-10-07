defmodule SdrAgent.Audit.SQL do
  @moduledoc """
  Trigger SQL used by resources' `custom_statements` (ADR-0009
  "Append-only"), so `mix ash.codegen` generates and checks the migrations.

  * `append_only/1` — rejects every `UPDATE`, `DELETE` and `TRUNCATE` on an
    APPEND-ONLY table (row trigger `<table>_guard_row`, statement trigger
    `<table>_guard_truncate`).
  * `terminal_immutable/4` — for ModelInvocation/ToolInvocation (and S8's
    Draft, Approval, DeliveryOperation): rejects
    `DELETE`/`TRUNCATE`, any update of a row whose status is terminal, and
    any update that changes a column outside the listed mutable columns.
  """

  @doc "Statements `{name, up, down}` making `table` append-only."
  def append_only(table) do
    function = """
    CREATE FUNCTION #{table}_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only: % rejected', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    END;
    $$
    """

    triggers(table, function, "#{table}_append_only")
  end

  @doc """
  Statements for a terminal-immutable table whose lifecycle column is
  `state_column` (default `"status"`; DeliveryOperation uses `"state"`).
  """
  def terminal_immutable(table, terminal_states, mutable_columns, state_column \\ "status") do
    states = Enum.map_join(terminal_states, ", ", &"'#{&1}'")
    columns = Enum.map_join(mutable_columns, ", ", &"'#{&1}'")

    function = """
    CREATE FUNCTION #{table}_terminal_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION '% is append-only: % rejected (invocations cannot be deleted)', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF OLD.#{state_column} IN (#{states}) THEN
        RAISE EXCEPTION '% row % is terminal: update rejected', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF (to_jsonb(NEW) - ARRAY[#{columns}]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[#{columns}]) THEN
        RAISE EXCEPTION '% row %: immutable column changed', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """

    triggers(table, function, "#{table}_terminal_immutable")
  end

  @doc """
  `{name, up, down}` adding a composite FK from `table.(tenant_id, column)`
  to `payloads(tenant_id, sha256)` (Ash references cover single columns).
  """
  def payload_fk(table, column) do
    constraint = "#{table}_#{column}_payload_fkey"

    {:"#{constraint}",
     "ALTER TABLE #{table} ADD CONSTRAINT #{constraint} FOREIGN KEY (tenant_id, #{column}) " <>
       "REFERENCES payloads (tenant_id, sha256) ON DELETE RESTRICT",
     "ALTER TABLE #{table} DROP CONSTRAINT #{constraint}"}
  end

  @doc "Check constraint SQL restricting `column` to `values`."
  def one_of(column, values) do
    "#{column} IN (#{Enum.map_join(values, ", ", &"'#{&1}'")})"
  end

  @doc "Check constraint SQL for the trace columns (lowercase hex, non-zero)."
  def trace_check do
    "trace_id ~ '^[0-9a-f]{32}$' AND trace_id <> repeat('0', 32) AND " <>
      "span_id ~ '^[0-9a-f]{16}$' AND span_id <> repeat('0', 16)"
  end

  defp triggers(table, function_sql, function) do
    [
      {:"#{table}_guard_function", function_sql, "DROP FUNCTION #{function}()"},
      {:"#{table}_guard_row",
       "CREATE TRIGGER #{table}_guard_row BEFORE UPDATE OR DELETE ON #{table} " <>
         "FOR EACH ROW EXECUTE FUNCTION #{function}()",
       "DROP TRIGGER #{table}_guard_row ON #{table}"},
      {:"#{table}_guard_truncate",
       "CREATE TRIGGER #{table}_guard_truncate BEFORE TRUNCATE ON #{table} " <>
         "FOR EACH STATEMENT EXECUTE FUNCTION #{function}()",
       "DROP TRIGGER #{table}_guard_truncate ON #{table}"}
    ]
  end
end
