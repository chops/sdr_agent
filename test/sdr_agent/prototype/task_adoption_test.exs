defmodule SdrAgent.Prototype.TaskAdoptionTest do
  @moduledoc """
  The source checks of D-237 task adoption (S1b plan r4, I2 r2): the grammar
  checker's controls on synthetic source strings, the five task files, and
  the TaskBoundary build partition. Source parsing only: nothing here
  compiles, loads or runs a task, and no file is written.

  - The synthetic controls are semantic RED against the deny-only
    `SdrAgent.D237TaskAdoption.violations/2`.
  - The five task files are owned by S1 (setup, provision), S3 (import)
    and S4 (op, serve). They are ABSENT at this lane's base, so their
    cases fail on a structural prerequisite (file absent), not a semantic
    one. They can pass only at integration, after each owner adopts.
  - The partition check reads `task_boundary.ex` and is semantic RED: the
    carried declaration is not gated on `:prototype_authority_compiled`.
    Prod BEAM absence itself is owed by the existing prod artifact proof
    at integration; this is a source check only.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.D237TaskAdoption, as: Adoption

  @tasks [
    setup: "lib/mix/tasks/sdr.prototype.setup.ex",
    provision: "lib/mix/tasks/sdr.prototype.provision.ex",
    import: "lib/mix/tasks/sdr.prototype.import.ex",
    op: "lib/mix/tasks/sdr.prototype.op.ex",
    serve: "lib/mix/tasks/sdr.prototype.serve.ex"
  ]

  @gate "if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do"

  # A synthetic task module for `kind`; `run` is the run/1 clause and
  # `extra` any other module-body source.
  defp module(kind, run, extra \\ "") do
    name = kind |> Atom.to_string() |> Macro.camelize()

    """
    #{@gate}
      defmodule Mix.Tasks.Sdr.Prototype.#{name} do
        @moduledoc "synthetic"
        use Mix.Task
        alias SdrAgent.Prototype.{SafeLog, TaskBoundary}
        @requirements ["app.config"]
        #{extra}
        @impl Mix.Task
        #{run}

        defp body(_argv), do: :ok
      end
    end
    """
  end

  defp good_run(kind) do
    """
    def run(argv) do
        attached = SafeLog.attach(file: nil)
        TaskBoundary.launch(#{inspect(kind)}, attached, fn -> body(argv) end)
      end
    """
  end

  describe "the grammar checker (synthetic sources)" do
    test "RED: the exact two statements, gated, are clean for every task" do
      for {kind, _path} <- @tasks do
        assert Adoption.violations(module(kind, good_run(kind)), kind) == []
      end
    end

    test "RED: fully qualified names are clean too" do
      run = """
      def run(argv) do
          attached = SdrAgent.Prototype.SafeLog.attach(file: nil)
          SdrAgent.Prototype.TaskBoundary.launch(:import, attached, fn -> body(argv) end)
        end
      """

      assert Adoption.violations(module(:import, run), :import) == []
    end

    test "RED: an ungated module is reported" do
      source = """
      defmodule Mix.Tasks.Sdr.Prototype.Import do
        use Mix.Task
        alias SdrAgent.Prototype.{SafeLog, TaskBoundary}
        @requirements ["app.config"]

        def run(argv) do
          attached = SafeLog.attach(file: nil)
          TaskBoundary.launch(:import, attached, fn -> body(argv) end)
        end

        defp body(_argv), do: :ok
      end
      """

      assert Adoption.violations(source, :import) == [:not_gated]
    end

    test "RED: each run/1 shape defect is reported" do
      for run <- [
            # a third statement
            """
            def run(argv) do
                attached = SafeLog.attach(file: nil)
                Mix.Task.run("app.config", [])
                TaskBoundary.launch(:import, attached, fn -> body(argv) end)
              end
            """,
            # the wrong task atom
            """
            def run(argv) do
                attached = SafeLog.attach(file: nil)
                TaskBoundary.launch(:op, attached, fn -> body(argv) end)
              end
            """,
            # a capture instead of a zero-arity fn literal
            """
            def run(_argv) do
                attached = SafeLog.attach(file: nil)
                TaskBoundary.launch(:import, attached, &body/0)
              end
            """,
            # a one-arity fn
            """
            def run(argv) do
                attached = SafeLog.attach(file: nil)
                TaskBoundary.launch(:import, attached, fn _x -> body(argv) end)
              end
            """,
            # the attach result not passed
            """
            def run(argv) do
                attached = SafeLog.attach(file: nil)
                TaskBoundary.launch(:import, :ok, fn -> body(argv) end)
              end
            """,
            # a guard
            """
            def run(argv) when is_list(argv) do
                attached = SafeLog.attach(file: nil)
                TaskBoundary.launch(:import, attached, fn -> body(argv) end)
              end
            """,
            # a second clause
            """
            def run([]), do: :ok

              def run(argv) do
                attached = SafeLog.attach(file: nil)
                TaskBoundary.launch(:import, attached, fn -> body(argv) end)
              end
            """
          ] do
        assert Adoption.violations(module(:import, run), :import) == [:run_shape]
      end
    end

    test "RED: an attach other than attach(file: nil) is reported" do
      for attach <- ["SafeLog.attach()", ~s|SafeLog.attach(file: "/x")|, "SafeLog.attach([])"] do
        run = """
        def run(argv) do
            attached = #{attach}
            TaskBoundary.launch(:import, attached, fn -> body(argv) end)
          end
        """

        assert Adoption.violations(module(:import, run), :import) == [:attach_form]
      end
    end

    test "ADR-0022: non-config or duplicate requirements are reported" do
      source = module(:import, good_run(:import), ~s|@requirements ["app.start"]|)
      assert Adoption.violations(source, :import) == [:requirements]
    end

    test "ADR-0022: requirements must be one literal app.config before every function" do
      good = module(:import, good_run(:import))
      required = ~s|@requirements ["app.config"]|

      for replacement <- [
            "",
            ~s|@requirements ["app.start"]|,
            ~s|@requirements ["app.config", "app.start"]|,
            "@requirements required_tasks()",
            required <> "\n" <> required
          ] do
        assert Adoption.violations(String.replace(good, required, replacement), :import) ==
                 [:requirements]
      end

      missing = String.replace(good, required, "")

      late =
        String.replace(
          missing,
          "defp body(_argv), do: :ok",
          "defp body(_argv), do: :ok\n" <> required
        )

      nested =
        String.replace(
          missing,
          "defp body(_argv), do: :ok",
          "defp body(_argv) do\n" <> required <> "\n:ok\nend"
        )

      early = String.replace(missing, "use Mix.Task", required <> "\nuse Mix.Task")

      for source <- [late, nested, early] do
        assert Adoption.violations(source, :import) == [:requirements]
      end
    end

    test "ADR-0022: legacy run cannot replace terminal launch" do
      legacy = String.replace(good_run(:import), "TaskBoundary.launch(", "TaskBoundary.run(")
      assert Adoption.violations(module(:import, legacy), :import) == [:run_shape]
    end

    test "RED: each forbidden call anywhere in the module is reported" do
      for call <- [
            ~s|IO.puts("x")|,
            ~s|IO.write(:stderr, "x")|,
            ~s|Logger.info("x")|,
            ~s|Mix.shell().info("x")|,
            ~s|Mix.raise("x")|,
            "System.halt(1)",
            "System.stop(1)",
            ":erlang.halt(1)",
            ":init.stop()",
            "exit(:normal)",
            "Process.exit(self(), :kill)"
          ] do
        extra = "defp helper, do: #{call}"
        source = module(:import, good_run(:import), extra)
        assert Adoption.violations(source, :import) == [:forbidden_call]
      end
    end

    test "RED: no run/1, and unparsable source, are reported" do
      no_run = module(:import, "def other(argv), do: argv")
      assert Adoption.violations(no_run, :import) == [:no_run]
      assert Adoption.violations("defmodule X do", :import) == [:not_parsed]
    end
  end

  describe "the five task files (structural prerequisite: absent at this base)" do
    for {kind, path} <- @tasks do
      test "#{kind}: #{path} follows the grammar" do
        read = File.read(unquote(path))
        assert match?({:ok, _source}, read), "the #{unquote(kind)} task file is absent"
        {:ok, source} = read
        assert Adoption.violations(source, unquote(kind)) == []
      end
    end
  end

  describe "the TaskBoundary build partition (source)" do
    test "RED: task_boundary.ex is gated on :prototype_authority_compiled" do
      source = File.read!("lib/sdr_agent/prototype/task_boundary.ex")
      assert {:ok, quoted} = Code.string_to_quoted(source)
      assert gated_module?(quoted, [:SdrAgent, :Prototype, :TaskBoundary])
    end
  end

  defp gated_module?({:if, _, [condition, [do: form]]}, module),
    do: gate?(condition) and defines?(form, module)

  defp gated_module?(_quoted, _module), do: false

  defp gate?({{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _, args}),
    do: args == [:sdr_agent, :prototype_authority_compiled, false]

  defp gate?(_condition), do: false

  defp defines?({:defmodule, _, [{:__aliases__, _, module} | _]}, module), do: true
  defp defines?(_form, _module), do: false
end
