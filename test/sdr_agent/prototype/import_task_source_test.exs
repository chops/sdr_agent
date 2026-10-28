defmodule SdrAgent.Prototype.ImportTaskSourceTest do
  @moduledoc """
  The source guard of `mix sdr.prototype.import`
  (`SdrAgent.ImportTaskSource.violations/1`; Codex 8ff184e4 and the
  coordinator's harness GO), in two parts:

  - **the checker itself**, on tracked synthetic sources written here (no
    task file in `lib/`): a conforming sample has no violation, and every
    single-defect variant has exactly the violation of its defect. These
    run now; they are evidence about the checker, not a task RED;
  - **the real task file**, `lib/mix/tasks/sdr.prototype.import.ex`, must
    have no violation. It does not exist yet, so that case fails
    structurally (`File.Error`) until the task's reviewed GREEN.

  Honest scope (see the checker's moduledoc): a lexical, source-order guard
  over explicit remote calls inside the task module, with `attach`, the
  session entry and every reader required lexically inside `run/1`, and
  only inside a supported grammar; outside it the checker refuses with
  exactly `[:unsupported_scope]` (Codex task-harness review R1: a
  helper-local alias, a nested module or an alias rebinding must neither
  hide a call nor supply the task's `run/1`, `use` or `@moduledoc`). It is
  not runtime dominance and proves no output, success or refusal behaviour.
  Nothing here runs a task or reads an input file.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.ImportTaskSource

  @task "lib/mix/tasks/sdr.prototype.import.ex"

  # A synthetic conforming task (test text only; never compiled or run).
  @conforming ~S"""
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defmodule Mix.Tasks.Sdr.Prototype.Import do
      @moduledoc "Synthetic conforming sample for the source guard (test only)."
      use Mix.Task

      alias SdrAgent.Prototype.{DossierImport, DossierParser, SafeLog, Session}
      alias SdrAgent.Prototype.SpotcheckManifest, as: Manifest

      @impl Mix.Task
      def run(args) do
        SafeLog.attach()
        opts = parse(args)
        correlation = System.get_env("SDR_PROTOTYPE_SESSION")

        with {:ok, %{actor: actor}} <- Session.enter(agent: opts.agent, session_correlation: correlation),
             {:ok, dossier} <- DossierParser.read(opts.dossier, opts.dossier_sha256),
             {:ok, manifest} <- Manifest.read(opts.spotcheck, dossier, opts.spotcheck_sha256),
             {:ok, rows} <- DossierImport.prepare(dossier, opts.dossier_sha256, manifest, opts.rows, opts.artifacts),
             {:ok, summary} <- DossierImport.import(rows, actor),
             {:ok, used} <- DossierImport.cap_used(actor) do
          SafeLog.say(:import_row, row_index: 0, result: :imported, reason: :none)
          SafeLog.say(:import_summary, imported: length(summary.imported), replayed: 0, refused: 0, cap_used: used)
        else
          _refused -> exit({:shutdown, 2})
        end
      end

      defp parse([_ | _]), do: %{agent: "codex_cli", dossier: "d", dossier_sha256: "h", spotcheck: "s", spotcheck_sha256: "h", rows: ["row-1"], artifacts: "a"}
      defp parse(_args), do: Mix.raise("invalid arguments")
    end
  end
  """

  @attach "SafeLog.attach()\n"
  @with "with {:ok, %{actor: actor}} <-"
  @enter "Session.enter(agent: opts.agent, session_correlation: correlation)"
  @row_say "SafeLog.say(:import_row, row_index: 0, result: :imported, reason: :none)"
  @manifest_alias "alias SdrAgent.Prototype.SpotcheckManifest, as: Manifest\n"
  @first_helper "defp parse([_ | _])"
  @last_helper ~S|defp parse(_args), do: Mix.raise("invalid arguments")| <> "\n"
  @module_line "defmodule Mix.Tasks.Sdr.Prototype.Import do\n"
  @file_end "  end\nend\n"

  # {label, [{text to replace (each exactly once), replacement}], expected}
  @variants [
    {:manifest_read_before_entry,
     [{@with, "_early = Manifest.read(opts.spotcheck, nil, opts.spotcheck_sha256)\n" <> @with}],
     [:read_before_enter]},
    {:dossier_read_before_entry,
     [{@with, "_early = DossierParser.read(opts.dossier, opts.dossier_sha256)\n" <> @with}],
     [:read_before_enter]},
    {:enter_wrong_arity, [{@enter, "Session.enter([agent: opts.agent], correlation)"}],
     [:enter_arity]},
    {:enter_twice, [{@row_say, "_again = Session.enter(agent: opts.agent)\n" <> @row_say}],
     [:enter_count]},
    {:reader_in_a_helper,
     [
       {"defp parse([_ | _])",
        "defp early(opts), do: DossierParser.read(opts.dossier, opts.dossier_sha256)\n" <>
          "defp parse([_ | _])"}
     ], [:outside_run]},
    {:enter_in_an_earlier_helper,
     [
       {@enter, "enter(opts, correlation)"},
       {"@impl Mix.Task\n",
        "defp enter(opts, correlation), do: " <> @enter <> "\n@impl Mix.Task\n"}
     ], [:outside_run]},
    {:attach_not_first,
     [{@attach, ""}, {"opts = parse(args)\n", "opts = parse(args)\n" <> @attach}],
     [:attach_not_first]},
    {:say_three_args,
     [
       {@row_say,
        "SafeLog.say(:import_row, [row_index: 0, result: :imported, reason: :none], :extra)"}
     ], [:say_shape]},
    {:say_other_code, [{@row_say, "SafeLog.say(:boot, result: :ok, reason: :none)"}],
     [:say_shape]},
    {:io_call, [{@attach, @attach <> "IO.puts(\"started\")\n"}], [:other_channel]},
    {:logger_call, [{@attach, @attach <> "Logger.info(\"started\")\n"}], [:other_channel]},
    {:safe_log_event, [{@attach, @attach <> "SafeLog.event(:import_row, [])\n"}],
     [:other_channel]},
    {:file_call, [{@attach, @attach <> "_ = File.read(\"x\")\n"}], [:file_call]},
    {:application_start, [{@attach, @attach <> "Application.ensure_all_started(:sdr_agent)\n"}],
     [:start_call]},
    {:boot_check, [{@attach, @attach <> "SdrAgent.Prototype.BootCheck.verify!()\n"}],
     [:start_call]},
    {:other_env_var, [{~S|System.get_env("SDR_PROTOTYPE_SESSION")|, ~S|System.get_env("OTHER")|}],
     [:env_read]},
    {:extra_env_read, [{@attach, @attach <> "_ = System.fetch_env!(\"HOME\")\n"}], [:env_read]},
    {:interpolated_raise,
     [{~S|Mix.raise("invalid arguments")|, ~S|Mix.raise("invalid #{inspect(args)}")|}],
     [:raise_not_literal]},
    {:variable_exit, [{"exit({:shutdown, 2})", "exit({:shutdown, code()})"}],
     [:exit_not_literal]},
    {:apply_call, [{@attach, @attach <> "apply(SafeLog, :flush, [])\n"}], [:indirect_dispatch]},
    {:remote_capture, [{@attach, @attach <> "_ = &String.upcase/1\n"}], [:indirect_dispatch]},
    {:variable_module_call, [{@attach, @attach <> "module = SafeLog\nmodule.flush()\n"}],
     [:indirect_dispatch]},
    {:import_directive, [{"use Mix.Task\n", "use Mix.Task\nimport SdrAgent.Prototype.SafeLog\n"}],
     [:indirect_dispatch]},
    {:missing_cap_used, [{"{:ok, used} <- DossierImport.cap_used(actor)", "used = 0"}],
     [:missing_reader]},
    {:no_run, [{"def run(args) do\n", "def run_task(args) do\n"}], [:no_run, :outside_run]},
    {:no_mix_task, [{"use Mix.Task\n", ""}], [:not_mix_task]},
    {:no_moduledoc,
     [{"@moduledoc \"Synthetic conforming sample for the source guard (test only).\"\n", ""}],
     [:no_moduledoc]},
    {:other_module,
     [
       {"defmodule Mix.Tasks.Sdr.Prototype.Import do",
        "defmodule Mix.Tasks.Sdr.Prototype.Other do"}
     ], [:no_module]},
    # Codex task-harness review R1: unsupported scopes are refused, never
    # analysed. Helper-local alias laundering of IO, of File and of an early
    # reader (each would hide a real call in run/1 from a flattened alias map):
    {:helper_local_alias_hides_io,
     [
       {@attach, @attach <> ~S|IO.puts("started")| <> "\n"},
       {@first_helper, "defp alias_scope do\nalias String, as: IO\n:ok\nend\n\n" <> @first_helper}
     ], [:unsupported_scope]},
    {:helper_local_alias_hides_file,
     [
       {@attach, @attach <> ~S|_ = File.read("x")| <> "\n"},
       {@first_helper,
        "defp alias_scope do\nalias String, as: File\n:ok\nend\n\n" <> @first_helper}
     ], [:unsupported_scope]},
    {:helper_local_alias_hides_early_reader,
     [
       {"{:ok, dossier} <- DossierParser.read(",
        "{:ok, dossier} <- SdrAgent.Prototype.DossierParser.read("},
       {@with, "_early = DossierParser.read(opts.dossier, opts.dossier_sha256)\n" <> @with},
       {@first_helper,
        "defp alias_scope do\nalias SdrAgent.Prototype.SafeLog, as: DossierParser\n:ok\nend\n\n" <>
          @first_helper}
     ], [:unsupported_scope]},
    {:alias_inside_run, [{@attach, @attach <> "alias SdrAgent.Prototype.SafeLog, as: Log\n"}],
     [:unsupported_scope]},
    # A nested module cannot supply the outer task's run/1, use or moduledoc,
    # and no nested module, macro or code injection is analysed at all:
    {:nested_module_supplies_run,
     [
       {@module_line, @module_line <> "defmodule Support do\n"},
       {@last_helper, @last_helper <> "end\n"}
     ], [:unsupported_scope]},
    {:nested_module_beside_run,
     [{@last_helper, @last_helper <> "defmodule Helper do\n@moduledoc false\nend\n"}],
     [:unsupported_scope]},
    {:module_create, [{@attach, @attach <> "Module.create(Helper, quote(do: :ok), __ENV__)\n"}],
     [:unsupported_scope]},
    {:local_macro, [{@last_helper, @last_helper <> "defmacrop quiet, do: :ok\n"}],
     [:unsupported_scope]},
    {:other_use, [{"use Mix.Task\n", "use Mix.Task\nuse GenServer\n"}], [:unsupported_scope]},
    {:before_compile_hook,
     [{@manifest_alias, @manifest_alias <> "@before_compile SdrAgent.Prototype.SafeLog\n"}],
     [:unsupported_scope]},
    {:task_inside_another_module,
     [
       {@module_line, "defmodule Wrapper do\n" <> @module_line},
       {@file_end, "  end\nend\nend\n"}
     ], [:unsupported_scope]},
    {:second_task_definition,
     [
       {@file_end,
        "  end\nelse\ndefmodule Mix.Tasks.Sdr.Prototype.Import do\n@moduledoc \"x\"\nend\nend\n"}
     ], [:unsupported_scope]},
    {:second_run_clause,
     [{@first_helper, "def run(_ignored), do: exit({:shutdown, 2})\n\n" <> @first_helper}],
     [:unsupported_scope]},
    # Alias rebinding and order: no alias reinterprets an earlier call, none
    # is bound twice, none binds a ruled root, and only supported forms:
    {:alias_rebinding_after_definitions,
     [
       {@manifest_alias, @manifest_alias <> "alias IO, as: Out\n"},
       {@attach, @attach <> ~S|Out.puts("started")| <> "\n"},
       {@last_helper, @last_helper <> "alias String, as: Out\n"}
     ], [:unsupported_scope]},
    {:alias_after_definitions,
     [{@last_helper, @last_helper <> "alias SdrAgent.Prototype.Unused\n"}], [:unsupported_scope]},
    {:alias_rebinding,
     [{@manifest_alias, @manifest_alias <> "alias SdrAgent.Prototype.BootCheck, as: Session\n"}],
     [:unsupported_scope]},
    {:alias_shadows_ruled_root,
     [
       {@manifest_alias, @manifest_alias <> "alias String, as: IO\n"},
       {@attach, @attach <> ~S|IO.puts("started")| <> "\n"}
     ], [:unsupported_scope]},
    {:require_as,
     [{"use Mix.Task\n", "use Mix.Task\nrequire SdrAgent.Prototype.SafeLog, as: Quiet\n"}],
     [:unsupported_scope]},
    {:unsupported_alias_form,
     [{@manifest_alias, @manifest_alias <> ~S|alias :"Elixir.String", as: Text| <> "\n"}],
     [:unsupported_scope]},
    # Inside the grammar, aliases expand in order and a delegation is
    # flagged as indirect dispatch:
    {:alias_through_earlier_alias,
     [
       {@manifest_alias,
        "alias SdrAgent.Prototype\n" <> "alias Prototype.SpotcheckManifest, as: Manifest\n"}
     ], []},
    {:defdelegate_to_io,
     [{@manifest_alias, @manifest_alias <> "defdelegate puts(text), to: IO\n"}],
     [:indirect_dispatch]}
  ]

  defp occurrences(text, part), do: length(String.split(text, part)) - 1

  defp variant(replacements) do
    Enum.reduce(replacements, @conforming, fn {from, to}, text ->
      assert occurrences(text, from) == 1, "#{inspect(from)} must occur exactly once"
      String.replace(text, from, to)
    end)
  end

  describe "the checker, on tracked synthetic sources" do
    test "the conforming sample has no violation" do
      assert ImportTaskSource.violations(@conforming) == []
    end

    test "each single-defect variant has exactly the violation of its defect" do
      for {label, replacements, expected} <- @variants do
        source = variant(replacements)
        refute source == @conforming, "#{label}: no change"
        assert {:ok, _ast} = Code.string_to_quoted(source), "#{label}: does not parse"

        assert ImportTaskSource.violations(source) == Enum.sort(expected),
               "#{label}: #{inspect(ImportTaskSource.violations(source))}"
      end
    end

    test "every closed violation is exercised by some variant" do
      exercised = Enum.flat_map(@variants, fn {_label, _replacements, expected} -> expected end)

      for violation <- ~w(no_module not_mix_task no_moduledoc no_run attach_not_first outside_run
                          enter_count enter_arity read_before_enter missing_reader start_call
                          env_read file_call say_shape other_channel raise_not_literal
                          exit_not_literal indirect_dispatch unsupported_scope)a do
        assert violation in exercised, "#{violation} is not exercised"
      end
    end
  end

  describe "the real task file" do
    test "lib/mix/tasks/sdr.prototype.import.ex has no violation" do
      assert ImportTaskSource.violations(File.read!(@task)) == []
    end
  end
end
