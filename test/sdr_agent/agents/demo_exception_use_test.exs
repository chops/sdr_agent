defmodule SdrAgent.Agents.DemoExceptionUseTest do
  @moduledoc """
  C2* S3 RED-4, output use and registration, and the field and action
  policies (plan r2 §6 `ReleasedOutput`/`DemoExceptionUse`, §8 row "use and
  registration" (T-U-reg); ADR-0005 C2* item 9; AC9; OQ1), with explicit
  allow and deny cases.

  Allow: the output through `ReleasedOutput.fetch/2` (`Agents.released_output/2`)
  under present use authority; AGT deciding under the finalizer's context
  (T-L1's positive control in `demo_exception_authority_test.exs`).
  Deny: fetch without use authority; a registration copied into another
  process, a forged reference, a registration of another invocation, an
  admin's raw read, and the ordinary released-output mark alone each read
  `%Ash.ForbiddenField{}`; the auditor, REC, the kernel and an admin may not
  `:decide` a `:demo_exception`. The registration is gone after fetch
  returns, raises, throws or exits.

  Classification (RED-4 at 109b2614): every test passes now. The
  registration, the field-policy row and the fetch path were implemented in
  GREEN-3b (`8d7ec3a`..`109b2614`), so these are disclosed
  tests-after-GREEN coverage (`control:` in the RED-4 inventory), not REDs.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.DemoExceptionUse
  alias SdrAgent.Agents.Checks.ReleasedOutputRead
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Clock
  alias SdrAgent.DemoExceptionFixtures, as: Fx

  @end_at ~U[2026-11-01 06:00:00.000000Z]

  setup do
    env = Fx.demo_env!()
    %{env: env, demo: Fx.demo_invocation!(env)}
  end

  describe "fetch under use authority (AC9)" do
    test "control: allow, the output under use authority; no registration remains",
         %{env: env, demo: demo} do
      assert {:ok, output} = Agents.released_output(demo.invocation.id, actor: env.agent)
      assert output == demo.output
      assert registrations() == []
    end

    test "control: deny, no output after expiry", %{env: env, demo: demo} do
      :ok = Clock.freeze(DateTime.add(@end_at, 1, :second))

      assert Agents.released_output(demo.invocation.id, actor: env.agent) ==
               {:error, :result_not_released}

      assert registrations() == []
    end

    test "control: a raise inside the use path leaves no registration", %{env: env, demo: demo} do
      Fx.put_source!(:live_binding?, fn _att, _tenant -> raise "injected" end)

      assert_raise RuntimeError, "injected", fn ->
        Agents.released_output(demo.invocation.id, actor: env.agent)
      end

      assert registrations() == []
    end

    for exit <- [:return, :raise, :throw, :exit] do
      @tag exit: exit
      test "control: with_use/3 removes its registration on #{exit}", %{demo: demo} = ctx do
        run_and_exit(demo.invocation, ctx.exit)
        assert registrations() == []
      end
    end
  end

  describe "the output field policy (OQ1)" do
    test "control: deny, a registration copied into another process", %{env: env, demo: demo} do
      read =
        DemoExceptionUse.with_use(env.tenant.id, demo.invocation.id, fn ref ->
          own = read(env, demo.invocation.id, ref)
          refute match?(%Ash.ForbiddenField{}, own.parsed_output)
          task = Task.async(fn -> read(env, demo.invocation.id, ref) end)
          Task.await(task)
        end)

      assert %Ash.ForbiddenField{} = read.parsed_output
    end

    test "control: deny, a forged reference", %{env: env, demo: demo} do
      assert %Ash.ForbiddenField{} = read(env, demo.invocation.id, make_ref()).parsed_output
    end

    test "control: deny, a registration of another invocation", %{env: env, demo: demo} do
      other = Fx.demo_invocation!(env)

      read =
        DemoExceptionUse.with_use(env.tenant.id, demo.invocation.id, fn ref ->
          read(env, other.invocation.id, ref)
        end)

      assert %Ash.ForbiddenField{} = read.parsed_output
    end

    test "control: deny, the released-output mark alone and an admin's raw read",
         %{env: env, demo: demo} do
      marked =
        ModelInvocation
        |> Ash.Query.for_read(:read, %{},
          actor: env.agent,
          context: ReleasedOutputRead.context()
        )
        |> Ash.Query.filter(id == ^demo.invocation.id)
        |> Ash.read_one!()

      assert %Ash.ForbiddenField{} = marked.parsed_output

      raw =
        ModelInvocation
        |> Ash.Query.for_read(:read, %{}, actor: human(:admin, env.tenant))
        |> Ash.Query.filter(id == ^demo.invocation.id)
        |> Ash.read_one!()

      assert %Ash.ForbiddenField{} = raw.parsed_output
    end
  end

  describe "the :decide action policy for :demo_exception" do
    for actor <- [:auditor, :reconciler, :kernel, :admin] do
      @tag actor: actor
      test "control: deny #{actor}", %{env: env} = ctx do
        parts = Fx.constructed!(env)

        attrs = %{
          model_invocation_id: parts.invocation.id,
          disposition: :demo_exception,
          reason: :v4_uncalibrated,
          wire_witness_link_id: parts.link.id
        }

        assert {:error, %Ash.Error.Forbidden{}} =
                 Agents.decide_result_release(attrs, actor: actor(env, ctx.actor))

        assert {:ok, nil} = Agents.get_result_release(parts.invocation.id, actor: env.agent)
      end
    end
  end

  ## Harness

  defp read(env, invocation_id, ref) do
    context = Map.merge(ReleasedOutputRead.context(), DemoExceptionUse.context(ref))

    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: env.agent, context: context)
    |> Ash.Query.filter(id == ^invocation_id)
    |> Ash.read_one!()
  end

  defp registrations do
    Enum.filter(Process.get_keys(), &match?({DemoExceptionUse, _ref}, &1))
  end

  defp run_and_exit(invocation, exit) do
    fun = fn _ref ->
      case exit do
        :return -> :ok
        :raise -> raise "injected"
        :throw -> throw(:injected)
        :exit -> exit(:injected)
      end
    end

    try do
      DemoExceptionUse.with_use(invocation.tenant_id, invocation.id, fun)
    rescue
      RuntimeError -> :raised
    catch
      :throw, :injected -> :thrown
      :exit, :injected -> :exited
    end
  end

  defp actor(env, :auditor), do: human(:auditor, env.tenant)
  defp actor(env, :admin), do: human(:admin, env.tenant)
  defp actor(env, type), do: system_actor(type, env.tenant)
end
