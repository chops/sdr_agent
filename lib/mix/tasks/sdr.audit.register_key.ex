defmodule Mix.Tasks.Sdr.Audit.RegisterKey do
  @moduledoc "Registers the pinned public audit-signing key without reading private material."
  @shortdoc "Register the pinned audit-anchor public key"
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, [], []} = OptionParser.parse(argv, strict: [public_key: :string, key_id: :string])
    path = Keyword.get(opts, :public_key, "docs/audit/anchor-signing-key.pub")
    expected_id = Keyword.get(opts, :key_id, System.get_env("SDR_AUDIT_ANCHOR_KEY_ID"))
    {:ok, trusted} = SdrAgent.Audit.TrustedKey.load(path, expected_id)
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()

    case SdrAgent.Audit.register_signing_key(
           %{key_id: trusted.key_id, public_key: trusted.public_key},
           actor: SdrAgent.Actor.system(:kernel, tenant_id)
         ) do
      {:ok, _key} -> Mix.shell().info("registered audit signing key #{trusted.key_id}")
      {:error, reason} -> Mix.raise("key registration failed: #{inspect(reason)}")
    end
  rescue
    MatchError -> Mix.raise("usage: mix sdr.audit.register_key [--public-key PATH] [--key-id ID]")
  end
end
