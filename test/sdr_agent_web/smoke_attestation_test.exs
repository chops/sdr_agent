defmodule SdrAgentWeb.SmokeAttestationTest do
  @moduledoc """
  Review #25 MF2: the scripted browser smoke signs in and approves, so it
  must refuse every instance that is not the attested throw-away smoke
  server — the dev port 4120, a missing or mismatched launcher attestation,
  and an ordinary (non-smoke) loopback instance of the app — before any
  browser starts or anything is sent. The script's refusals run against a
  real loopback listener of this endpoint; they need Node >= 22 (its
  built-in fetch) and are skipped, with that reason, without it.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgentWeb.SmokeAttestation

  @script Path.expand("../browser/golden_path_smoke.mjs", __DIR__)
  @node System.find_executable("node")
  @node_ok @node != nil and
             (case System.cmd(@node, [
                     "-e",
                     "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)"
                   ]) do
                {_, 0} -> true
                _ -> false
              end)

  defp attestation!(nonce) do
    Application.put_env(:sdr_agent, SmokeAttestation, %{nonce: nonce})
    on_exit(fn -> Application.delete_env(:sdr_agent, SmokeAttestation) end)
  end

  defp nonce, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  describe "the attestation endpoint" do
    test "answers nothing unless the smoke launcher configured a nonce", %{conn: conn} do
      conn = get(conn, "/__smoke/attestation")
      assert conn.status == 404
    end

    test "returns the launcher's nonce and the Repo's actual database", %{conn: conn} do
      nonce = nonce()
      attestation!(nonce)

      body = conn |> get("/__smoke/attestation") |> json_response(200)

      assert body == %{
               "nonce" => nonce,
               "database" => Keyword.fetch!(SdrAgent.Repo.config(), :database),
               "env" => "test"
             }
    end

    test "is compiled in only by the test configuration" do
      root = Path.expand("../..", __DIR__)

      for file <- ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs) do
        refute File.read!(Path.join(root, file)) =~ "smoke_attestation_plug", file
      end

      assert File.read!(Path.join(root, "config/test.exs")) =~
               "config :sdr_agent, :smoke_attestation_plug, true"
    end
  end

  describe "the browser smoke script refuses before any browser or request" do
    @describetag skip: if(@node_ok, do: false, else: "needs node >= 22 on PATH")

    setup do
      server =
        start_supervised!(
          {Bandit, plug: SdrAgentWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      dir = Path.expand("../../tmp/smoke", __DIR__)
      File.mkdir_p!(dir)
      file = Path.join(dir, "attestation-#{port}.json")
      on_exit(fn -> File.rm(file) end)

      parent = self()
      handler = "smoke-requests-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:phoenix, :endpoint, :start],
        fn _event, _measurements, %{conn: conn}, _config ->
          send(parent, {:request, conn.method, conn.request_path})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{base: "http://127.0.0.1:#{port}", port: port, attestation_file: file}
    end

    defp run_script(base) do
      System.cmd(@node, [@script, base],
        stderr_to_stdout: true,
        env: [{"CHROME", "/nonexistent/chrome"}]
      )
    end

    defp write_file!(ctx, nonce, database) do
      File.write!(
        ctx.attestation_file,
        Jason.encode!(%{nonce: nonce, port: ctx.port, database: database})
      )
    end

    defp requests do
      receive do
        {:request, method, path} -> [{method, path} | requests()]
      after
        0 -> []
      end
    end

    defp assert_untouched!(ctx, before) do
      assert Enum.all?(requests(), &(&1 == {"GET", "/__smoke/attestation"}))
      assert length(events(ctx.tenant)) == before
    end

    test "the dev server's port 4120", ctx do
      before = length(events(ctx.tenant))
      assert {output, 2} = run_script("http://127.0.0.1:4120")
      assert output =~ "refusing: 4120 is the dev server's port"
      assert requests() == []
      assert_untouched!(ctx, before)
    end

    test "no launcher attestation for the port", ctx do
      before = length(events(ctx.tenant))
      assert {output, 3} = run_script(ctx.base)
      assert output =~ "refusing: no smoke attestation"
      assert requests() == []
      assert_untouched!(ctx, before)
    end

    test "an ordinary loopback instance of the app (no attestation endpoint)", ctx do
      before = length(events(ctx.tenant))
      write_file!(ctx, nonce(), "sdr_agent_test_demo")

      assert {output, 3} = run_script(ctx.base)
      assert output =~ "is not an attested smoke server"
      assert_untouched!(ctx, before)
    end

    test "a server whose nonce differs from the launcher's", ctx do
      before = length(events(ctx.tenant))
      attestation!(nonce())
      write_file!(ctx, nonce(), Keyword.fetch!(SdrAgent.Repo.config(), :database))

      assert {output, 3} = run_script(ctx.base)
      assert output =~ "does not match"
      assert_untouched!(ctx, before)
    end

    test "an attested server on a database that is not a _demo one", ctx do
      before = length(events(ctx.tenant))
      nonce = nonce()
      attestation!(nonce)
      database = Keyword.fetch!(SdrAgent.Repo.config(), :database)
      refute database =~ ~r/_demo$/
      write_file!(ctx, nonce, database)

      assert {output, 3} = run_script(ctx.base)
      assert output =~ "is not a throw-away _demo database"
      assert_untouched!(ctx, before)
    end
  end
end
