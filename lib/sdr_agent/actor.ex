defmodule SdrAgent.Actor do
  @moduledoc """
  A non-human (system) actor: the identity under which background code calls
  domain actions (ADR-0009 "Roles and actors").

  Human operators are `SdrAgent.Accounts.User`s with a `role`; system actors
  are never users. Every system actor carries the `tenant_id` it acts for, so
  tenant-owned rows and audit events are attributed to the right chain.

  Types (S2 actor legend):

    * `:agent_runtime` (AGT) — Jido actions of the SDR agent
    * `:delivery_worker` (DLV), `:reconciler` (REC), `:webhook_ingestor` (WHK),
      `:scheduler` (SCH), `:anchorer` (ANC)
    * `:auditor_cli` (AUD) — read-only verify/export CLI
    * `:kernel` (KRN) — boot-time registration and the audit kernel itself
    * `:seeder` (SEED) — `:dev`/`:test` fixtures only
  """

  @types [
    :agent_runtime,
    :delivery_worker,
    :reconciler,
    :webhook_ingestor,
    :scheduler,
    :anchorer,
    :auditor_cli,
    :kernel,
    :seeder
  ]

  @enforce_keys [:type]
  defstruct [:type, :id, :tenant_id]

  @type type ::
          :agent_runtime
          | :delivery_worker
          | :reconciler
          | :webhook_ingestor
          | :scheduler
          | :anchorer
          | :auditor_cli
          | :kernel
          | :seeder

  @type t :: %__MODULE__{type: type(), id: String.t() | nil, tenant_id: Ecto.UUID.t() | nil}

  @doc "All system actor types."
  @spec types() :: [type()]
  def types, do: @types

  @doc "Builds a system actor of `type` acting for `tenant_id`."
  @spec system(type(), Ecto.UUID.t() | nil, String.t() | nil) :: t()
  def system(type, tenant_id, id \\ nil) when type in @types do
    %__MODULE__{type: type, id: id || Atom.to_string(type), tenant_id: tenant_id}
  end
end
