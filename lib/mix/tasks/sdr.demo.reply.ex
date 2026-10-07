defmodule Mix.Tasks.Sdr.Demo.Reply do
  @shortdoc "Posts a signed simulated reply or provider event to the local webhook (dev/test only)"

  @moduledoc """
  Sends one correctly signed simulated provider event (`capture_sim`) for
  the latest delivered message of a demo lead to the *running local
  server's* webhook (`SdrAgent.Demo.Replies`):

      mix sdr.demo.reply --lead 01 --kind interested
      mix sdr.demo.reply --lead 01 --kind unsubscribe
      mix sdr.demo.reply --lead 02 --kind unsubscribe_link --url http://127.0.0.1:4120

  Kinds: #{Enum.map_join(SdrAgent.Demo.Replies.kinds(), ", ", &"`#{&1}`")}.
  `--lead` is the fixture key ("01"…"10"); the lead must have an accepted
  delivery. Refuses to run outside `MIX_ENV=dev` or `test` and to post
  anywhere but a local host. It reads the database (repo only — no Oban
  queues, no HTTP listener in this VM) to find the delivery; the server
  processes the event. No mail system is involved.
  """
  use Mix.Task

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Replies
  alias SdrAgent.Outreach.DeliveryOperation

  @switches [lead: :string, kind: :string, url: :string]

  @doc false
  @impl Mix.Task
  def run(args) do
    unless allowed_env?(Mix.env()) do
      Mix.raise("mix sdr.demo.reply runs only in dev and test (MIX_ENV=#{Mix.env()})")
    end

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    kind = parse_kind(opts[:kind])
    index = parse_lead(opts[:lead])

    Mix.Task.run("app.config")
    oban = Application.get_env(:sdr_agent, Oban, [])
    Application.put_env(:sdr_agent, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Mix.Task.run("app.start")

    delivery = latest_delivery!(Enum.at(Fixtures.leads(), index))

    case Replies.post(kind, delivery, base_url: opts[:url] || "http://127.0.0.1:4120") do
      {:ok, status} -> Mix.shell().info("#{kind} for delivery #{delivery.id}: HTTP #{status}")
      {:error, reason} -> Mix.raise("demo event not sent: #{inspect(reason)}")
    end
  end

  @doc "True for the Mix environments the demo reply may run in."
  @spec allowed_env?(atom()) :: boolean()
  def allowed_env?(env), do: env in [:dev, :test]

  defp parse_kind(kind) do
    Enum.find(Replies.kinds(), &(Atom.to_string(&1) == kind)) ||
      Mix.raise("--kind must be one of #{Enum.map_join(Replies.kinds(), ", ", &to_string/1)}")
  end

  defp parse_lead(key) do
    with key when is_binary(key) <- key,
         {n, ""} when n in 1..10 <- Integer.parse(key) do
      n - 1
    else
      _ -> Mix.raise("--lead must be a fixture key 01..10")
    end
  end

  defp latest_delivery!(%{contact_id: contact_id}) do
    {:ok, tenant_id} = Kernel.singleton_tenant_id()

    DeliveryOperation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and recipient_contact_id == ^contact_id and
        state in [:accepted, :delivered]
    )
    |> Ash.Query.sort(accepted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
    |> case do
      nil -> Mix.raise("that lead has no delivered message yet")
      delivery -> delivery
    end
  end
end
