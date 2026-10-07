defmodule SdrAgent.Integrations.FakeCRM do
  @moduledoc """
  Read-only CRM adapter over the demo seed (`SdrAgent.Integrations.Fixtures`).
  Deterministic and offline; write-back is DEFERRED (S2 CrmActivity) and
  refused.
  """
  @behaviour SdrAgent.Integrations.CRM

  alias SdrAgent.Integrations.Fixtures

  @impl true
  def fetch_contact(crm_id) when is_binary(crm_id) do
    case Fixtures.crm_record(crm_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def update_contact(_crm_id, _changes), do: {:error, :read_only}

  @impl true
  def record_activity(_activity), do: {:error, :read_only}
end
