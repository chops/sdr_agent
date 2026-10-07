defmodule SdrAgent.Outreach.NoExternalDeliveryTest do
  @moduledoc """
  ADR-0001 invariant "never enable a delivery path capable of reaching a
  real recipient" (checklist 3.4): in every environment the only delivery
  adapter is the local capture adapter, the Swoosh mailer is local-only with
  no API client, and no other module implements the delivery behaviour.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Outreach.Delivery

  @root Path.expand("../../..", __DIR__)

  defp config(env) do
    @root |> Path.join("config/config.exs") |> Config.Reader.read!(env: env, target: :host)
  end

  test "the delivery adapter is the capture adapter and cannot be configured" do
    assert Delivery.adapter() == Delivery.CaptureAdapter
    previous = Application.get_env(:sdr_agent, :delivery_adapter)
    Application.put_env(:sdr_agent, :delivery_adapter, Swoosh.Adapters.SMTP)

    try do
      assert Delivery.adapter() == Delivery.CaptureAdapter
    after
      if previous,
        do: Application.put_env(:sdr_agent, :delivery_adapter, previous),
        else: Application.delete_env(:sdr_agent, :delivery_adapter)
    end
  end

  test "no environment configures an external delivery adapter or an HTTP mail client" do
    for env <- [:dev, :test, :prod] do
      config = config(env)
      sdr = Keyword.get(config, :sdr_agent, [])
      mailer = Keyword.get(sdr, SdrAgent.Mailer, [])

      assert mailer[:adapter] in [Swoosh.Adapters.Local, Swoosh.Adapters.Test], "#{env} mailer"

      assert Keyword.get(Keyword.get(config, :swoosh, []), :api_client, false) == false,
             "#{env} api_client"

      refute Keyword.has_key?(sdr, :delivery_adapter), "#{env} delivery_adapter"
      refute Keyword.has_key?(sdr, :capture_faults), "#{env} capture_faults"
    end

    runtime = File.read!(Path.join(@root, "config/runtime.exs"))

    for line <- String.split(runtime, "\n"),
        not String.starts_with?(String.trim_leading(line), "#") do
      refute line =~ ~r/adapter:|api_client|Swoosh\.Adapters\./, "runtime.exs: #{line}"
    end
  end

  test "only the capture adapter implements the delivery behaviour" do
    {:ok, modules} = :application.get_key(:sdr_agent, :modules)

    implementations =
      Enum.filter(modules, fn module ->
        Delivery.Adapter in (module.module_info(:attributes)[:behaviour] || [])
      end)

    assert implementations == [Delivery.CaptureAdapter]
    assert SdrAgent.Outreach.DeliveryOperation.providers() == [:capture]
  end
end
