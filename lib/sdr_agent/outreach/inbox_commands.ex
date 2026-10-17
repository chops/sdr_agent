defmodule SdrAgent.Outreach.InboxCommands do
  @moduledoc """
  Source-owned atomic Home approve-for-capture, edit and reject commands.
  A current human session and exact displayed binding are revalidated after
  enrollment/share, draft/update, campaign/share and contact/share locks,
  before the existing guarded source action acquires the audit head.
  Adds no policy bypass, result release, delivery or retry authority.
  """

  require Ash.Query

  alias Ash.Error.Forbidden
  alias SdrAgent.Accounts
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Inbox.Binding
  alias SdrAgent.Inbox.Command
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Repo
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.CampaignEnrollment
  alias SdrAgent.Sales.Contact

  @actions [:approve_capture, :edit_draft, :reject_draft]
  @draft_locks [:id, :tenant_id, :enrollment_id, :campaign_id, :recipient_contact_id]

  @doc "Execute one exact typed draft command as the current stored session, never a supplied actor."
  def execute(token, input) do
    with {:ok, actor} <- operator(token),
         {:ok, command} <- Command.parse(input),
         :ok <- draft_action(command),
         :ok <- permitted(actor, command),
         {:ok, peek} <- peek(actor, command.source_id) do
      transaction(token, actor, peek, command)
    end
    |> outcome()
  rescue
    _ -> Command.error(:producer_error)
  catch
    _, _ -> Command.error(:producer_error)
  end

  defp transaction(token, actor, peek, command) do
    Audit.transaction(fn ->
      with {:ok, _} <- lock(CampaignEnrollment, peek.enrollment_id, actor, "FOR SHARE"),
           {:ok, draft} <- lock(Draft, peek.id, actor, :for_update),
           :ok <- same_enrollment(draft, peek),
           {:ok, _} <- lock(Campaign, draft.campaign_id, actor, "FOR SHARE"),
           {:ok, _} <- lock(Contact, draft.recipient_contact_id, actor, "FOR SHARE"),
           {:ok, fresh} <- operator(token),
           true <- same_actor?(actor, fresh) or Command.error(:forbidden),
           :ok <- permitted(fresh, command),
           {:ok, source} <- Outreach.get_inbox_draft(fresh, draft.id),
           {:ok, secret} <- secret(),
           :ok <- binding(source, fresh, command, secret),
           :ok <- admission(source, command.action_id),
           {:ok, result} <- mutate(source.draft, command, fresh) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp operator(token) do
    case Accounts.current_operator(token) do
      {:ok, actor} -> {:ok, actor}
      :error -> Command.error(:forbidden)
    end
  end

  defp draft_action(%{action_id: action}) when action in @actions, do: :ok
  defp draft_action(_), do: Command.error(:invalid_input)

  defp permitted(actor, command) do
    {resource, action} = action(command.action_id)
    meta = %{resource: resource, action: action, subject_id: command.source_id, guarded?: true}

    Guard.run(meta, actor, fn ->
      if actor.role in [:admin, :reviewer],
        do: :ok,
        else: {:error, Forbidden.exception([])}
    end)
  end

  defp action(:approve_capture), do: {Approval, :approve}
  defp action(:reject_draft), do: {Approval, :reject}
  defp action(:edit_draft), do: {Draft, :edit}

  defp peek(actor, id) do
    Draft
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select(@draft_locks)
    |> Ash.read_one()
    |> readable()
  end

  defp lock(resource, id, actor, strength) do
    fields = if resource == Draft, do: @draft_locks, else: [:id, :tenant_id]

    resource
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select(fields)
    |> Ash.Query.lock(strength)
    |> Ash.read_one()
    |> readable()
  end

  defp readable({:ok, nil}), do: Command.error(:not_found)
  defp readable({:error, %Forbidden{}}), do: Command.error(:not_found)
  defp readable(result), do: result

  defp same_enrollment(%{enrollment_id: id}, %{enrollment_id: id}), do: :ok
  defp same_enrollment(_, _), do: Command.error(:producer_error)
  defp same_actor?(a, b), do: a.id == b.id and a.tenant_id == b.tenant_id

  defp secret do
    config = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])

    case config[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 20 -> {:ok, secret}
      _ -> Command.error(:producer_error)
    end
  end

  defp binding(source, actor, command, secret) do
    identity = Binding.draft_identity(actor, source.draft.id)
    revision = source.revision
    args = command.args

    cond do
      source.draft.status != :pending_review ->
        Command.error(:stale, %{change: :lifecycle})

      args.draft_revision_id != revision.id or
          args.content_sha256 != Base.encode16(revision.content_sha256, case: :lower) ->
        Command.error(:stale, %{change: :revision})

      args.recipient_email != to_string(source.contact.email) ->
        Command.error(:stale, %{change: :recipient})

      command.item_id != Binding.fingerprint({:item, identity}, secret) ->
        Command.error(:stale)

      command.expected_freshness_token !=
          Binding.fingerprint({:freshness, identity, Binding.draft_facts(source)}, secret) ->
        Command.error(:stale, %{change: :lifecycle})

      true ->
        :ok
    end
  end

  # Only capture admission needs reachable/non-suppressed/open. Exact
  # safe edits and rejections retain their existing source action policy.
  defp admission(source, :approve_capture) do
    cond do
      source.contact.status != :active -> blocked(:recipient_inactive)
      source.suppression_refs != [] -> blocked(:recipient_suppressed)
      source.campaign.status in [:completed, :archived] -> blocked(:campaign_closed)
      true -> :ok
    end
  end

  defp admission(_, _), do: :ok
  defp blocked(reason), do: Command.error(:blocked, %{blocked_reason: reason})

  defp mutate(draft, %{action_id: :approve_capture, args: args}, actor),
    do:
      Outreach.approve(
        draft,
        Map.take(args, [:draft_revision_id, :content_sha256, :recipient_email]),
        actor: actor
      )

  defp mutate(draft, %{action_id: :reject_draft, args: args}, actor),
    do:
      Outreach.reject(draft, Map.take(args, [:draft_revision_id, :content_sha256, :reason]),
        actor: actor
      )

  defp mutate(draft, %{action_id: :edit_draft, args: args}, actor),
    do:
      Outreach.edit_draft(draft, Map.take(args, [:subject, :body_text, :angle, :cta]),
        actor: actor
      )

  defp outcome({:ok, _}), do: {:ok, %{outcome: :applied, refresh?: true}}

  defp outcome({:error, %{reason: reason} = error})
       when map_size(error) == 1 and
              reason in [
                :stale,
                :forbidden,
                :not_found,
                :blocked,
                :invalid_input,
                :producer_error
              ],
       do: {:error, error}

  defp outcome({:error, %{reason: :stale, change: change} = error})
       when map_size(error) == 2 and
              change in [:revision, :recipient, :lifecycle, :recovery_guard],
       do: {:error, error}

  defp outcome({:error, %{reason: :blocked, blocked_reason: reason} = error})
       when map_size(error) == 2 and
              reason in [:recipient_inactive, :recipient_suppressed, :campaign_closed],
       do: {:error, error}

  defp outcome({:error, :real_data_disabled}), do: blocked(:real_data_disabled)
  defp outcome({:error, :withheld}), do: blocked(:witness_withheld)
  defp outcome({:error, :not_found}), do: Command.error(:not_found)
  defp outcome({:error, %Forbidden{}}), do: Command.error(:forbidden)
  defp outcome({:error, %Ash.Error.Invalid{}}), do: Command.error(:invalid_input)
  defp outcome(_), do: Command.error(:producer_error)
end
