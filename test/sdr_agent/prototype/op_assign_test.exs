defmodule SdrAgent.Prototype.OpAssignTest do
  @moduledoc """
  `mix sdr.prototype.op assign` (D-268 M7; interfaces r6 IF-2 task kind):
  `execute/2` assigns through `SdrAgent.SDR.assign_lead/2` as the bound
  operator, and every other command stays unimplemented; the terminal body
  enters Session with the insert-only Oban and never supplies an owner.

  The full assign → research → draft path (a seeded campaign and an
  imported lead) is the journey test's G4; it needs the seed write (M4).
  Synthetic ids only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.Session

  @op Mix.Tasks.Sdr.Prototype.Op
  @source "lib/mix/tasks/sdr.prototype.op.ex"

  defp assign(lead, campaign),
    do: %{command: :assign, agent: :codex_cli, lead: lead, campaign: campaign}

  test "the bound operator assigning an unknown lead is refused not_found" do
    fx = bound!()

    assert @op.execute(assign(Ecto.UUID.generate(), Ecto.UUID.generate()), fx.actor) ==
             {:error, :not_found}
  end

  test "every other command stays unimplemented" do
    fx = bound!()

    assert @op.execute(%{command: :status, agent: :codex_cli}, fx.actor) ==
             {:error, :not_implemented}
  end

  test "Session's insert-only Oban config keeps the base and disables queues, plugins, peer and stager" do
    base = [
      repo: SdrAgent.Repo,
      queues: [research: 2],
      plugins: [Oban.Plugins.Pruner],
      peer: Oban.Peers.Database
    ]

    config = Session.insert_only_config(base)

    assert Keyword.fetch!(config, :repo) == SdrAgent.Repo
    assert Keyword.fetch!(config, :queues) == false
    assert Keyword.fetch!(config, :plugins) == false
    assert Keyword.fetch!(config, :peer) == false
    assert Keyword.fetch!(config, :stage_interval) == :infinity
  end

  # Op seed retry (Codex ACK 0c257de5): exactly two literal Session.enter
  # calls, assign enqueuing and seed not; neither ever supplies an owner.
  test "source: assign enters Session enqueuing, seed without, and no owner is ever supplied" do
    {:ok, ast} = @source |> File.read!() |> Code.string_to_quoted()

    code =
      Macro.prewalk(ast, fn
        {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :shortdoc] -> nil
        node -> node
      end)

    {_ast, enters} =
      Macro.prewalk(code, [], fn
        {{:., _, [{:__aliases__, _, [:Session]}, :enter]}, _, [opts]} = node, acc ->
          {node, [opts | acc]}

        node, acc ->
          {node, acc}
      end)

    assert [_, _] = enters, "#{@source}: expected exactly two Session.enter calls"
    assert enters |> Enum.map(&Keyword.fetch!(&1, :enqueue?)) |> Enum.sort() == [false, true]
    refute Macro.to_string(code) =~ "owner_user_id"
  end
end
