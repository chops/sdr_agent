defmodule SdrAgent.Prototype.ContainmentGuardHappyVmTest do
  @moduledoc """
  The `:ok` happy path of `ContainmentGuard.guard(:import)` (D-237 S4
  K0/guard RED packet r1, test K-H1; packet OPEN item O-3).

  The shared test VM starts `SdrAgentWeb.Endpoint` (application.ex
  children), and the guard's view row "endpoint" is
  `Process.whereis(SdrAgentWeb.Endpoint)` (plan r3 section 4), so a shared-VM
  `:ok` is not expected; the guard test protocol cannot force `:ok` (packet
  section 3: refusal-only). This test therefore runs the guard in a FRESH
  test-environment VM that starts no application: `mix run --no-start` on
  an owned build path, with the B2 step (`:opentelemetry` started), SafeLog
  attached (`file: nil`, the reviewed filter head) and
  `ERL_CRASH_DUMP_BYTES` "0", in a spawned process that adopts the
  `:import` token and calls the guard.

  It prints one closed summary line (`ok`, `refused:<closed code>`,
  `unknown` for an error outside `codes/0`, `token_refused`, `raised`,
  `timeout`); no env value is read or printed.
  Every `OTEL_` name and `PHX_SERVER` are unset in the child's
  environment (names only are read here).

  That the test configuration passes rows 5-12 in such a VM is ASSUMED by
  plan r3 IT-N1 ("a valid token passes under the test config"); a closed
  refusal here after GREEN is a STOP for C4, not a reason to weaken this
  assertion.
  """
  use ExUnit.Case, async: false

  @moduletag :external
  @moduletag timeout: 1_800_000

  @script ~S"""
  summary = fn
    :ok -> "ok"
    {:error, code} ->
      if code in SdrAgent.Prototype.ContainmentGuard.codes(),
        do: "refused:" <> Atom.to_string(code),
        else: "unknown"

    :token_refused -> "token_refused"
    _other -> "raised"
  end

  verdict = fn ->
    try do
      case SdrAgent.Prototype.Containment.put_entry(:import) do
        :ok -> SdrAgent.Prototype.ContainmentGuard.guard(:import)
        _refused -> :token_refused
      end
    rescue
      _error -> :raised
    catch
      _kind, _reason -> :raised
    end
  end

  line =
    try do
      # This child only: the accepted OG-2 prototype settings, before
      # OpenTelemetry starts (Codex 872f565d V-2); shared config unchanged.
      :ok =
        Application.put_all_env(
          opentelemetry: [
            traces_exporter: :none,
            span_processor: :undefined,
            processors: [],
            sampler: :always_off
          ],
          sdr_agent: [otel_capture_content: false]
        )

      {:ok, _apps} = Application.ensure_all_started(:opentelemetry)
      :ok = SdrAgent.Prototype.SafeLog.attach(file: nil)
      System.put_env("ERL_CRASH_DUMP_BYTES", "0")
      parent = self()
      spawn(fn -> send(parent, {:verdict, verdict.()}) end)

      receive do
        {:verdict, result} -> summary.(result)
      after
        10_000 -> "timeout"
      end
    rescue
      _error -> "raised"
    catch
      _kind, _reason -> "raised"
    end

  IO.write("D237-HAPPY:" <> line <> "\n")
  """

  test "a fresh no-start test VM: an adopted :import token and the guard give :ok" do
    build = SdrAgent.PrototypeOutreachFixtures.exclusive_root!("d237-guard-happy")

    unset =
      for name <- Map.keys(System.get_env()),
          String.starts_with?(name, "OTEL_") or name == "PHX_SERVER",
          do: {name, nil}

    env = [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", build} | unset]
    {_deps, deps_status} = System.cmd("mix", ["deps.compile"], env: env, stderr_to_stdout: true)
    assert deps_status == 0, "deps.compile failed in the owned build path"

    {out, status} =
      System.cmd("mix", ["run", "--no-start", "-e", @script], env: env, stderr_to_stdout: true)

    assert status == 0, "the fresh VM did not exit 0"
    lines = Enum.filter(String.split(out, "\n"), &String.starts_with?(&1, "D237-HAPPY:"))
    assert lines == ["D237-HAPPY:ok"], "the fresh-VM guard did not pass: #{inspect(lines)}"
  end
end
