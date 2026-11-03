defmodule SdrAgent.Prototype.ProspectSearch do
  @moduledoc """
  Fresh-hosted-owner interactive discovery facade (ADR-0027). Results are sent
  only to the calling process. No search writes business/model state. The web
  layer must recheck authorization before displaying or selecting results.
  Ordinary builds refuse without consulting persistence or provider transport.
  """

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Audit.HumanAuthority
    alias SdrAgent.Discovery.Candidate
    alias SdrAgent.Discovery.Config
    alias SdrAgent.Discovery.Limiter

    @doc "Fresh owner check, independent of provider availability."
    def authorized?(actor), do: HumanAuthority.hosted_owner?(actor)

    @doc "Whether the owner can explicitly request paid discovery."
    def available?(actor), do: authorized?(actor) and Config.ready?()

    @doc "Authorize, validate and admit one explicit asynchronous action."
    def start(actor, request) do
      with :ok <- owner(actor),
           true <- Config.ready?(),
           {:ok, request} <- Candidate.request(request) do
        Limiter.start({actor.tenant_id, actor.id}, request)
      else
        false -> {:error, :unavailable}
        error -> error
      end
    catch
      :exit, _ -> {:error, :unavailable}
    end

    @doc "Cancel only an action owned by this owner and this exact process."
    def cancel(actor, id) do
      with :ok <- owner(actor), do: Limiter.cancel({actor.tenant_id, actor.id}, id)
    catch
      :exit, _ -> {:error, :unavailable}
    end

    @doc "Authorize before confirming the server-held candidate's company inputs."
    def company_context(actor, candidate, inputs) do
      with :ok <- owner(actor), do: Candidate.company_context(candidate, inputs)
    end

    defp owner(actor), do: if(authorized?(actor), do: :ok, else: {:error, :forbidden})
  else
    @doc "Ordinary builds have no discovery authority."
    def authorized?(_), do: false
    @doc "Ordinary builds never expose paid search."
    def available?(_), do: false
    @doc "Constant refusal outside the compiled hosted authority boundary."
    def start(_, _), do: {:error, :forbidden}
    @doc "Constant refusal outside the compiled hosted authority boundary."
    def cancel(_, _), do: {:error, :forbidden}
    @doc "Constant refusal outside the compiled hosted authority boundary."
    def company_context(_, _, _), do: {:error, :forbidden}
  end
end
