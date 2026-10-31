defmodule SdrAgent.Actor do
  @moduledoc """
  A non-human (system) actor: the identity under which background code calls
  domain actions (ADR-0009 "Roles and actors").

  Human operators are `SdrAgent.Accounts.User`s with a `role`; system actors
  are never users. Every system actor carries the `tenant_id` it acts for, so
  tenant-owned rows and audit events are attributed to the right chain.

  Types (S2 actor legend):

    * `:agent_runtime` (AGT) — Jido actions of the SDR agent
    * `:model_runtime` (MRT) — the model server's runtime: completes, fails
      or blocks a model profile switch (C2-02a), and nothing else
    * `:delivery_worker` (DLV), `:reconciler` (REC), `:webhook_ingestor` (WHK),
      `:scheduler` (SCH), `:anchorer` (ANC)
    * `:auditor_cli` (AUD) — read-only verify/export CLI
    * `:kernel` (KRN) — boot-time registration and the audit kernel itself
    * `:seeder` (SEED) — `:dev`/`:test` fixtures only
    * `:prototype_operator` (OPR) — the D-237 prototype operator: one
      agent session's `PrototypeDelegation`, whose id is the actor id; it is
      authority only when `SdrAgent.Prototype.operator_actor/1` resolves it
      against the live binding (never by the struct alone)
    * `:mac_worker` (MAC) — an enrolled off-host executor (S-B2,
      `SdrAgent.Operations.MacWorker`): built only inside
      `SdrAgent.Agents.RemoteCalls` after a token digest match, and granting
      nothing by itself (every remote-call write also needs the RemoteCalls
      scope)
  """

  @types [
    :agent_runtime,
    :model_runtime,
    :delivery_worker,
    :reconciler,
    :webhook_ingestor,
    :scheduler,
    :anchorer,
    :auditor_cli,
    :kernel,
    :seeder,
    :prototype_operator,
    :mac_worker
  ]

  @enforce_keys [:type]
  defstruct [:type, :id, :tenant_id]

  @type type ::
          :agent_runtime
          | :model_runtime
          | :delivery_worker
          | :reconciler
          | :webhook_ingestor
          | :scheduler
          | :anchorer
          | :auditor_cli
          | :kernel
          | :seeder
          | :prototype_operator
          | :mac_worker

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
