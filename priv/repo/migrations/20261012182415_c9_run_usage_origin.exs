defmodule SdrAgent.Repo.Migrations.C9RunUsageOrigin do
  @moduledoc """
  C9 (R0 readiness packet): `agent_runs.usage_origin`, nullable, so every run
  created before R0 keeps a null origin (a real reservation for such a run is
  refused). Generated with `mix ash.codegen c9_admission` and split from the
  admission migration; the drop is in `down/0` only.
  """

  use Ecto.Migration

  def up do
    alter table(:agent_runs) do
      add :usage_origin, :text
    end
  end

  def down do
    alter table(:agent_runs) do
      remove :usage_origin
    end
  end
end
