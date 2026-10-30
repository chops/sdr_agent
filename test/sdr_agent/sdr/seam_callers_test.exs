defmodule SdrAgent.SDR.SeamCallersTest do
  @moduledoc """
  Test-seam builds only (D-268, Codex GO in review 88558f94): Jido's
  timeout worker is a bare `spawn_monitor`, so an action process loses the
  runner's `$callers` and with it the per-process prototype runtime and
  frozen clock. `SdrAgent.SDR.SeamCallers` carries the runner's ancestry in
  the Jido context and the action adopts it, keeping its own callers first.
  """
  use SdrAgent.PrototypeCase, async: false

  @seam SdrAgent.SDR.SeamCallers

  defmodule Probe do
    @moduledoc false
    use Jido.Action, name: "seam_callers_probe", schema: []

    @impl Jido.Action
    def run(_params, context) do
      if context[:adopt?], do: apply(SdrAgent.SDR.SeamCallers, :adopt, [context])

      {:ok,
       %{
         runtime: SdrAgent.Prototype.runtime(),
         clock: SdrAgent.Clock.source(),
         callers: Process.get(:"$callers", [])
       }}
    end
  end

  setup do
    bound!()
    SdrAgent.Clock.freeze(~U[2026-10-30 17:00:00Z])
    on_exit(&SdrAgent.Clock.unfreeze/0)
    :ok
  end

  defp probe(context), do: Jido.Exec.run(Probe, %{}, context, timeout: 5_000)

  test "the Jido timeout worker drops the caller's ancestry (the boundary)" do
    assert SdrAgent.Prototype.runtime() == :prototype
    assert {:ok, %{runtime: :ordinary, clock: :system_utc}} = probe(%{})
  end

  test "an adopted runner ancestry restores the runtime and clock, own callers first" do
    assert Code.ensure_loaded?(@seam), "SdrAgent.SDR.SeamCallers is not built"
    context = apply(@seam, :context, [])
    assert [runner | _] = context[:sdr_seam_callers]
    assert runner == self()

    assert {:ok, %{runtime: :prototype, clock: :test_fixed, callers: callers}} =
             probe(Map.put(context, :adopt?, true))

    assert List.last(callers) == self() or self() in callers
    refute hd(callers) == self()
  end

  test "a context without ancestry, or with non-pids, changes nothing" do
    assert Code.ensure_loaded?(@seam), "SdrAgent.SDR.SeamCallers is not built"

    for context <- [%{adopt?: true}, %{adopt?: true, sdr_seam_callers: [:x, "y", 1]}] do
      assert {:ok, %{runtime: :ordinary}} = probe(context)
    end
  end
end
