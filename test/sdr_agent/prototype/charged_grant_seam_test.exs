defmodule SdrAgent.Prototype.ChargedGrantSeamTest do
  @moduledoc """
  RED-b2c (Codex 3122b0d4 Q6; Codex 6d1ead6d common error rule), D-237
  slice S2: the charged-grant read shared by launch and the release
  decision separates a successful absence from a returned error.

  - `{:ok, nil}` (no charged grant) is the business refusal
    `grant_not_eligible`: launch refuses with its charge kept, the release
    is withheld.
  - A returned `{:error, e}` is PROPAGATED unchanged: no launch, no release,
    no business refusal, refusal event or Failure manufactured from it, the
    charge kept, the invocation still `:reserved` (launch) and no decision
    (release). No mapping of Forbidden is defined, so it propagates too.

  The results are injected through a test-seam builds only hook,
  `config :sdr_agent, SdrAgent.Prototype.Admission, charged_grant_read:
  fun/1` (the invocation in, the injected read result out), which the
  increment adds; until then the injection is never consulted, so every case
  stops at its seam prerequisite (PREREQUISITE, not semantic RED). The
  injected error is a returned Ash error whose leaf is a binary
  `UnknownError`, the shape a real failed read returns; no Postgrex struct is
  synthesized and no DB failure type is inferred. Assertion messages are
  value-free (`G.summary/1`).
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Prototype.Admission
  alias SdrAgent.PrototypeGateFixtures, as: G

  setup do
    previous = Application.get_env(:sdr_agent, Admission)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, Admission, previous),
        else: Application.delete_env(:sdr_agent, Admission)
    end)

    fx = G.prototype!()
    %{fx: fx, run: G.run!(fx)}
  end

  defp inject!(result) do
    Application.put_env(:sdr_agent, Admission,
      charged_grant_read: fn _invocation ->
        Process.put(:charged_grant_seam, Process.get(:charged_grant_seam, 0) + 1)
        result
      end
    )
  end

  defp clear!, do: Application.delete_env(:sdr_agent, Admission)

  defp consulted!,
    do:
      assert(
        Process.get(:charged_grant_seam, 0) > 0,
        "prerequisite: the charged-grant seam was not consulted"
      )

  defp returned_error,
    do:
      Unknown.exception(errors: [UnknownError.exception(error: "d237-s2 synthetic read failure")])

  defp reserved!(ctx) do
    result = G.reserve(ctx.fx, ctx.run)

    assert match?({:ok, %ModelInvocation{}}, result),
           "prerequisite: reserve: #{inspect(G.summary(result))}"

    {:ok, invocation} = result
    invocation
  end

  defp status(invocation), do: Ash.get!(ModelInvocation, invocation.id, authorize?: false).status

  defp failures(fx) do
    SdrAgent.Operations.Failure
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  describe "launch" do
    test "{:ok, nil}: refused grant_not_eligible, the charge kept", ctx do
      invocation = reserved!(ctx)
      inject!({:ok, nil})
      result = G.launch(ctx.fx, invocation)
      consulted!()

      assert match?(
               {:error,
                %Refused{
                  stage: :launch,
                  reason: :prototype_not_authorized,
                  check: :grant_not_eligible
                }},
               result
             ),
             "launch: #{inspect(G.summary(result))}"

      assert status(invocation) == :failed
      assert G.charged(ctx.fx) == 1
    end

    for {label, error} <- [returned: :unknown, forbidden: :forbidden] do
      test "a #{label} error is propagated unchanged: no launch, no refusal, the charge kept",
           ctx do
        invocation = reserved!(ctx)
        failures_before = failures(ctx.fx)

        injected =
          case unquote(error) do
            :unknown -> returned_error()
            :forbidden -> Ash.Error.Forbidden.exception([])
          end

        inject!({:error, injected})
        result = G.launch(ctx.fx, invocation)
        consulted!()

        assert result == {:error, injected}, "launch: #{inspect(G.summary(result))}"
        assert status(invocation) == :reserved
        assert events_of_type(ctx.fx.tenant, "model.launch.refused") == []
        assert failures(ctx.fx) == failures_before
        assert G.charged(ctx.fx) == 1
      end
    end
  end

  describe "the release decision" do
    test "{:ok, nil}: withheld grant_not_eligible", ctx do
      invocation = G.completed!(ctx.fx, ctx.run)
      inject!({:ok, nil})
      result = G.finalize(invocation, ctx.run)
      consulted!()

      assert match?({:withheld, %{reason: :prototype_authority_refused}, _}, result),
             "finalize: #{inspect(G.summary(result))}"

      {:withheld, release, _run} = result
      [event] = G.release_events(ctx.fx, "model.result.withheld", release)
      assert event.payload["arguments"]["prototype_refusal"] == "grant_not_eligible"
    end

    test "a returned error is propagated unchanged: nothing decided, the run still running",
         ctx do
      invocation = G.completed!(ctx.fx, ctx.run)
      injected = returned_error()
      inject!({:error, injected})
      result = G.finalize(invocation, ctx.run)
      consulted!()
      clear!()

      assert result == {:error, injected}, "finalize: #{inspect(G.summary(result))}"
      assert G.release(invocation) == nil
      assert events_of_type(ctx.fx.tenant, "model.result.withheld") == []
      assert events_of_type(ctx.fx.tenant, "model.result.released_unverified") == []

      assert Ash.get!(SdrAgent.Agents.AgentRun, ctx.run.id, authorize?: false).status == :running
      assert G.charged(ctx.fx) == 1
    end
  end
end
