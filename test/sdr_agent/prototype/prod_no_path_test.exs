defmodule SdrAgent.Prototype.ProdNoPathTest do
  @moduledoc """
  IF-1 production build and IF-2 switch (interfaces r6; amendment item 2
  "Development build only", "The switch"): the authority compile flag is
  set only by `config/dev.exs` and `config/test.exs`, and `runtime.exs`
  refuses the switch outside `dev`. The compiled-artifact proof itself is
  the separate `:external` prod build.
  """
  use ExUnit.Case, async: false

  @flag :prototype_authority_compiled

  defp sets_flag?(file) do
    file |> File.read!() |> String.contains?("#{@flag}: true")
  end

  test "only config/dev.exs and config/test.exs set the authority compile flag" do
    assert sets_flag?("config/dev.exs")
    assert sets_flag?("config/test.exs")
    refute sets_flag?("config/config.exs")
    refute sets_flag?("config/prod.exs")
    refute sets_flag?("config/runtime.exs")
    assert Application.get_env(:sdr_agent, @flag) == true
  end

  test "only config/test.exs sets the test-seam flag" do
    seams = "prototype_test_seams: true"
    assert "config/test.exs" |> File.read!() |> String.contains?(seams)

    for file <- ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs) do
      refute file |> File.read!() |> String.contains?(seams), "#{file} sets the test-seam flag"
    end
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read_runtime(env) do
    Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    :read
  rescue
    error -> {:raised, error}
  end

  test "runtime.exs refuses the switch in test and prod" do
    switch = [
      {"SDR_PROTOTYPE", "d237-prototype/1"},
      {"SDR_PROTOTYPE_INSTANCE", Ecto.UUID.generate()},
      {"DATABASE_URL", "ecto://u:p@localhost/x"},
      {"SECRET_KEY_BASE", String.duplicate("k", 64)},
      {"TOKEN_SIGNING_SECRET", String.duplicate("t", 32)}
    ]

    for env <- [:test, :prod] do
      result = with_env(switch, fn -> read_runtime(env) end)

      assert match?({:raised, %RuntimeError{}}, result),
             "runtime.exs accepted the switch in #{env}: #{inspect(result)}"

      {:raised, error} = result
      assert Exception.message(error) =~ "SDR_PROTOTYPE"
    end
  end

  test "runtime.exs selects the prototype cluster in dev only with a valid switch" do
    instance = Ecto.UUID.generate()

    config =
      with_env(
        [{"SDR_PROTOTYPE", "d237-prototype/1"}, {"SDR_PROTOTYPE_INSTANCE", instance}],
        fn ->
          Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
        end
      )

    repo = get_in(config, [:sdr_agent, SdrAgent.Repo]) || []
    assert repo[:socket_dir] == "/private/tmp/d237-pg"
    assert repo[:port] == 5541
    assert repo[:database] == "sdr_agent_prototype"

    assert get_in(config, [:sdr_agent, SdrAgent.Prototype, :switch]) ==
             %{policy_id: "d237-prototype/1", instance_id: instance}

    bad =
      with_env(
        [{"SDR_PROTOTYPE", "d237-prototype/2"}, {"SDR_PROTOTYPE_INSTANCE", instance}],
        fn ->
          read_runtime(:dev)
        end
      )

    assert match?({:raised, _}, bad), "runtime.exs accepted a wrong policy id in dev"
  end
end
