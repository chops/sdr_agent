defmodule SdrAgent.JidoSpikeTest do
  use ExUnit.Case, async: false

  test "a Jido agent runs an action and commits fake-model structured output" do
    assert Code.ensure_loaded?(SdrAgent.JidoSpike),
           "S1 spike implementation must provide SdrAgent.JidoSpike"

    assert {:ok,
            %{
              action_result: 42,
              structured_output: %{answer: "qualified", score: 42}
            }} = SdrAgent.JidoSpike.run()
  end

  test "the lock retains the reviewed Jido compatibility set" do
    lock = Mix.Dep.Lock.read()

    assert {:git, "https://github.com/agentjido/jido.git",
            "8c75f94958cad682834af787cb164536c5b513ea", jido_opts} = lock[:jido]

    assert jido_opts[:ref] == "8c75f94958cad682834af787cb164536c5b513ea"

    assert {:git, "https://github.com/agentjido/jido_action.git",
            "af16008f79e8b76d3f3995935b1366bb2a0d7031", action_opts} =
             lock[:jido_action]

    assert action_opts[:ref] == "af16008f79e8b76d3f3995935b1366bb2a0d7031"

    assert {:git, "https://github.com/agentjido/jido_ai.git",
            "b6fbd846f58f7629a0a68b2209f67848e242bdfe", ai_opts} = lock[:jido_ai]

    assert ai_opts[:ref] == "b6fbd846f58f7629a0a68b2209f67848e242bdfe"
    assert {:hex, :jido_signal, "3.0.0-beta.4", _, _, _, "hexpm", _} = lock[:jido_signal]
    assert {:hex, :zoi, "0.18.10", _, _, _, "hexpm", _} = lock[:zoi]
  end
end
