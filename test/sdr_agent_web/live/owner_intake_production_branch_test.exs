defmodule SdrAgentWeb.OwnerIntakeProductionBranchTest do
  @moduledoc """
  Ordinary-build intake events clear stale owner presentation and never call
  the prototype coordinator. The exact LiveView source is compiled under a
  fresh module name with prototype authority disabled, then the flag restored.
  """
  use ExUnit.Case, async: false

  @twin SdrAgentWeb.LeadLive.OrdinaryIntakeTwin
  @events ~w(intake_open intake_close intake_change intake_add_source intake_preview intake_commit)

  setup_all do
    source = File.read!("lib/sdr_agent_web/live/lead_live/index.ex")

    source =
      String.replace(
        source,
        "defmodule SdrAgentWeb.LeadLive.Index do",
        "defmodule #{inspect(@twin)} do"
      )

    previous = Application.fetch_env(:sdr_agent, :prototype_authority_compiled)

    modules =
      try do
        Application.put_env(:sdr_agent, :prototype_authority_compiled, false)
        Code.compile_string(source, "owner_intake_live_production_twin.ex")
      after
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, :prototype_authority_compiled, value)
          :error -> Application.delete_env(:sdr_agent, :prototype_authority_compiled)
        end
      end

    assert [{@twin, binary}] = modules
    %{binary: binary}
  end

  test "every ordinary intake event clears stale owner state without offering the panel" do
    for event <- @events do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_scope: %SdrAgentWeb.Scope{user: nil, role: :admin},
          owner?: true,
          intake_open?: true,
          intake_form: Phoenix.Component.to_form(%{"company_name" => "stale.test"}, as: :intake),
          source_rows: [0, 1],
          preview: %{mode: :create},
          intake_params: %{"company_name" => "stale.test"},
          intake_error: :preview_stale
        }
      }

      params = %{"intake" => %{"company_name" => "forged.test"}}

      assert {:noreply, result} =
               Function.capture(@twin, :handle_event, 3).(event, params, socket)

      refute result.assigns.owner?, event
      refute result.assigns.intake_open?, event
      assert result.assigns.preview == nil, event
      assert result.assigns.intake_params == nil, event
      assert result.assigns.intake_form.params == %{}, event
      assert result.assigns.source_rows == [0], event
    end
  end

  test "ordinary intake handlers do not import the prototype coordinator", ctx do
    assert {:ok, {@twin, [imports: imports]}} = :beam_lib.chunks(ctx.binary, [:imports])
    refute Enum.any?(imports, fn {module, _, _} -> module == SdrAgent.Prototype.OwnerIntake end)
  end
end
