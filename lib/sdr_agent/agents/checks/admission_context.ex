defmodule SdrAgent.Agents.Checks.AdmissionContext do
  @moduledoc """
  Marker and charge for `ModelInvocation :reserve` (C9): a real-model
  (ClaudeCLI) reservation is created only by
  `SdrAgent.Agents.reserve_model_invocation/3`, which sets this context —
  the admitted `%{grant_id:, allocation_id:, reserved_at:}` (the admission
  instant, read after every reservation lock is held) — only after
  `SdrAgent.Agents.Admission.admit/4` selected and checked the allocation
  inside the reservation transaction. No other code sets it, so a direct
  `:reserve` of a ClaudeCLI call is refused
  (`SdrAgent.Agents.Changes.AdmissionCharge`; same pattern as
  `SdrAgent.Agents.Checks.RetryContext` and `GrantContext`).
  """

  @marker :sdr_agent_model_admission

  @doc """
  The context map carrying an admitted charge, with the recorded
  `calibration_tuple` of an authorized calibration call (R0-07 slice B,
  row B4; nil otherwise), the console's `calibration_claim` recorded
  next to it (R0-07 E4c-2; nil otherwise) and, in prototype runtime, the
  `prototype_authority` that `Admission.admit/5` built after the room
  check (D-237 IF-4; nil otherwise).
  """
  def context(
        %{grant_id: grant_id, allocation_id: allocation_id, reserved_at: %DateTime{} = at} =
          charge
      )
      when is_binary(grant_id) and is_binary(allocation_id) do
    %{
      @marker => %{
        grant_id: grant_id,
        allocation_id: allocation_id,
        reserved_at: at,
        calibration_tuple: Map.get(charge, :calibration_tuple),
        calibration_claim: Map.get(charge, :calibration_claim),
        calibration_binding: Map.get(charge, :calibration_binding),
        prototype_authority: Map.get(charge, :prototype_authority),
        registration: Map.get(charge, :registration)
      }
    }
  end

  @doc "The admitted charge in a changeset context, or `nil`."
  def charge(%{
        @marker =>
          %{grant_id: grant_id, allocation_id: allocation_id, reserved_at: %DateTime{}} =
            charge
      })
      when is_binary(grant_id) and is_binary(allocation_id),
      do:
        charge
        |> Map.put_new(:calibration_tuple, nil)
        |> Map.put_new(:calibration_claim, nil)
        |> Map.put_new(:calibration_binding, nil)
        |> Map.put_new(:prototype_authority, nil)
        |> Map.put_new(:registration, nil)

  def charge(%{@marker => _malformed}), do: :malformed
  def charge(_context), do: nil

  ## D-237 trusted admission origin (mechanism note r3 section B)

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  if @prototype_compiled do
    @doc """
    Whether `registration` is a live, unconsumed registration this process
    owns in the current transaction (read-only; see
    `SdrAgent.Prototype.Admission`).
    """
    defdelegate registered?(registration), to: SdrAgent.Prototype.Admission

    @doc "Every registration this process owns: live, stale and consumed ones."
    defdelegate pending(), to: SdrAgent.Prototype.Admission

    @doc "Removes this process's own entry equal to `registration`; nothing else."
    defdelegate discard(registration), to: SdrAgent.Prototype.Admission

    @doc """
    Runs `fun` and then discards ONLY the registrations this process created
    during it (by owned ref), whatever `fun` returns or raises; its result
    or raise is passed through unchanged.
    """
    defdelegate with_owned_registrations(fun), to: SdrAgent.Prototype.Admission
  else
    @doc "The production build has no registrations."
    def registered?(_registration), do: false

    @doc "The production build has no registrations."
    def pending, do: 0

    @doc "The production build has no registrations."
    def discard(_registration), do: :ok

    @doc "The production build has no registrations: `fun.()`, unchanged."
    def with_owned_registrations(fun), do: fun.()
  end
end

defmodule SdrAgent.Agents.Checks.AdmissionContext.Registration do
  @moduledoc """
  A D-237 trusted admission-origin registration (mechanism note r3 section
  B): made only by `SdrAgent.Agents.Admission.admit/5` in prototype runtime,
  after the room check, for the charge it admitted and the 14-key authority
  it built. It binds the reservation it may fund (tenant, run, provider,
  profile, purpose, grant, allocation, admitted instant), the authority's
  canonical digest, and its owner's PostgreSQL transaction id and
  transaction-local marker. A trusted in-process convention, not a
  capability against server code.
  """

  @enforce_keys [
    :ref,
    :tenant_id,
    :agent_run_id,
    :provider,
    :profile_id,
    :purpose,
    :grant_id,
    :allocation_id,
    :reserved_at,
    :authority_sha256,
    :xact_id,
    :savepoint_marker
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end
