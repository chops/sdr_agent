defmodule SdrAgent.Integrations.CRM do
  @moduledoc """
  CRM adapter behaviour (spec §17). `fetch_contact/1` returns the CRM record
  of a contact by its CRM id: `contact` and `account` field maps,
  `activities`, a stable `source_url`, a `title` and the verbatim `content`
  the agent stores as a research artifact. Write-back (`update_contact/2`,
  `record_activity/1`) is DEFERRED in S2 (CrmActivity); MVP adapters refuse
  it with `{:error, :read_only}`.
  """

  @type crm_record :: %{
          required(:source_url) => String.t(),
          required(:title) => String.t(),
          required(:content) => String.t(),
          required(:contact) => map(),
          required(:account) => map(),
          required(:activities) => [map()]
        }

  @callback fetch_contact(crm_id :: String.t()) :: {:ok, crm_record()} | {:error, :not_found}
  @callback update_contact(crm_id :: String.t(), changes :: map()) :: {:error, :read_only}
  @callback record_activity(activity :: map()) :: {:error, :read_only}
end
