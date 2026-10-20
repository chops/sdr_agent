defmodule SdrAgent.SDR.Admission do
  @moduledoc """
  The lead admission orchestrator behind `SdrAgent.SDR.admit_lead/2`
  (C3-02 G4; packet sections 4.1, 4.3-4.5, 5 and 6; plan r8 sections 2.6,
  6.3, 6.5 and 14). It runs inside `SdrAgent.Audit.Guard.run/3` (an
  auditor's attempt is refused and audited there) and returns
  `{:ok, %{admission, outcome, lead, run, replayed?}}` or `{:error, reason}`
  with a closed reason only.

  Steps (packet section 4.1; lock order of section 6):

    1. the actor struct must be an active human admin of a tenant
       (`:forbidden`);
    2. `source_kind: :referral` is `:use_referral_handover` (C3-03);
    3. `SdrAgent.SDR.Admission.Input.normalize/2` (`{:invalid, [field]}`);
    4. the real-data guard on the normalized domain and email
       (`real_data_permitted?/2`; `:real_data_disabled`).

  Then one `SdrAgent.Audit.transaction/1`, the application scope:

    5. one identity pass over `admission-ref` (the exact `source_ref`), the
       company domain, the email and the email's host, before any domain
       row lock or append; the requester re-read `FOR SHARE` (an active
       admin of the tenant, else `:forbidden`);
    6. the replay lookup by `(tenant, kind, ref)`, unlocked (the ref key
       serializes it): the same input hash returns the stored admission,
       its lead re-read and its run, `replayed?: true`, writing nothing; a
       different hash is `:source_ref_conflict`;
    7. the campaign `FOR SHARE`, `active` (`:campaign_not_active`);
    8. agent_found: the discovery run `FOR KEY SHARE`, of the tenant and
       origin `:discovery` (`{:invalid, [:agent_run_id]}`); the committed
       `SDRAgent` definition, read only (`SDRAgent.fetch_definition/1`;
       `:agent_definition_unavailable`); 8a, the settings pre-check for the
       server-owned origin `:assignment` (`{:settings_incomplete, kinds}`);
    9. the account by canonical domain `FOR SHARE`, the contact by email
       `FOR SHARE`, the account's open leads `FOR SHARE`; then the guard
       again on the resolved stored values (`:real_data_disabled`);
    10-15. the decision table: suppression
       (`SdrAgent.Sales.SuppressionFacts.scope/3`), contact at another
       account, archived contact or account, the contact's open lead, an
       open lead at the company, step 14a (csv, hubspot, agent_found: the
       account's most recently closed lead, `closed_at DESC NULLS LAST, id
       DESC`, one unlocked read of its status only, under the company key),
       a contact with only closed leads unless `readmit` (manual); each
       records one `LeadAdmission` row (with its `sales.admission.recorded`
       event) and nothing else;
    16. admitted: the account and the contact if new (a new company needs
       its `name`, a new person `first_name` and `last_name`:
       `{:invalid, [field]}`, nothing written), the admission row, the Lead
       (`:create` with `admission_id` and `source` = the kind, owned by the
       requester), `:assign`, and the queued run
       (`SdrAgent.SDR.Assignment.queue/2`, origin `:assignment`, no budget
       input). The run's settings snapshot is authoritative: its refusal
       rolls everything back as `{:settings_incomplete, kinds}` or
       `:settings_default_unavailable`.

  Every Sales write of the admission carries the
  `SdrAgent.Sales.Checks.LeadAdmissionContext` marker: `LeadAdmission
  :record` requires it, and under it the nested Account and Contact
  `:create` and Lead `:create`/`:assign` require the pass's keys held
  instead of taking keys. The marker grants no authorization.

  Refusals of nested writes: Ash rolls the whole transaction back with its
  error; a known closed reason (the settings snapshot's structured rule
  and kinds, `Ash.Error.Forbidden`) keeps its mapping; any other returned
  refusal is the content-free `:conflict`. Identity-key failures
  (`MissingPass`, `LateAcquisition`, `PassInconsistent`,
  `AcquisitionFailed`, `InvalidKeyValue`) are raised, never mapped: the
  admission fails closed. No refusal carries an input value.
  """

  require Ash.Query

  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Audit
  alias SdrAgent.Audit.IdentityKeys
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Checks.LeadAdmissionContext
  alias SdrAgent.Sales.LeadAdmission
  alias SdrAgent.Sales.SuppressionFacts
  alias SdrAgent.Sales.Synthetic
  alias SdrAgent.SDR.Admission.Input
  alias SdrAgent.SDR.Assignment
  alias SdrAgent.SDR.SDRAgent

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @company_kinds [:csv, :hubspot, :agent_found]
  @relationship [:converted, :nurture]
  @identity_errors [
    IdentityKeys.AcquisitionFailed,
    IdentityKeys.InvalidKeyValue,
    IdentityKeys.LateAcquisition,
    IdentityKeys.MissingPass,
    IdentityKeys.NotInTransaction,
    IdentityKeys.PassInconsistent,
    IdentityKeys.UnscopedTransaction
  ]

  @doc """
  The real-data guard (plan r8 section 6.5): until C5-04, the reserved-name
  policy of `SdrAgent.Sales.Synthetic` on the domain and the email.
  """
  @spec real_data_permitted?(term(), term()) :: boolean()
  def real_data_permitted?(domain, email) when is_binary(domain) and is_binary(email),
    do: Synthetic.reserved_domain?(domain) and Synthetic.reserved_email?(email)

  def real_data_permitted?(_domain, _email), do: false

  @doc false
  # The admission (see the moduledoc); `SdrAgent.SDR.admit_lead/2` runs it in the Guard.
  def run(input, actor) do
    with {:ok, actor} <- admin_struct(actor),
         :ok <- not_referral(input),
         {:ok, doc} <- Input.normalize(input, actor.tenant_id),
         :ok <- guard(:input, doc["company"]["domain"], doc["person"]["email"]) do
      sha = Input.sha256(doc)

      fn -> committed(admit(doc, sha, actor)) end
      |> Audit.transaction()
      |> result()
    end
  end

  ## Steps 1-4 (no lock)

  defp admin_struct(%User{role: :admin, status: :active, tenant_id: tenant_id} = actor)
       when is_binary(tenant_id),
       do: {:ok, actor}

  defp admin_struct(_actor), do: {:error, :forbidden}

  defp not_referral(%{source_kind: :referral}), do: {:error, :use_referral_handover}
  defp not_referral(_input), do: :ok

  defp guard(stage, domain, email) do
    observe_guard(stage, domain, email)
    if real_data_permitted?(domain, email), do: :ok, else: {:error, :real_data_disabled}
  end

  ## The transaction

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Repo.rollback(reason)

  defp admit(doc, sha, actor) do
    tenant_id = actor.tenant_id
    :ok = IdentityKeys.pass(tenant_id, keys(doc))

    with {:ok, requester} <- requester(actor),
         :new <- stored(doc, sha, requester),
         {:ok, _campaign} <- campaign(doc, requester),
         {:ok, agent_run_id} <- discovery_run(doc, requester),
         {:ok, definition} <- SDRAgent.fetch_definition(tenant_id),
         :ok <- Agents.settings_complete(:assignment, actor: agent(tenant_id)),
         {:ok, facts} <- facts(doc, requester),
         :ok <- guard(:resolved, resolved_domain(facts, doc), resolved_email(facts, doc)) do
      context = %{
        doc: doc,
        sha: sha,
        requester: requester,
        definition: definition,
        agent_run_id: agent_run_id,
        facts: facts
      }

      context |> outcome() |> write(context)
    end
  end

  # Step 5's pass: the raw key inputs; IdentityKeys strips a domain once.
  defp keys(doc) do
    email = doc["person"]["email"]
    [_local, host] = String.split(email, "@", parts: 2)

    Enum.uniq([
      {:"admission-ref", doc["source_ref"]},
      {:domain, doc["company"]["domain"]},
      {:email, email},
      {:domain, host}
    ])
  end

  # Step 5: the authorization re-read, under the requester's FOR SHARE.
  defp requester(actor) do
    User
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
    |> Ash.Query.filter(id == ^actor.id and tenant_id == ^actor.tenant_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %User{role: :admin, status: :active} = user} -> {:ok, user}
      {:ok, _not_an_active_admin} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  # Step 6: the replay lookup.
  defp stored(doc, sha, requester) do
    LeadAdmission
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(
      tenant_id == ^requester.tenant_id and source_kind == ^kind(doc) and
        source_ref == ^doc["source_ref"]
    )
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> :new
      {:ok, %LeadAdmission{input_sha256: ^sha} = admission} -> replay(admission, requester)
      {:ok, %LeadAdmission{}} -> {:error, :source_ref_conflict}
      {:error, error} -> {:error, error}
    end
  end

  defp replay(admission, requester) do
    lead = admitted_lead(admission, requester)

    {:ok,
     %{
       admission: admission,
       outcome: admission.outcome,
       lead: lead,
       run: lead && first_run(lead, requester),
       replayed?: true
     }}
  end

  defp admitted_lead(%LeadAdmission{outcome: :admitted, id: id}, requester) do
    Sales.Lead
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(admission_id == ^id and tenant_id == ^requester.tenant_id)
    |> Ash.read_one!()
  end

  defp admitted_lead(_admission, _requester), do: nil

  defp first_run(lead, requester) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(
      lead_id == ^lead.id and tenant_id == ^requester.tenant_id and usage_origin == :assignment
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
  end

  # Step 7.
  defp campaign(doc, requester) do
    Sales.Campaign
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(id == ^doc["campaign_id"] and tenant_id == ^requester.tenant_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %{status: :active} = campaign} -> {:ok, campaign}
      {:ok, _missing_or_inactive} -> {:error, :campaign_not_active}
      {:error, error} -> {:error, error}
    end
  end

  # Step 8, agent_found only: the discovery run the candidate came from.
  defp discovery_run(%{"source_kind" => "agent_found", "agent_run_id" => id}, requester) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(id == ^id and tenant_id == ^requester.tenant_id)
    |> Ash.Query.lock("FOR KEY SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %AgentRun{usage_origin: :discovery}} -> {:ok, id}
      {:ok, _missing_or_other} -> {:error, {:invalid, [:agent_run_id]}}
      {:error, error} -> {:error, error}
    end
  end

  defp discovery_run(_doc, _requester), do: {:ok, nil}

  # Step 9: the locks, in the packet's order.
  defp facts(doc, requester) do
    account = account_share(doc["company"]["domain"], requester)
    contact = contact_share(doc["person"]["email"], requester)
    open = if account, do: open_leads(account.id, requester), else: []
    {:ok, %{account: account, contact: contact, open: open}}
  end

  # By the index's key form (a legacy `www.` row is found too).
  defp account_share(domain, requester) do
    Sales.Account
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(tenant_id == ^requester.tenant_id and canonical_domain == ^domain)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one!()
  end

  defp contact_share(email, requester) do
    Sales.Contact
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(tenant_id == ^requester.tenant_id and email == ^email)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one!()
  end

  # At most one row by the account index.
  defp open_leads(account_id, requester) do
    Sales.Lead
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(
      tenant_id == ^requester.tenant_id and account_id == ^account_id and
        status in ^Sales.Lead.open_statuses()
    )
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read!()
  end

  defp resolved_domain(%{account: %{domain: domain}}, _doc), do: to_string(domain)
  defp resolved_domain(_facts, doc), do: doc["company"]["domain"]

  defp resolved_email(%{contact: %{email: email}}, _doc), do: to_string(email)
  defp resolved_email(_facts, doc), do: doc["person"]["email"]

  ## Steps 10-16

  # The first decision-table step that applies, in the packet's order.
  defp outcome(context) do
    Enum.find_value(
      [
        &suppressed/1,
        &other_account/1,
        &archived/1,
        &duplicate_open_lead/1,
        &active_target/1,
        &in_relationship/1,
        &previously_worked/1
      ],
      :admitted,
      & &1.(context)
    )
  end

  # Step 10.
  defp suppressed(%{doc: doc, requester: requester}) do
    case SuppressionFacts.scope(
           requester.tenant_id,
           doc["person"]["email"],
           doc["company"]["domain"]
         ) do
      nil -> nil
      scope -> {:suppressed, scope}
    end
  end

  # Step 11.
  defp other_account(%{facts: %{contact: nil}}), do: nil

  defp other_account(%{facts: %{contact: contact, account: account}}) do
    if is_nil(account) or contact.account_id != account.id, do: :contact_at_other_account
  end

  # Step 12.
  defp archived(%{facts: %{contact: %{status: :archived}}}), do: :contact_archived
  defp archived(%{facts: %{account: %{status: :archived}}}), do: :account_archived
  defp archived(_context), do: nil

  # Step 13.
  defp duplicate_open_lead(%{facts: %{contact: nil}}), do: nil

  defp duplicate_open_lead(%{facts: %{contact: contact, open: open}}) do
    case Enum.find(open, &(&1.contact_id == contact.id)) do
      nil -> nil
      lead -> {:matched, :duplicate_open_lead, lead}
    end
  end

  # Step 14.
  defp active_target(%{facts: %{open: [lead | _]}}), do: {:matched, :active_target_exists, lead}
  defp active_target(_context), do: nil

  # Step 14a.
  defp in_relationship(%{doc: doc, facts: %{account: account}, requester: requester}) do
    if in_relationship?(kind(doc), account, requester), do: :company_in_relationship
  end

  # Step 15: a contact with only closed leads, unless readmitted (manual).
  defp previously_worked(%{doc: %{"readmit" => true}}), do: nil
  defp previously_worked(%{facts: %{contact: nil}}), do: nil

  defp previously_worked(%{facts: %{contact: contact}, requester: requester}) do
    if worked?(contact, requester), do: :previously_worked
  end

  # Step 14a: the account's most recently closed lead (no open lead is left
  # at the account here), its status only.
  defp in_relationship?(kind, %{id: account_id}, requester) when kind in @company_kinds do
    Sales.Lead
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(tenant_id == ^requester.tenant_id and account_id == ^account_id)
    |> Ash.Query.sort(closed_at: :desc_nils_last, id: :desc)
    |> Ash.Query.select([:status])
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
    |> case do
      %{status: status} -> status in @relationship
      nil -> false
    end
  end

  defp in_relationship?(_kind, _account, _requester), do: false

  defp worked?(contact, requester) do
    Sales.Lead
    |> Ash.Query.for_read(:read, %{}, actor: requester)
    |> Ash.Query.filter(tenant_id == ^requester.tenant_id and contact_id == ^contact.id)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
    |> is_struct()
  end

  defp write(:admitted, context), do: admitted(context)
  defp write(outcome, context), do: recorded(outcome, context)

  defp recorded(outcome, %{facts: %{account: account, contact: contact}} = context) do
    {name, attrs} =
      case outcome do
        {:suppressed, scope} -> {:suppressed, %{suppression_scope: scope}}
        {:matched, name, lead} -> {name, %{matched_lead_id: lead.id}}
        name -> {name, %{}}
      end

    attrs =
      attrs
      |> Map.put(:outcome, name)
      |> Map.merge(identities(name, account, contact))

    with {:ok, admission} <- record(attrs, context) do
      {:ok, %{admission: admission, outcome: name, lead: nil, run: nil, replayed?: false}}
    end
  end

  # The recorded identities: no account for a contact at another account;
  # a contact only at the recorded account (or the other account's contact).
  defp identities(:contact_at_other_account, _account, contact),
    do: %{account_id: nil, contact_id: contact.id}

  defp identities(_outcome, nil, _contact), do: %{account_id: nil, contact_id: nil}

  defp identities(_outcome, account, contact) do
    contact_id = if contact && contact.account_id == account.id, do: contact.id
    %{account_id: account.id, contact_id: contact_id}
  end

  defp admitted(%{doc: doc, facts: facts} = context) do
    with :ok <- required(facts.account, doc["company"], ["name"]),
         :ok <- required(facts.contact, doc["person"], ["first_name", "last_name"]),
         {:ok, account, account_created} <- account(facts.account, context),
         {:ok, contact, contact_created} <- contact(facts.contact, account, context),
         {:ok, admission} <-
           record(
             %{
               outcome: :admitted,
               account_id: account.id,
               contact_id: contact.id,
               account_created: account_created,
               contact_created: contact_created
             },
             context
           ),
         {:ok, lead} <- lead(account, contact, admission, context),
         {:ok, lead} <- Sales.update(lead, :assign, %{}, marked(context)),
         {:ok, queued} <- queue(lead, context) do
      {:ok,
       %{
         admission: admission,
         outcome: :admitted,
         lead: queued.lead,
         run: queued.run,
         replayed?: false
       }}
    end
  end

  # A new company or person must name itself (checked before any write).
  defp required(%{} = _existing, _part, _fields), do: :ok

  defp required(nil, part, fields) do
    case Enum.find(fields, &is_nil(part[&1])) do
      nil -> :ok
      field -> {:error, {:invalid, [String.to_existing_atom(field)]}}
    end
  end

  defp account(%Sales.Account{} = account, _context), do: {:ok, account, false}

  defp account(nil, %{doc: doc} = context) do
    company = doc["company"]

    attrs = %{
      name: company["name"],
      domain: company["domain"],
      website_url: company["website_url"],
      industry: company["industry"],
      employee_count: company["employee_count"],
      geography: company["geography"],
      source: kind(doc)
    }

    with {:ok, account} <- Sales.create_account(attrs, marked(context)), do: {:ok, account, true}
  end

  defp contact(%Sales.Contact{} = contact, _account, _context), do: {:ok, contact, false}

  defp contact(nil, account, %{doc: doc} = context) do
    person = doc["person"]

    attrs = %{
      account_id: account.id,
      email: person["email"],
      first_name: person["first_name"],
      last_name: person["last_name"],
      title: person["title"],
      timezone: person["timezone"]
    }

    with {:ok, contact} <- Sales.create_contact(attrs, marked(context)), do: {:ok, contact, true}
  end

  defp record(attrs, %{doc: doc, sha: sha, requester: requester, agent_run_id: run_id} = context) do
    attrs =
      Map.merge(attrs, %{
        source_kind: kind(doc),
        source_ref: doc["source_ref"],
        input_version: 1,
        input_sha256: sha,
        readmit: doc["readmit"],
        requested_by_user_id: requester.id,
        campaign_id: doc["campaign_id"],
        agent_run_id: run_id
      })

    Audit.GuardedCall.create(LeadAdmission, :record, attrs, marked(context))
  end

  defp lead(account, contact, admission, %{doc: doc, requester: requester} = context) do
    attrs = %{
      contact_id: contact.id,
      account_id: account.id,
      owner_user_id: requester.id,
      source: kind(doc),
      admission_id: admission.id
    }

    Sales.create_lead(attrs, marked(context))
  end

  defp queue(lead, %{doc: doc, definition: definition}) do
    Assignment.queue(lead,
      campaign_id: doc["campaign_id"],
      definition: definition,
      usage_origin: :assignment,
      agent: agent(lead.tenant_id),
      correlation_id: Ecto.UUID.generate(),
      job_opts: []
    )
  end

  # Every Sales write of the admission: the requester, and the marker.
  defp marked(%{requester: requester}),
    do: [actor: requester, context: LeadAdmissionContext.context()]

  defp agent(tenant_id), do: Actor.system(:agent_runtime, tenant_id)

  defp kind(doc), do: String.to_existing_atom(doc["source_kind"])

  ## Results

  defp result({:ok, value}), do: {:ok, value}
  defp result({:error, reason}), do: {:error, reason(reason)}

  @closed [
    :forbidden,
    :source_ref_conflict,
    :campaign_not_active,
    :agent_definition_unavailable,
    :real_data_disabled,
    :settings_default_unavailable
  ]

  defp reason(reason) when reason in @closed, do: reason
  defp reason({:invalid, [field]} = reason) when is_atom(field), do: reason

  defp reason({:settings_incomplete, kinds} = reason) when is_list(kinds),
    do: settings(kinds, reason)

  defp reason(error), do: error |> leaves() |> nested()

  # A returned nested refusal: an identity-key failure is re-raised (fail
  # closed); the settings snapshot's structured refusal and a policy
  # refusal keep their reasons; anything else is `:conflict`.
  defp nested(leaves) do
    case Enum.find(leaves, &(is_exception(&1) and &1.__struct__ in @identity_errors)) do
      nil -> Enum.find_value(leaves, :conflict, &known/1)
      error -> raise error
    end
  end

  defp known(%Ash.Error.Changes.InvalidAttribute{vars: vars, private_vars: private}) do
    case Keyword.get(vars || [], :rule) do
      :settings_incomplete -> settings(Keyword.get(private || [], :kinds), :conflict)
      :settings_default_unavailable -> :settings_default_unavailable
      _other -> nil
    end
  end

  defp known(%Ash.Error.Forbidden{}), do: :forbidden
  defp known(%Ash.Error.Forbidden.Policy{}), do: :forbidden
  defp known(_leaf), do: nil

  # Kinds are validated against the closed RunSettings set.
  defp settings([_ | _] = kinds, _otherwise) do
    if Enum.all?(kinds, &(&1 in RunSettings.kinds())),
      do: {:settings_incomplete, kinds},
      else: :conflict
  end

  defp settings(_kinds, otherwise), do: otherwise

  defp leaves(%Ash.Changeset{errors: errors}), do: Enum.flat_map(errors, &leaves/1)

  defp leaves(%{__exception__: true, errors: [_ | _] = errors} = error),
    do: [error | Enum.flat_map(errors, &leaves/1)]

  defp leaves(%Ash.Error.Unknown.UnknownError{error: error} = leaf) when is_exception(error),
    do: [leaf | leaves(error)]

  defp leaves(errors) when is_list(errors), do: Enum.flat_map(errors, &leaves/1)
  defp leaves(leaf), do: [leaf]

  ## Test seams

  if @test_seams do
    defp observe_guard(stage, domain, email),
      do: SdrAgent.SDR.Admission.TestHooks.checked(stage, domain, email)
  else
    defp observe_guard(_stage, _domain, _email), do: :ok
  end
end
