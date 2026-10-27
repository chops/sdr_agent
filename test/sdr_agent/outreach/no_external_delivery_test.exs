defmodule SdrAgent.Outreach.NoExternalDeliveryTest do
  @moduledoc """
  ADR-0001 invariant "never enable a delivery path capable of reaching a
  real recipient" (checklist 3.4): in every environment the only outreach
  delivery adapter is the local capture adapter and no other module
  implements the delivery behaviour. The Swoosh mailer is local-only in dev
  and test; in prod it may reach Postmark (with `POSTMARK_API_KEY`) for one
  purpose only, the hosted owner's sign-in link, which the magic-link sender
  mails only to addresses on `SDR_LOGIN_ALLOWLIST`; no outreach module uses
  it.
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

  test "no environment configures an external delivery adapter; only prod's sign-in mailer has an HTTP client" do
    for env <- [:dev, :test, :prod] do
      config = config(env)
      sdr = Keyword.get(config, :sdr_agent, [])
      mailer = Keyword.get(sdr, SdrAgent.Mailer, [])

      assert mailer[:adapter] in [Swoosh.Adapters.Local, Swoosh.Adapters.Test], "#{env} mailer"

      # Hosted owner sign-in: prod's mailer may reach Postmark (runtime.exs,
      # only with POSTMARK_API_KEY); dev and test have no HTTP mail client.
      expected_client = if env == :prod, do: Swoosh.ApiClient.Req, else: false

      assert Keyword.get(Keyword.get(config, :swoosh, []), :api_client, false) ==
               expected_client,
             "#{env} api_client"

      refute Keyword.has_key?(sdr, :delivery_adapter), "#{env} delivery_adapter"
      refute Keyword.has_key?(sdr, :capture_faults), "#{env} capture_faults"
    end

    runtime = File.read!(Path.join(@root, "config/runtime.exs"))

    adapter_lines =
      for line <- String.split(runtime, "\n"),
          not String.starts_with?(String.trim_leading(line), "#"),
          line =~ ~r/adapter:|api_client|Swoosh\.Adapters\./,
          do: String.trim(line)

    # The one runtime adapter: the sign-in mailer's Postmark, in the prod block.
    assert adapter_lines == ["adapter: Swoosh.Adapters.Postmark,"]
  end

  test "only the magic-link sender sends through the Swoosh mailer; outreach never does" do
    users =
      for file <- Path.wildcard(Path.join(@root, "lib/**/*.ex")),
          File.read!(file) =~ ~r/SdrAgent\.Mailer|Mailer\.deliver/,
          do: Path.relative_to(file, @root)

    assert Enum.sort(users) == [
             "lib/sdr_agent/accounts/senders/magic_link.ex",
             "lib/sdr_agent/mailer.ex"
           ]
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
