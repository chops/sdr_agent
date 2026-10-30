defmodule SdrAgent.Prototype.ApplicationSafeLogTest do
  @moduledoc """
  RED, D-269 M8 (server r1 evidence claude-d269-m8-server-run-20261030.K71uqm):
  `SdrAgent.Application.start/2` with the prototype switch set attached
  SafeLog through `SafeLog.attach/0`, the held file-sink stub
  (`{:error, :not_implemented}`), so the application never booted and
  `mix sdr.prototype.serve` aborted at `stage=body`.

  The boot attach is the implemented filter-only `SafeLog.attach(file: nil)`
  (idempotent; the serve task attaches the same before `app.start`).
  `attach/0` stays the held stub. Switch off: nothing is attached.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Prototype.SafeLog

  @filter_id :sdr_prototype_content_free

  setup do
    previous = Application.get_env(:sdr_agent, SdrAgent.Prototype)
    filters = :logger.get_primary_config().filters
    had_filter? = List.keymember?(filters, @filter_id, 0)

    on_exit(fn ->
      Application.put_env(:sdr_agent, SdrAgent.Prototype, previous)
      unless had_filter?, do: SafeLog.detach()
    end)

    %{had_filter?: had_filter?}
  end

  defp boot_attach do
    assert function_exported?(SdrAgent.Application, :attach_safe_log, 0),
           "SdrAgent.Application.attach_safe_log/0 is not exported"

    apply(SdrAgent.Application, :attach_safe_log, [])
  end

  test "switch set: the boot attach succeeds and installs SafeLog's filter" do
    Application.put_env(:sdr_agent, SdrAgent.Prototype,
      switch: %{policy_id: "d237-prototype/1", instance_id: Ecto.UUID.generate()}
    )

    assert boot_attach() == :ok
    assert List.keymember?(:logger.get_primary_config().filters, @filter_id, 0)
    # Idempotent: a second boot attach (after the serve task's own) is :ok.
    assert boot_attach() == :ok
  end

  test "switch off: the boot attach changes nothing", ctx do
    Application.put_env(:sdr_agent, SdrAgent.Prototype, switch: :off)
    filters = :logger.get_primary_config().filters
    assert boot_attach() == :ok
    assert :logger.get_primary_config().filters == filters
    assert List.keymember?(filters, @filter_id, 0) == ctx.had_filter?
  end

  test "attach/0 stays the held file-sink stub" do
    assert SafeLog.attach() == {:error, :not_implemented}
  end
end
