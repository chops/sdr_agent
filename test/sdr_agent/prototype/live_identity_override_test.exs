defmodule SdrAgent.Prototype.LiveIdentityOverrideTest do
  @moduledoc """
  The consumer of the test-build live-identity seam
  (`SdrAgent.Prototype.Authority.TestSeam.put_live_identity/1`, B1b
  storage), directly over the real `bind/1`: `check_live/0` must SEE the
  override, so the drift cases of S2 and S3 can rely on it.

  - each override (`database`, `database_oid`, `system_identifier`) makes
    `check_live/0` a `:binding_mismatch`, and `:raise` (an unavailable
    identity) denies as a mismatch too;
  - a Task of the caller sees the caller's override (`$callers`); an
    unrelated process's override does not affect this process;
  - `clear/0` removes the override, and the exact snapshot then checks
    `:ok` again.

  The seam exists only in a test-seam build (compile-time
  `:prototype_test_seams`). Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Authority.TestSeam

  test "each overridden identity field, and an unavailable identity, is a mismatch" do
    fx = bound!()
    assert Prototype.check_live() == :ok, "prerequisite: the exact binding was not :ok"

    for override <- [
          %{database: "sdr_agent_dev"},
          %{database_oid: fx.snapshot.database_oid + 1},
          %{system_identifier: fx.snapshot.system_identifier + 1},
          :raise
        ] do
      assert PrototypeFixtures.put_live_identity(override) == :ok
      result = Prototype.check_live()

      assert result == {:error, :binding_mismatch},
             "override #{inspect(override)}: got #{inspect(result)}"
    end
  end

  test "a Task of the caller sees the caller's override; an unrelated process's does not count" do
    _fx = bound!()
    parent = self()

    unrelated =
      spawn(fn ->
        PrototypeFixtures.put_live_identity(%{database_oid: 1})
        send(parent, :set)
        receive do: (:done -> :ok)
      end)

    on_exit(fn -> Process.exit(unrelated, :kill) end)
    assert_receive :set, 2_000
    assert Prototype.check_live() == :ok, "an unrelated process's override was seen"
    send(unrelated, :done)

    assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok
    in_task = Task.async(fn -> Prototype.check_live() end) |> Task.await()

    assert in_task == {:error, :binding_mismatch},
           "a Task did not see its caller's override: #{inspect(in_task)}"
  end

  test "clear/0 removes the override; the exact snapshot checks :ok again" do
    fx = bound!()
    assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok
    overridden = Prototype.check_live()
    assert overridden == {:error, :binding_mismatch}, "override not seen: #{inspect(overridden)}"

    assert TestSeam.clear() == :ok
    enter!(fx)
    assert Prototype.check_live() == :ok
  end
end
