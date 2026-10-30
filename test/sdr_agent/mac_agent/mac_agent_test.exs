defmodule SdrAgent.MacAgentTest do
  @moduledoc "S-B7 synthetic contracts: no provider calls, credentials or retained database access."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
  alias SdrAgent.ChildEnv
  alias SdrAgent.MacAgent.Agent
  alias SdrAgent.MacAgent.Client
  alias SdrAgent.MacAgent.Config
  alias SdrAgent.MacAgent.Journal
  alias SdrAgent.MacAgent.Launch
  alias SdrAgent.Test.PinnedCLI

  @call_id "01a18dd4-aeee-7e4a-8185-2e36a991d2b0"
  @nonce String.duplicate("a", 32)
  @digest String.duplicate("b", 64)
  @token "synthetic-worker-token-not-a-provider-credential"

  setup do
    root = Path.join(System.tmp_dir!(), "sdr-mac-agent-#{Ecto.UUID.generate()}")
    bin = Path.join([root, "fixture-store", "fake-cli", "bin"])
    File.mkdir_p!(bin)
    File.chmod!(root, 0o700)
    executable = Path.join(bin, "claude-code")
    File.write!(executable, "#!/bin/sh\nexit 91\n")
    File.chmod!(executable, 0o700)
    previous = Application.get_env(:sdr_agent, PinnedExecutable)
    PinnedCLI.inject_identity!(executable, store: Path.join(root, "fixture-store"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, PinnedExecutable, previous),
        else: Application.delete_env(:sdr_agent, PinnedExecutable)

      File.rm_rf!(root)
    end)

    %{
      root: root,
      executable: executable,
      settings: %{
        "base_url" => "https://sdr.example.test",
        "token" => @token,
        "executable" => executable,
        "journal_dir" => Path.join(root, "journal"),
        "profile_id" => "claude_cli_opus"
      }
    }
  end

  describe "private configuration and closed pins" do
    test "uses a reviewed local executable without exposing the worker token", ctx do
      assert {:ok, config} = invoke(Config, :new, [ctx.settings])
      refute inspect(config) =~ @token
      assert config.base_url == "https://sdr.example.test"
      assert config.pins["profile_id"] == "claude_cli_opus"
      assert config.pins["model_id"] == "claude-opus-5-5"
      assert config.pins["cli_version"] == "2.1.294"
      assert config.pins["executable_sha256"] == sha(File.read!(ctx.executable))
    end

    test "refuses HTTP, URL credentials, query strings and fragments", ctx do
      for url <- [
            "http://sdr.example.test",
            "https://user:password@sdr.example.test",
            "https://sdr.example.test?token=leak",
            "https://sdr.example.test/#fragment"
          ] do
        assert {:error, :invalid_config} =
                 invoke(Config, :new, [Map.put(ctx.settings, "base_url", url)])
      end
    end

    test "refuses unknown configuration, fake profiles and header injection", ctx do
      for settings <- [
            Map.put(ctx.settings, "command", "arbitrary"),
            Map.put(ctx.settings, "profile_id", "fake"),
            Map.put(ctx.settings, "profile_id", "unreviewed-model"),
            Map.put(ctx.settings, "token", "bad\r\nInjected: yes")
          ] do
        assert {:error, :invalid_config} = invoke(Config, :new, [settings])
      end
    end

    test "refuses a different executable rather than falling back to PATH", ctx do
      assert {:error, :invalid_pin} =
               invoke(Config, :new, [Map.put(ctx.settings, "executable", "/bin/sh")])
    end

    test "loads only private regular JSON settings files", ctx do
      path = Path.join(ctx.root, "settings.json")
      File.write!(path, Jason.encode!(ctx.settings))
      File.chmod!(path, 0o600)
      assert {:ok, _} = invoke(Config, :load, [path])
      File.chmod!(path, 0o644)
      assert {:error, :unsafe_config_file} = invoke(Config, :load, [path])
      File.chmod!(path, 0o600)
      link = Path.join(ctx.root, "link.json")
      File.ln_s!(path, link)
      assert {:error, :unsafe_config_file} = invoke(Config, :load, [link])
    end
  end

  describe "durable launch-once journal" do
    test "exactly one local process wins the exclusive launching marker", ctx do
      root = ctx.settings["journal_dir"]
      assert :ok = invoke(Journal, :prepare, [root])

      results =
        1..12
        |> Enum.map(fn _ ->
          Task.async(fn -> invoke(Journal, :launch_once, [root, @call_id, @nonce]) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_launched})) == 11
      assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700
    end

    test "a fresh process never relaunches a recorded launching call", ctx do
      root = ctx.settings["journal_dir"]
      assert :ok = invoke(Journal, :prepare, [root])
      assert :ok = invoke(Journal, :launch_once, [root, @call_id, @nonce])

      assert {:error, :already_launched} =
               Task.async(fn -> invoke(Journal, :launch_once, [root, @call_id, @nonce]) end)
               |> Task.await()

      assert {:error, :already_launched} =
               invoke(Journal, :launch_once, [root, @call_id, String.duplicate("c", 32)])
    end

    test "journal persists only identifiers, privately", ctx do
      root = ctx.settings["journal_dir"]
      assert :ok = invoke(Journal, :prepare, [root])
      assert :ok = invoke(Journal, :launch_once, [root, @call_id, @nonce])
      assert :ok = invoke(Journal, :reported, [root, @call_id, @nonce])

      for path <- Path.wildcard(Path.join(root, "*")), File.regular?(path) do
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
        bytes = File.read!(path)
        refute bytes =~ @token
        refute bytes =~ "Synthetic private prospect"
      end
    end

    test "rejects unsafe paths and never follows a launching-marker symlink", ctx do
      root = ctx.settings["journal_dir"]
      assert :ok = invoke(Journal, :prepare, [root])

      assert {:error, :invalid_identity} =
               invoke(Journal, :launch_once, [root, "../escape", @nonce])

      target = Path.join(ctx.root, "outside")
      File.write!(target, "unchanged")
      File.ln_s!(target, Path.join(root, @call_id <> ".launching"))
      assert {:error, :unsafe_journal} = invoke(Journal, :launch_once, [root, @call_id, @nonce])
      assert File.read!(target) == "unchanged"
    end

    test "does not relax an existing journal directory's permissions", ctx do
      root = ctx.settings["journal_dir"]
      File.mkdir!(root)
      File.chmod!(root, 0o755)
      assert {:error, :unsafe_journal} = invoke(Journal, :prepare, [root])
      assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o755
    end
  end

  describe "closed CLI input and transient prompt" do
    test "argv is local allowlisted code, never a server-provided command" do
      assert {:ok, argv} = invoke(Launch, :argv, [call()])
      assert ["-p", "--output-format", "stream-json", "--verbose" | _] = argv
      assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.member?(["--tools", ""])
      assert "--safe-mode" in argv
      assert "--restricted" in argv
      assert "--no-session-persistence" in argv
      assert "--disable-slash-commands" in argv
      assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.member?(["--model", "opus"])
      refute "Synthetic private prospect" in argv
    end

    test "unknown models and server executable/argv fields are rejected" do
      for input <- [
            Map.put(call(), "model_id", "claude-unreviewed"),
            Map.put(call(), "profile_id", "fake"),
            Map.put(call(), "executable", "/bin/sh"),
            Map.put(call(), "argv", ["--tools", "Bash"])
          ] do
        assert {:error, :invalid_call} = invoke(Launch, :argv, [input])
      end
    end

    test "expired, malformed and oversized launch input is refused" do
      for input <- [
            Map.put(call(), "result_deadline", "2000-01-01T00:00:00Z"),
            Map.put(call(), "call_id", "../../unsafe"),
            Map.put(call(), "request_digest", "bad"),
            Map.put(call(), "schema", []),
            Map.put(call(), "prompt", String.duplicate("x", 1_048_577))
          ] do
        assert {:error, :invalid_call} = invoke(Launch, :argv, [input])
      end
    end

    test "prompt file is private, matches the existing renderer, and is removed", ctx do
      assert {:ok, :checked} =
               invoke(Launch, :with_prompt, [
                 ctx.root,
                 call(),
                 fn path ->
                   assert File.read!(path) ==
                            ClaudeCLI.render_prompt(call()["prompt"], call()["schema"])

                   assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
                   assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
                   send(self(), {:prompt_path, path})
                   :checked
                 end
               ])

      assert_received {:prompt_path, path}
      refute File.exists?(path)
      refute File.exists?(Path.dirname(path))
    end

    test "prompt cleanup also happens when the fixture launcher raises", ctx do
      assert {:error, :launch_failed} =
               invoke(Launch, :with_prompt, [
                 ctx.root,
                 call(),
                 fn path ->
                   send(self(), {:failed_prompt_path, path})
                   raise "synthetic launcher failure, private content must not escape"
                 end
               ])

      assert_received {:failed_prompt_path, path}
      refute File.exists?(path)
    end
  end

  describe "HTTPS worker transport" do
    test "claim uses bearer auth, fresh nonce and local pins", ctx do
      client = client(ctx)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/worker/claim"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"claim_nonce" => @nonce, "pins" => pins} = Jason.decode!(body)
        assert pins["profile_id"] == "claude_cli_opus"
        Req.Test.json(conn, %{"call" => nil})
      end)

      assert {:ok, nil} = invoke(Client, :claim, [client, @nonce])
    end

    test "never follows a redirect or automatically retries an HTTP failure", ctx do
      client = client(ctx)

      for status <- [302, 503] do
        Req.Test.stub(__MODULE__, fn conn ->
          send(self(), {:request_seen, status})

          conn
          |> Plug.Conn.put_resp_header("location", "https://other.example.test")
          |> Plug.Conn.send_resp(status, "private server detail")
        end)

        log =
          capture_log(fn ->
            assert {:error, :remote_refused} = invoke(Client, :claim, [client, @nonce])
          end)

        assert_received {:request_seen, ^status}
        refute_received {:request_seen, ^status}
        refute log =~ @token
        refute log =~ "private server detail"
      end
    end

    test "completes with bound ids and a transcript, not a caller command", ctx do
      client = client(ctx)
      transcript = "synthetic init and result transcript"

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/worker/complete"
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "call_id" => @call_id,
                 "claim_nonce" => @nonce,
                 "request_digest" => @digest,
                 "transcript" => transcript
               }

        Req.Test.json(conn, %{"status" => "accepted"})
      end)

      assert {:ok, :accepted} = invoke(Client, :complete, [client, call(), @nonce, transcript])
    end

    test "heartbeat exposes pins only, never the local executable path", ctx do
      client = client(ctx)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/worker/heartbeat"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"pins" => pins} = Jason.decode!(body)
        refute Map.has_key?(pins, "executable")
        refute body =~ ctx.executable
        Req.Test.json(conn, %{"status" => "ready"})
      end)

      assert :ok = invoke(Client, :heartbeat, [client])
    end
  end

  describe "one outbound worker iteration" do
    test "an empty queue never launches a CLI", ctx do
      assert {:ok, config} = invoke(Config, :new, [ctx.settings])

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/worker/heartbeat" -> Req.Test.json(conn, %{"status" => "ready"})
          "/worker/claim" -> Req.Test.json(conn, %{"call" => nil})
          _ -> flunk("an idle worker must not complete a call")
        end
      end)

      assert {:ok, :idle} = invoke(Agent, :run_once, [config, [plug: {Req.Test, __MODULE__}]])
    end

    test "runs only the pinned synthetic child once and returns its transcript", ctx do
      init =
        ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"2.1.294","tools":[],"mcp_servers":[],"slash_commands":[]})

      result = ~s({"type":"result","is_error":false,"result":"{}","usage":{}})

      File.write!(
        ctx.executable,
        "#!/bin/sh\n/bin/cat >/dev/null\nprintf '%s\\n' '#{init}' '#{result}'\n"
      )

      PinnedCLI.inject_identity!(ctx.executable, store: Path.join(ctx.root, "fixture-store"))
      assert {:ok, config} = invoke(Config, :new, [ctx.settings])

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/worker/heartbeat" ->
            Req.Test.json(conn, %{"status" => "ready"})

          "/worker/claim" ->
            Req.Test.json(conn, %{"call" => call()})

          "/worker/complete" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            payload = Jason.decode!(body)
            assert payload["call_id"] == @call_id
            assert payload["request_digest"] == @digest
            assert payload["transcript"] =~ init
            assert payload["transcript"] =~ result
            send(self(), :fixture_completed)
            Req.Test.json(conn, %{"status" => "accepted"})
        end
      end)

      log =
        capture_log(fn ->
          assert {:ok, :completed} =
                   invoke(Agent, :run_once, [config, [plug: {Req.Test, __MODULE__}]])

          assert_received :fixture_completed

          assert {:error, :already_launched} =
                   invoke(Agent, :run_once, [config, [plug: {Req.Test, __MODULE__}]])

          refute_received :fixture_completed
        end)

      refute log =~ @token
      refute log =~ "Synthetic private prospect"
      refute log =~ init
    end

    test "worker revocation prevents claim and child launch", ctx do
      assert {:ok, config} = invoke(Config, :new, [ctx.settings])

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/worker/heartbeat"
        Plug.Conn.send_resp(conn, 403, "disabled")
      end)

      assert {:error, :unauthorized} =
               invoke(Agent, :run_once, [config, [plug: {Req.Test, __MODULE__}]])
    end
  end

  test "task refuses credential arguments instead of reading them from argv" do
    task = Mix.Tasks.Sdr.MacAgent
    assert Code.ensure_loaded?(task), "S-B7 standalone task is not implemented yet"

    assert_raise Mix.Error, "invalid mac agent options", fn ->
      apply(task, :run, [["--token", @token]])
    end
  end

  test "standalone bootstrap starts HTTP dependencies, not SDR or Postgrex" do
    task = Mix.Tasks.Sdr.MacAgent
    assert Code.ensure_loaded?(task), "S-B7 standalone task is not implemented yet"
    assert function_exported?(task, :bootstrap, 0)
    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))

    code = """
    :ok = Mix.Tasks.Sdr.MacAgent.bootstrap()
    apps = Enum.map(Application.started_applications(), &elem(&1, 0))
    if :sdr_agent in apps or :postgrex in apps or Process.whereis(SdrAgent.Repo),
      do: System.halt(71)
    IO.puts("STANDALONE_OK")
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa" | paths] ++ ["-e", code],
        env: ChildEnv.cmd([]),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "STANDALONE_OK"
  end

  defp client(ctx) do
    assert {:ok, config} = invoke(Config, :new, [ctx.settings])
    assert {:ok, client} = invoke(Client, :new, [config, [plug: {Req.Test, __MODULE__}]])
    refute inspect(client) =~ @token
    client
  end

  defp call do
    %{
      "call_id" => @call_id,
      "profile_id" => "claude_cli_opus",
      "model_id" => "claude-opus-5-5",
      "request_digest" => @digest,
      "prompt" => "Synthetic private prospect",
      "schema" => %{"type" => "object"},
      "result_deadline" => DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
    }
  end

  # RED uses an assertion for the missing public feature, not an undefined
  # function crash; the behavioral assertions above run unchanged in GREEN.
  defp invoke(module, function, args) do
    assert Code.ensure_loaded?(module), "S-B7 #{inspect(module)} is not implemented yet"
    assert function_exported?(module, function, length(args))
    apply(module, function, args)
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
