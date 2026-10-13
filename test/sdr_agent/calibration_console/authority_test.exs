defmodule SdrAgent.CalibrationConsole.AuthorityTest do
  @moduledoc """
  R0-07 slice E, packet 8.2 (R10-1, step 4-7; entity PASS in round 11 at
  9190c06, 8.7 `CalibrationAuthority`), sub-slice d1a: the sealed one-shot
  calibration authority registry. Test-seam builds only.

    * `Authority.start_link/1` owns a protected ETS table and generates the
      console instance id (`instance/0`) at start.
    * `issue(binding)` registers an entry under an unguessable key binding
      invocation, run, tenant and profile ids, the command pid, the private
      server pid, the prompt and schema commitments and the console
      instance; it returns only an opaque reference.
    * `consume(ref, claims)`, called in the server process, requires an
      unconsumed entry, `self()` equal to the bound server, the claimed
      caller equal to the bound command, and every claimed id, hash and the
      instance equal to the bound ones; on success the entry is consumed
      before any launch. Any mismatch is refused and leaves the entry
      unconsumed. A consumed entry is never usable again.
    * `revoke(ref)` removes the entry; it is also removed when the command
      or the server dies.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.CalibrationConsole.Authority

  setup do
    assert Code.ensure_loaded?(Authority), "SdrAgent.CalibrationConsole.Authority is not defined"
    start_supervised!(Authority)
    server = spawn_server()
    binding = binding_for(server)
    %{server: server, binding: binding}
  end

  test "the console instance is generated at start", _ctx do
    assert Authority.instance() =~ ~r/\A[0-9a-f]{32}\z/
  end

  test "issue returns only an opaque reference", ctx do
    assert {:ok, ref} = Authority.issue(ctx.binding)
    rendered = inspect(ref)

    for value <- [ctx.binding.invocation_id, ctx.binding.prompt_sha256, Authority.instance()] do
      refute rendered =~ value, "the reference reveals #{value}"
    end
  end

  test "the matching server and caller consume it exactly once", ctx do
    {:ok, ref} = Authority.issue(ctx.binding)
    assert consume_in(ctx.server, ref, claims(ctx.binding)) == :ok
    assert consume_in(ctx.server, ref, claims(ctx.binding)) == {:error, :real_model_staged}
  end

  test "any mismatch is refused and leaves the entry unconsumed", ctx do
    {:ok, ref} = Authority.issue(ctx.binding)
    good = claims(ctx.binding)

    for {key, value} <- [
          caller: spawn_owned(fn -> :ok end),
          invocation_id: Ash.UUIDv7.generate(),
          run_id: Ash.UUIDv7.generate(),
          tenant_id: Ash.UUIDv7.generate(),
          profile_id: :claude_cli_sonnet,
          prompt_sha256: String.duplicate("a", 64),
          schema_sha256: String.duplicate("b", 64),
          instance: String.duplicate("c", 32)
        ] do
      assert consume_in(ctx.server, ref, Map.put(good, key, value)) ==
               {:error, :real_model_staged},
             inspect(key)
    end

    # Another process than the bound server.
    other = spawn_server()
    assert consume_in(other, ref, good) == {:error, :real_model_staged}

    # Still unconsumed: the matching call succeeds.
    assert consume_in(ctx.server, ref, good) == :ok
  end

  test "forged and malformed references are refused", ctx do
    {:ok, _ref} = Authority.issue(ctx.binding)

    for forged <- [nil, make_ref(), "ref", :crypto.strong_rand_bytes(32), %{}, {:authority, 1}] do
      assert consume_in(ctx.server, forged, claims(ctx.binding)) ==
               {:error, :real_model_staged},
             inspect(forged)
    end
  end

  test "a malformed binding is never issued", ctx do
    for bad <- [
          Map.delete(ctx.binding, :server_pid),
          %{ctx.binding | command_pid: :nope},
          %{ctx.binding | invocation_id: "not-a-uuid"},
          %{ctx.binding | prompt_sha256: "short"},
          %{ctx.binding | instance: "another"},
          Map.put(ctx.binding, :extra, 1)
        ] do
      assert Authority.issue(bad) == {:error, :invalid_binding}, inspect(bad)
    end
  end

  # Removal is observed without mutating the entry: the registry's table
  # (read-only from here) holds the issued row until it is removed
  # (Codex 01a135f7).
  test "revocation removes the row", ctx do
    {:ok, ref} = Authority.issue(ctx.binding)
    assert entries() == 1
    assert :ok = Authority.revoke(ref)
    assert entries() == 0
    assert consume_in(ctx.server, ref, claims(ctx.binding)) == {:error, :real_model_staged}
  end

  for state <- [:unconsumed, :consumed], dies <- [:command, :server] do
    test "an #{state} entry is removed when the #{dies} dies", ctx do
      command = spawn_owned(fn -> receive do: (:exit -> :ok) end)
      binding = %{ctx.binding | command_pid: command}
      {:ok, ref} = Authority.issue(binding)

      if unquote(state) == :consumed,
        do: assert(consume_in(ctx.server, ref, claims(binding)) == :ok)

      assert entries() == 1, "the issued row must exist before the death"
      victim = if unquote(dies) == :command, do: command, else: ctx.server
      await_down(victim, fn -> send(victim, :exit) end)

      assert await(fn -> entries() == 0 end), "the row was not removed on #{unquote(dies)} death"

      # Only then: no process can use the reference.
      assert consume_in(spawn_server(), ref, claims(binding)) == {:error, :real_model_staged}
    end
  end

  test "the registry table is protected: only its owner writes it", _ctx do
    table = Authority.table()
    assert :ets.info(table, :protection) == :protected

    assert_raise ArgumentError, fn -> :ets.insert(table, {:forged, %{}}) end
  end

  ## Fixtures

  defp binding_for(server) do
    %{
      invocation_id: Ash.UUIDv7.generate(),
      run_id: Ash.UUIDv7.generate(),
      tenant_id: Ash.UUIDv7.generate(),
      profile_id: :claude_cli_opus,
      command_pid: self(),
      server_pid: server,
      prompt_sha256: sha("prompt"),
      schema_sha256: sha("schema"),
      instance: Authority.instance()
    }
  end

  # What the server checks for one call: its caller and the request.
  defp claims(binding) do
    binding
    |> Map.take([
      :invocation_id,
      :run_id,
      :tenant_id,
      :profile_id,
      :prompt_sha256,
      :schema_sha256
    ])
    |> Map.merge(%{caller: binding.command_pid, instance: binding.instance})
  end

  # A stand-in server process: consumes in itself and reports back.
  defp spawn_server, do: spawn_owned(fn -> server_loop() end)

  # Every fixture process is stopped when the test ends, pass or fail.
  defp spawn_owned(fun) do
    pid = spawn(fun)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # The size of the registry's protected table (a read, never a write).
  defp entries, do: :ets.info(Authority.table(), :size)

  defp server_loop do
    receive do
      {:consume, from, ref, claims} ->
        send(from, {:consumed, Authority.consume(ref, claims)})
        server_loop()

      :exit ->
        :ok
    end
  end

  defp consume_in(server, ref, claims) do
    send(server, {:consume, self(), ref, claims})
    assert_receive {:consumed, result}, 5_000
    result
  end

  defp await_down(pid, stop) do
    monitor = Process.monitor(pid)
    stop.()
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end

  defp await(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && await(check, attempts - 1)
    end
  end

  defp sha(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)
end
