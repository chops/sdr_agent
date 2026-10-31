defmodule SdrAgent.Operations.HostedOwners do
  @moduledoc """
  Transactional hosted-owner enrollment, one-use link exchange and terminal
  revocation (ADR-0024/P2). Public callers use the Operations domain APIs.

  Console enrollment requires an ordinary-runtime marked kernel and the
  latest activated relocation naming the live database. Users stay reviewers;
  nobody impersonates the kernel for an owner action. Narrow User/owner writes
  require a privately registered process/transaction scope. All persistence
  goes through authorized Ash actions; token mint/revoke uses existing
  AshAuthentication actions. Enrollment JWTs have a separate stored purpose,
  bind owner+activation, and cannot directly authenticate a normal session.
  """

  @behaviour SdrAgent.Audit.HumanAuthority

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  if @compiled do
    require Ash.Query

    alias AshAuthentication.Jwt
    alias AshAuthentication.TokenResource.Actions, as: TokenActions
    alias SdrAgent.Accounts.Token
    alias SdrAgent.Accounts.User
    alias SdrAgent.Actor
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Operations.HostedOwner
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.Authority
    alias SdrAgent.Prototype.Checks.KernelMarker
    alias SdrAgent.Prototype.CurrentAuthority
    alias SdrAgent.Prototype.Relocation
    alias SdrAgent.Repo

    @scope_key {__MODULE__, :write_scope}
    @scope_marker :sdr_hosted_owner_write_scope
    @purpose "hosted_owner_enrollment"

    @doc "Console enrollment; the returned link token is printed only by the owner console."
    def enrol(attrs, opts) do
      actor = Keyword.get(opts, :actor)

      if console?(actor, opts) do
        transaction(fn -> enrol_locked(Map.new(attrs), actor) end)
      else
        forbidden()
      end
    end

    defp enrol_locked(attrs, actor) do
      with {:ok, _} <- Kernel.lock_head(actor.tenant_id),
           {:ok, binding, activation} <- live_activation(actor.tenant_id),
           :ok <- no_active_owner(binding.id, actor.tenant_id),
           {:ok, user} <- create_user(attrs, actor),
           {:ok, owner} <- create_owner(user, binding, activation, actor),
           {:ok, token, _claims} <- link(user, owner) do
        {:ok, %{owner: owner, user: user, enrollment_token: token}}
      end
    end

    defp create_user(attrs, actor) do
      password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      attrs = Map.take(attrs, [:email, :display_name]) |> Map.put(:password, password)
      scoped_create(User, :create_hosted_owner, attrs, actor)
    end

    defp create_owner(user, binding, activation, actor) do
      scoped_create(
        HostedOwner,
        :enrol,
        %{user_id: user.id, binding_id: binding.id, relocation_id: activation.id},
        actor
      )
    end

    defp link(user, owner) do
      Jwt.token_for_user(
        user,
        %{"hosted_owner_id" => owner.id, "relocation_id" => owner.relocation_id},
        purpose: :hosted_owner_enrollment,
        token_lifetime: 900
      )
    end

    @doc "Exchange a signed, stored, unexpired one-use link for a normal stored session."
    def consume_link(token) when is_binary(token) do
      with {:ok, claims, User} <- Jwt.verify(token, :sdr_agent),
           {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], User) do
        transaction(fn -> consume_locked(token, claims, user) end)
      else
        _refused -> {:error, :invalid_enrollment_link}
      end
    rescue
      _error -> {:error, :invalid_enrollment_link}
    end

    def consume_link(_token), do: {:error, :invalid_enrollment_link}

    defp consume_locked(token, claims, user) do
      with {:ok, owner} <- lock_owner(claims["hosted_owner_id"], user.tenant_id),
           {:ok, fresh} <- lock_user(owner.user_id, user.tenant_id, :for_share),
           {:ok, _} <- Kernel.lock_head(user.tenant_id),
           {:ok, _claims, User} <- Jwt.verify(token, :sdr_agent),
           :ok <- stored_link(token),
           :ok <- link_owner(owner, fresh, claims, user.id),
           :ok <- TokenActions.revoke(Token, token, single_use?: true),
           {:ok, session, _} <- Jwt.token_for_user(fresh) do
        {:ok, Ash.Resource.put_metadata(fresh, :token, session)}
      else
        _refused -> {:error, :invalid_enrollment_link}
      end
    end

    defp stored_link(token) do
      case TokenActions.get_token(Token, %{"token" => token, "purpose" => @purpose}) do
        {:ok, [_stored]} -> :ok
        _refused -> {:error, :invalid_enrollment_link}
      end
    end

    defp link_owner(owner, user, claims, subject_id) do
      with true <- user.id == subject_id and user.role == :reviewer and user.status == :active,
           true <- owner.status == :active and owner.relocation_id == claims["relocation_id"],
           {:ok, binding, activation} <- live_activation(user.tenant_id),
           true <- owner.binding_id == binding.id and owner.relocation_id == activation.id do
        :ok
      else
        _refused -> {:error, :invalid_enrollment_link}
      end
    end

    @doc "Terminal disable by the console or exact active owner self, including every token."
    def disable(id, opts) do
      actor = Keyword.get(opts, :actor)

      if console?(actor, opts) or active?(actor) do
        transaction(fn -> disable_locked(id, actor, opts) end)
      else
        forbidden()
      end
    end

    defp disable_locked(id, actor, opts) do
      with {:ok, owner} <- lock_owner(id, actor.tenant_id),
           {:ok, user} <- lock_user(owner.user_id, actor.tenant_id, :for_update),
           {:ok, _} <- Kernel.lock_head(actor.tenant_id),
           :ok <- may_disable(owner, actor, opts),
           {:ok, _user} <- scoped_update(user, :disable_hosted_owner_user, actor) do
        scoped_update(owner, :disable, actor)
      end
    end

    defp may_disable(%HostedOwner{status: :active} = owner, actor, opts) do
      if console?(actor, opts) or (owner.user_id == actor.id and active?(actor)),
        do: :ok,
        else: forbidden()
    end

    defp may_disable(_owner, _actor, _opts), do: forbidden()

    @doc "Fresh live authority for the hosted reviewer; never trust a role/id alone."
    def active?(%User{role: :reviewer, status: :active, id: id, tenant_id: tenant_id}) do
      with :prototype <- Prototype.runtime(),
           {:ok, snapshot} <- Prototype.binding(),
           true <- snapshot.tenant_id == tenant_id,
           {:ok, binding, activation} <- live_activation(tenant_id),
           true <- snapshot.id == binding.id,
           {:ok, %User{role: :reviewer, status: :active}} <-
             read_user(id, tenant_id),
           {:ok, %HostedOwner{binding_id: binding_id, relocation_id: relocation_id}} <-
             active_owner_user(id, tenant_id) do
        binding_id == binding.id and relocation_id == activation.id
      else
        _refused -> false
      end
    rescue
      _error -> false
    end

    def active?(_actor), do: false

    @impl true
    def hosted_owner?(actor), do: active?(actor)

    @doc """
    Validates the retained legacy prototype human path against persisted
    identity. ANY owner association, including disabled history, takes
    precedence; no role fallback is available to a hosted identity.
    """
    def legacy_human?(%User{role: role} = actor) when role in [:admin, :reviewer, :auditor] do
      with :prototype <- Prototype.runtime(),
           {:ok, snapshot} <- Prototype.binding(),
           true <- snapshot.tenant_id == actor.tenant_id,
           true <- fresh_human?(actor),
           {:ok, nil} <- associated_owner(actor.id, actor.tenant_id) do
        true
      else
        _refused -> false
      end
    rescue
      _error -> false
    end

    def legacy_human?(_actor), do: false

    @impl true
    def role_allowed?(%{role: role} = actor) when role in [:admin, :reviewer, :auditor] do
      Prototype.runtime() == :ordinary or legacy_human?(actor)
    end

    def role_allowed?(_actor), do: false

    @doc "Fresh hosted or validated legacy human metadata access; ordinary runtime is unchanged."
    @impl true
    def human_read?(%User{} = actor) do
      Prototype.runtime() == :ordinary or active?(actor) or legacy_human?(actor)
    end

    def human_read?(_actor), do: false

    @doc "Hosted website principal: a live owner or the exact bound persisted auditor."
    def web_principal?(%User{} = actor) do
      Prototype.runtime() == :ordinary or active?(actor) or bound_auditor?(actor)
    end

    def web_principal?(_actor), do: false

    defp bound_auditor?(%User{role: :auditor} = actor) do
      with {:ok, snapshot} <- Prototype.binding(),
           true <- snapshot.auditor_user_id == actor.id,
           true <- snapshot.tenant_id == actor.tenant_id,
           :ok <- Prototype.check_live() do
        legacy_human?(actor)
      else
        _refused -> false
      end
    end

    defp bound_auditor?(_actor), do: false

    defp fresh_human?(%User{status: :active} = actor) do
      case read_user(actor.id, actor.tenant_id) do
        {:ok, %User{id: id, tenant_id: tenant_id, role: role, status: :active}} ->
          {id, tenant_id, role} == {actor.id, actor.tenant_id, actor.role}

        _refused ->
          false
      end
    end

    defp fresh_human?(_actor), do: false

    # unique_user is global. Deliberately NO active/status filter: terminal
    # history must never be reclassified as an unrelated legacy reviewer.
    defp associated_owner(id, tenant_id) do
      HostedOwner
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(user_id == ^id)
      |> Ash.read_one()
    end

    @doc "Boot's exact additional user tuples, including powerless revoked historical owners."
    def boot_user_rows(binding) do
      with {:ok, owners} <- read_owners(binding.tenant_id),
           {:ok, _binding, activation} <- activation_if_needed(binding, owners) do
        owners |> Enum.reduce_while({:ok, []}, &boot_owner(&1, &2, binding, activation))
      else
        _refused -> {:error, :users_not_exact}
      end
    rescue
      _error -> {:error, :users_not_exact}
    end

    defp activation_if_needed(binding, []), do: {:ok, binding, nil}
    defp activation_if_needed(binding, _owners), do: live_activation(binding.tenant_id)

    defp boot_owner(owner, {:ok, rows}, binding, activation) do
      with true <- owner.binding_id == binding.id,
           {:ok, %User{role: :reviewer} = user} <-
             read_user(owner.user_id, binding.tenant_id),
           true <- boot_owner_status?(owner, user, activation) do
        {:cont, {:ok, [{user.id, "reviewer", to_string(user.status), false} | rows]}}
      else
        _refused -> {:halt, {:error, :users_not_exact}}
      end
    end

    defp boot_owner_status?(
           %HostedOwner{status: :active} = owner,
           %User{status: :active},
           activation
         ),
         do: owner.relocation_id == activation.id

    defp boot_owner_status?(
           %HostedOwner{status: :disabled},
           %User{status: :disabled} = user,
           _activation
         ) do
      subject = AshAuthentication.user_to_subject(user)

      %{rows: [[count]]} =
        Repo.query!(
          "SELECT count(*) FROM tokens WHERE subject = $1 AND purpose <> 'revocation' AND expires_at > $2",
          [subject, SdrAgent.Clock.utc_now()]
        )

      count == 0
    end

    defp boot_owner_status?(_owner, _user, _activation), do: false

    defp read_owners(tenant_id) do
      HostedOwner
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read()
    end

    defp active_owner_user(id, tenant_id) do
      HostedOwner
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(user_id == ^id and tenant_id == ^tenant_id and status == :active)
      |> Ash.read_one()
    end

    defp no_active_owner(binding_id, tenant_id) do
      query =
        HostedOwner
        |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
        |> Ash.Query.filter(
          binding_id == ^binding_id and tenant_id == ^tenant_id and status == :active
        )

      case Ash.read_one(query) do
        {:ok, nil} -> :ok
        {:ok, _owner} -> {:error, :hosted_owner_exists}
        {:error, error} -> {:error, error}
      end
    end

    defp lock_owner(id, tenant_id) when is_binary(id) do
      HostedOwner
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one()
      |> found()
    end

    defp lock_owner(_id, _tenant_id), do: forbidden()

    defp lock_user(id, tenant_id, mode) do
      User
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.Query.lock(if(mode == :for_share, do: "FOR SHARE", else: mode))
      |> Ash.read_one()
      |> found()
    end

    # GuardedCall.get intentionally accepts only its public actor options;
    # this internal authorized read must retain the existing kernel context.
    defp read_user(id, tenant_id) do
      User
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.read_one()
      |> found()
    end

    defp found({:ok, nil}), do: forbidden()
    defp found(result), do: result

    defp live_activation(tenant_id) do
      query =
        PrototypeDatabaseBinding
        |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
        |> Ash.Query.filter(tenant_id == ^tenant_id)

      with {:ok, %PrototypeDatabaseBinding{} = binding} <- Ash.read_one(query),
           {:ok, live} <- Authority.live_identity(),
           {:ok, chain} <- Relocation.chain(binding.id, tenant_id),
           {:ok, current} <- CurrentAuthority.identity(chain, CurrentAuthority.normalize(binding)),
           true <- current == CurrentAuthority.normalize(live),
           sequence when is_integer(sequence) <- activated_sequence(chain),
           {:ok, %Relocation{} = activation} <- activation_row(binding.id, tenant_id, sequence) do
        {:ok, binding, activation}
      else
        _refused -> {:error, :not_current_activation}
      end
    end

    defp activated_sequence(chain) do
      chain
      |> Enum.filter(&Enum.any?(&1.events, fn event -> event.kind == :activated end))
      |> Enum.map(& &1.relocation_seq)
      |> Enum.max(fn -> nil end)
    end

    defp activation_row(binding_id, tenant_id, sequence) do
      Relocation
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(binding_id == ^binding_id and relocation_seq == ^sequence)
      |> Ash.read_one()
    end

    defp console?(%Actor{type: :kernel} = actor, opts) do
      Prototype.runtime() == :ordinary and
        KernelMarker.match?(actor, %{subject: %{context: Keyword.get(opts, :context, %{})}},
          marker: :hosted_owner
        )
    end

    defp console?(_actor, _opts), do: false

    defp transaction(fun) do
      Audit.transaction(fn ->
        case fun.() do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
          _refused -> Repo.rollback(:hosted_owner_refused)
        end
      end)
    rescue
      _error -> {:error, :hosted_owner_refused}
    end

    defp scoped_create(resource, action, attrs, actor) do
      with_scope(resource, action, nil, actor, fn context ->
        resource
        |> Ash.Changeset.for_create(action, attrs, actor: actor, context: context)
        |> Ash.create()
      end)
    end

    defp scoped_update(%resource{id: id} = row, action, actor) do
      with_scope(resource, action, id, actor, fn context ->
        row
        |> Ash.Changeset.for_update(action, %{}, actor: actor, context: context)
        |> Ash.update()
      end)
    end

    defp with_scope(resource, action, id, actor, fun) do
      previous = Process.get(@scope_key)
      ref = make_ref()

      Process.put(@scope_key, %{
        ref: ref,
        actor: actor,
        resource: resource,
        action: action,
        id: id
      })

      try do
        context = %{@scope_marker => ref}

        context =
          if match?(%Actor{type: :kernel}, actor),
            do: Map.merge(KernelMarker.context(:hosted_owner), context),
            else: context

        fun.(context)
      after
        if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
      end
    end

    @doc false
    @impl true
    def valid_write_scope?(actor, %Ash.Changeset{} = changeset) do
      with true <- Repo.in_transaction?(),
           ref when is_reference(ref) <- Map.get(changeset.context, @scope_marker),
           %{ref: ^ref, actor: ^actor, resource: resource, action: action, id: id} <-
             Process.get(@scope_key) do
        changeset.resource == resource and changeset.action.name == action and
          (id == nil or changeset.data.id == id)
      else
        _refused -> false
      end
    end

    def valid_write_scope?(_actor, _subject), do: false
    defp forbidden, do: {:error, Ash.Error.Forbidden.exception([])}
  else
    @doc "Unavailable: the ordinary production build has no hosted prototype authority."
    def enrol(_attrs, _opts), do: {:error, :not_prototype_runtime}
    @doc "Unavailable in an ordinary production build."
    def consume_link(_token), do: {:error, :not_prototype_runtime}
    @doc "Unavailable in an ordinary production build."
    def disable(_id, _opts), do: {:error, :not_prototype_runtime}
    @doc "No hosted authority in an ordinary production build."
    def active?(_actor), do: false
    @impl true
    def hosted_owner?(_actor), do: false
    @doc "No prototype legacy-human resolver in an ordinary production build."
    def legacy_human?(_actor), do: false
    @impl true
    def role_allowed?(_actor), do: false
    @doc "Ordinary human metadata semantics are unchanged."
    @impl true
    def human_read?(%SdrAgent.Accounts.User{}), do: true
    def human_read?(_actor), do: false
    @doc "Ordinary browser authentication remains available."
    def web_principal?(%SdrAgent.Accounts.User{}), do: true
    def web_principal?(_actor), do: false
    @doc "No additional boot users in an ordinary production build."
    def boot_user_rows(_binding), do: {:ok, []}
    @doc false
    @impl true
    def valid_write_scope?(_actor, _subject), do: false
  end
end
