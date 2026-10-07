defmodule SdrAgentWeb.ConsoleData do
  @moduledoc """
  Read composition for the operator console: joins of public domain reads
  (`SdrAgent.Sales`, `SdrAgent.Outreach`, `SdrAgent.Agents`) that several
  views share, always as the scope's user (tenant-scoped by the domain).
  No Repo access and no resource internals: only the domains' `fetch/3`,
  `list_records/2` and named query functions.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgentWeb.Scope

  @doc "`resource` rows (Sales or Outreach) keyed by id."
  @spec index(Scope.t(), module(), keyword()) ::
          {:ok, %{String.t() => struct()}} | {:error, term()}
  def index(%Scope{} = scope, resource, filter \\ []) do
    with {:ok, rows} <- domain(resource).list_records(resource, filter: filter, actor: scope.user) do
      {:ok, Map.new(rows, &{&1.id, &1})}
    end
  end

  @doc "The current revisions of `drafts`, keyed by revision id."
  @spec current_revisions(Scope.t(), [struct()]) :: {:ok, map()} | {:error, term()}
  def current_revisions(%Scope{} = scope, drafts) do
    drafts
    |> Enum.map(& &1.current_revision_id)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn id, {:ok, acc} ->
      case Outreach.fetch(Outreach.DraftRevision, id, actor: scope.user) do
        {:ok, revision} -> {:cont, {:ok, Map.put(acc, id, revision)}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  The console path of a Failure's subject (lead, draft, the draft of a
  delivery, the lead of an agent run), or nil when the console has no page
  for it.
  """
  @spec subject_path(Scope.t(), map()) :: String.t() | nil
  def subject_path(%Scope{} = scope, %{subject_resource: resource, subject_id: id}) do
    case resource do
      "SdrAgent.Sales.Lead" -> "/leads/#{id}"
      "SdrAgent.Outreach.Draft" -> "/drafts/#{id}"
      "SdrAgent.Outreach.DeliveryOperation" -> delivery_path(scope, id)
      "SdrAgent.Agents.AgentRun" -> run_path(scope, id)
      _ -> nil
    end
  end

  defp delivery_path(scope, id) do
    case Outreach.fetch(Outreach.DeliveryOperation, id, actor: scope.user) do
      {:ok, delivery} -> "/drafts/#{delivery.draft_id}"
      _ -> nil
    end
  end

  defp run_path(scope, id) do
    case Agents.get_run(id, actor: scope.user) do
      {:ok, %{lead_id: lead_id}} when is_binary(lead_id) -> "/leads/#{lead_id}"
      _ -> nil
    end
  end

  @doc "\"First Last\" of a contact."
  def contact_name(nil), do: "Unknown contact"
  def contact_name(contact), do: "#{contact.first_name} #{contact.last_name}"

  defp domain(resource) do
    case Module.split(resource) do
      ["SdrAgent", "Sales" | _] -> Sales
      ["SdrAgent", "Outreach" | _] -> Outreach
    end
  end
end
