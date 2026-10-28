defmodule SdrAgent.Prototype.ImportTaskSourceTest do
  @moduledoc """
  The source guard of `mix sdr.prototype.import`
  (`SdrAgent.ImportTaskSource.violations/1`; Codex 8ff184e4 and the
  coordinator's harness GO; I4 grammar r2 R-a1, the gate-independent rules,
  Codex d3048840), in two parts:

  - **the checker itself**, on tracked synthetic sources written here (no
    task file in `lib/`): a conforming sample of the I4 r2 grammar has no
    violation, and every single-defect variant has exactly the violations
    of its defect, one test per variant. They are evidence about the
    checker, not a task RED;
  - **the real task file**, `lib/mix/tasks/sdr.prototype.import.ex`, must
    have no violation. It does not exist yet, so that case fails
    structurally (`File.Error`) until the task's reviewed GREEN.

  The grammar checked here (R-a1): `run/1` is exactly
  `attached = SafeLog.attach(file: nil)` then
  `TaskBoundary.run(:import, attached, fn -> body(args) end)`; one private
  `body/1` clause starts with `Mix.Task.run("app.config", [])` and
  `{:ok, _} = Application.ensure_all_started(:opentelemetry)`, and holds the
  session entry and every reader; refusals go through
  `SafeLog.say(:import_refused, …)`; no `exit`, `raise`, `throw`, halt or
  stop. The containment gates (G0, G1) are NOT part of this sample or of
  these rules: they come with R-a2, once their call forms are accepted.

  Honest scope (see the checker's moduledoc): a lexical, source-order guard
  over explicit remote calls inside the task module, and only inside a
  supported grammar; outside it the checker refuses with exactly
  `[:unsupported_scope]` (Codex task-harness review R1). It is not runtime
  dominance and proves no output, success, exit or refusal behaviour.
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

      alias SdrAgent.Prototype.{DossierImport, DossierParser, ImportOutcome, SafeLog, Session}
      alias SdrAgent.Prototype.TaskBoundary
      alias SdrAgent.Prototype.SpotcheckManifest, as: Manifest

      @impl Mix.Task
      def run(args) do
        attached = SafeLog.attach(file: nil)
        TaskBoundary.run(:import, attached, fn -> body(args) end)
      end

      defp body(args) do
        Mix.Task.run("app.config", [])
        {:ok, _started} = Application.ensure_all_started(:opentelemetry)
        correlation = System.get_env("SDR_PROTOTYPE_SESSION")

        with {:ok, opts} <- parse(args),
             {:ok, %{actor: actor}} <- at(:session, Session.enter(agent: opts.agent, session_correlation: correlation)),
             {:ok, dossier} <- at(:dossier, DossierParser.read(opts.dossier, opts.dossier_sha256)),
             {:ok, manifest} <- at(:spotcheck, Manifest.read(opts.spotcheck, opts.spotcheck_sha256, {dossier, opts.dossier_sha256})),
             {:ok, rows} <- at(:prepare, DossierImport.prepare(dossier, opts.dossier_sha256, manifest, opts.rows, opts.artifacts)) do
          finish(DossierImport.import(rows, actor), actor)
        else
          {:error, stage, error} -> refuse(ImportOutcome.reason(stage, error))
        end
      end

      defp finish({:ok, summary}, actor) do
        case DossierImport.cap_used(actor) do
          {:ok, used} ->
            SafeLog.say(:import_row, row_index: 0, result: :imported, reason: :none)
            SafeLog.say(:import_summary, imported: length(summary.imported), replayed: 0, refused: 0, cap_used: used)
            :ok

          {:error, code} ->
            refuse(ImportOutcome.reason(:cap_used, code))
        end
      end

      defp finish({:error, %{code: code}}, _actor), do: refuse(ImportOutcome.reason(:import, code))

      defp refuse(reason) do
        SafeLog.say(:import_refused, reason: reason)
        :refused
      end

      defp at(_stage, {:ok, value}), do: {:ok, value}
      defp at(stage, {:error, error}), do: {:error, stage, error}

      defp parse([_ | _]), do: {:ok, %{agent: "codex_cli", dossier: "d", dossier_sha256: "h", spotcheck: "s", spotcheck_sha256: "h", rows: ["row-1"], artifacts: "a"}}
      defp parse(_args), do: {:error, :arguments, :invalid}
    end
  end
  """

  @attach "attached = SafeLog.attach(file: nil)\n"
  @boundary "TaskBoundary.run(:import, attached, fn -> body(args) end)"
  @app_config ~S|Mix.Task.run("app.config", [])| <> "\n"
  @otel "{:ok, _started} = Application.ensure_all_started(:opentelemetry)\n"
  @body_anchor ~S|correlation = System.get_env("SDR_PROTOTYPE_SESSION")| <> "\n"
  @with "with {:ok, opts} <- parse(args),"
  @enter "Session.enter(agent: opts.agent, session_correlation: correlation)"
  @row_say "SafeLog.say(:import_row, row_index: 0, result: :imported, reason: :none)"
  @refused_say "SafeLog.say(:import_refused, reason: reason)\n"
  @manifest_alias "alias SdrAgent.Prototype.SpotcheckManifest, as: Manifest\n"
  @first_helper "defp finish({:ok, summary}, actor) do"
  @last_helper "defp parse(_args), do: {:error, :arguments, :invalid}\n"
  @module_line "defmodule Mix.Tasks.Sdr.Prototype.Import do\n"
  @file_end "  end\nend\n"

  # {label, [{text to replace (each exactly once), replacement}], expected}
  @variants [
    # :run_shape (R-a1; replaces :attach_not_first)
    {:run_extra_statement, [{@attach, @attach <> "_ = :ok\n"}], [:run_shape]},
    {:attach_zero_arity, [{@attach, "attached = SafeLog.attach()\n"}], [:run_shape]},
    {:boundary_wrong_kind,
     [{@boundary, "TaskBoundary.run(:setup, attached, fn -> body(args) end)"}], [:run_shape]},
    {:boundary_other_value, [{@boundary, "TaskBoundary.run(:import, :ok, fn -> body(args) end)"}],
     [:run_shape]},
    {:boundary_other_argument,
     [{@boundary, "TaskBoundary.run(:import, attached, fn -> body([]) end)"}], [:run_shape]},
    {:attach_also_in_body, [{@body_anchor, "_ = SafeLog.attach(file: nil)\n" <> @body_anchor}],
     [:run_shape]},
    # :outside_body (R-a1; replaces :outside_run)
    {:reader_in_a_helper,
     [
       {@first_helper,
        "defp early(opts), do: DossierParser.read(opts.dossier, opts.dossier_sha256)\n" <>
          @first_helper}
     ], [:outside_body]},
    {:enter_in_an_earlier_helper,
     [
       {@enter, "enter(opts, correlation)"},
       {"@impl Mix.Task\n",
        "defp enter(opts, correlation), do: " <> @enter <> "\n@impl Mix.Task\n"}
     ], [:outside_body]},
    # :body_prologue (R-a1, new)
    {:prologue_missing_otel, [{@otel, ""}], [:body_prologue]},
    {:prologue_swapped, [{@app_config, ""}, {@otel, @otel <> @app_config}],
     [:body_prologue, :start_call]},
    {:app_config_with_argv, [{@app_config, ~S|Mix.Task.run("app.config", args)| <> "\n"}],
     [:body_prologue, :start_call]},
    {:otel_result_unmatched, [{@otel, "Application.ensure_all_started(:opentelemetry)\n"}],
     [:body_prologue, :start_call]},
    # :start_call (the list unchanged; only the exact prologue is exempt)
    {:second_app_config, [{@body_anchor, @app_config <> @body_anchor}], [:start_call]},
    {:start_sdr_agent,
     [{@body_anchor, "_ = Application.ensure_all_started(:sdr_agent)\n" <> @body_anchor}],
     [:start_call]},
    {:repo_start, [{@body_anchor, "_ = SdrAgent.Repo.start_link()\n" <> @body_anchor}],
     [:start_call]},
    {:boot_check, [{@body_anchor, "SdrAgent.Prototype.BootCheck.verify!()\n" <> @body_anchor}],
     [:start_call]},
    # :abnormal_exit (R-a1; replaces :raise_not_literal and :exit_not_literal)
    {:exit_literal, [{@refused_say, @refused_say <> "exit({:shutdown, 2})\n"}], [:abnormal_exit]},
    {:kernel_exit, [{@refused_say, @refused_say <> "Kernel.exit(:refused)\n"}], [:abnormal_exit]},
    {:mix_raise, [{@refused_say, @refused_say <> ~S|Mix.raise("refused")| <> "\n"}],
     [:abnormal_exit]},
    {:explicit_raise, [{@refused_say, @refused_say <> ~S|raise "refused"| <> "\n"}],
     [:abnormal_exit]},
    {:explicit_reraise, [{@refused_say, @refused_say <> ~S|reraise "refused", []| <> "\n"}],
     [:abnormal_exit]},
    {:explicit_throw, [{@refused_say, @refused_say <> "throw(:refused)\n"}], [:abnormal_exit]},
    {:system_halt, [{@refused_say, @refused_say <> "System.halt(2)\n"}], [:abnormal_exit]},
    {:system_stop, [{@refused_say, @refused_say <> "System.stop(2)\n"}], [:abnormal_exit]},
    {:erlang_halt, [{@refused_say, @refused_say <> ":erlang.halt(2)\n"}], [:abnormal_exit]},
    {:init_stop, [{@refused_say, @refused_say <> ":init.stop()\n"}], [:abnormal_exit]},
    {:process_exit, [{@refused_say, @refused_say <> "Process.exit(self(), :kill)\n"}],
     [:abnormal_exit]},
    # :say_shape (R-a1: three codes)
    {:say_three_args,
     [
       {@row_say,
        "SafeLog.say(:import_row, [row_index: 0, result: :imported, reason: :none], :extra)"}
     ], [:say_shape]},
    {:say_other_code, [{@row_say, "SafeLog.say(:boot, result: :ok, reason: :none)"}],
     [:say_shape]},
    {:no_import_refused_say, [{@refused_say, "_ = reason\n"}], [:say_shape]},
    # :missing_reader (the required calls, R-a1 adds ImportOutcome.reason/2 and
    # TaskBoundary.run/3)
    {:missing_cap_used, [{"DossierImport.cap_used(actor)", "{:ok, 0}"}], [:missing_reader]},
    {:missing_outcome,
     [
       {"refuse(ImportOutcome.reason(stage, error))", "refuse(:import_failed)"},
       {"refuse(ImportOutcome.reason(:cap_used, code))", "refuse(:import_failed)"},
       {"refuse(ImportOutcome.reason(:import, code))", "refuse(:import_failed)"}
     ], [:missing_reader]},
    # unchanged rules, re-based on the body
    {:manifest_read_before_entry,
     [{@with, "_early = Manifest.read(opts.spotcheck, opts.spotcheck_sha256, nil)\n" <> @with}],
     [:read_before_enter]},
    {:dossier_read_before_entry,
     [{@with, "_early = DossierParser.read(opts.dossier, opts.dossier_sha256)\n" <> @with}],
     [:read_before_enter]},
    {:enter_wrong_arity, [{@enter, "Session.enter([agent: opts.agent], correlation)"}],
     [:enter_arity]},
    {:enter_twice, [{@body_anchor, "_again = Session.enter(agent: :x)\n" <> @body_anchor}],
     [:enter_count]},
    {:io_call, [{@body_anchor, ~S|IO.puts("started")| <> "\n" <> @body_anchor}],
     [:other_channel]},
    {:logger_call, [{@body_anchor, ~S|Logger.info("started")| <> "\n" <> @body_anchor}],
     [:other_channel]},
    {:safe_log_event, [{@body_anchor, "SafeLog.event(:import_row, [])\n" <> @body_anchor}],
     [:other_channel]},
    {:file_call, [{@body_anchor, ~S|_ = File.read("x")| <> "\n" <> @body_anchor}], [:file_call]},
    {:other_env_var, [{~S|System.get_env("SDR_PROTOTYPE_SESSION")|, ~S|System.get_env("OTHER")|}],
     [:env_read]},
    {:extra_env_read, [{@body_anchor, ~S|_ = System.fetch_env!("HOME")| <> "\n" <> @body_anchor}],
     [:env_read]},
    {:apply_call, [{@body_anchor, "apply(SafeLog, :flush, [])\n" <> @body_anchor}],
     [:indirect_dispatch]},
    {:remote_capture, [{@body_anchor, "_ = &String.upcase/1\n" <> @body_anchor}],
     [:indirect_dispatch]},
    {:variable_module_call,
     [{@body_anchor, "module = SafeLog\nmodule.flush()\n" <> @body_anchor}],
     [:indirect_dispatch]},
    {:import_directive, [{"use Mix.Task\n", "use Mix.Task\nimport SdrAgent.Prototype.SafeLog\n"}],
     [:indirect_dispatch]},
    {:no_run, [{"def run(args) do\n", "def run_task(args) do\n"}], [:no_run, :run_shape]},
    {:no_mix_task, [{"use Mix.Task\n", ""}], [:not_mix_task]},
    {:no_moduledoc,
     [{"@moduledoc \"Synthetic conforming sample for the source guard (test only).\"\n", ""}],
     [:no_moduledoc]},
    {:other_module,
     [
       {"defmodule Mix.Tasks.Sdr.Prototype.Import do",
        "defmodule Mix.Tasks.Sdr.Prototype.Other do"}
     ], [:no_module]},
    # Unsupported scopes are refused, never analysed (Codex task-harness R1, R1b)
    {:second_body_clause, [{@first_helper, "defp body(_other), do: :ok\n\n" <> @first_helper}],
     [:unsupported_scope]},
    {:helper_local_alias_hides_io,
     [
       {@body_anchor, ~S|IO.puts("started")| <> "\n" <> @body_anchor},
       {@first_helper, "defp alias_scope do\nalias String, as: IO\n:ok\nend\n\n" <> @first_helper}
     ], [:unsupported_scope]},
    {:helper_local_alias_hides_file,
     [
       {@body_anchor, ~S|_ = File.read("x")| <> "\n" <> @body_anchor},
       {@first_helper,
        "defp alias_scope do\nalias String, as: File\n:ok\nend\n\n" <> @first_helper}
     ], [:unsupported_scope]},
    {:helper_local_alias_hides_early_reader,
     [
       {"at(:dossier, DossierParser.read(",
        "at(:dossier, SdrAgent.Prototype.DossierParser.read("},
       {@with, "_early = DossierParser.read(opts.dossier, opts.dossier_sha256)\n" <> @with},
       {@first_helper,
        "defp alias_scope do\nalias SdrAgent.Prototype.SafeLog, as: DossierParser\n:ok\nend\n\n" <>
          @first_helper}
     ], [:unsupported_scope]},
    {:alias_inside_body,
     [{@body_anchor, "alias SdrAgent.Prototype.SafeLog, as: Log\n" <> @body_anchor}],
     [:unsupported_scope]},
    {:nested_module_supplies_run,
     [
       {@module_line, @module_line <> "defmodule Support do\n"},
       {@last_helper, @last_helper <> "end\n"}
     ], [:unsupported_scope]},
    {:nested_module_beside_run,
     [{@last_helper, @last_helper <> "defmodule Helper do\n@moduledoc false\nend\n"}],
     [:unsupported_scope]},
    {:module_create,
     [{@body_anchor, "Module.create(Helper, quote(do: :ok), __ENV__)\n" <> @body_anchor}],
     [:unsupported_scope]},
    {:module_create_via_alias,
     [
       {@manifest_alias, @manifest_alias <> "alias Module, as: Builder\n"},
       {@body_anchor, "_ = Builder.create(Helper, quote(do: :ok), __ENV__)\n" <> @body_anchor}
     ], [:unsupported_scope]},
    {:module_create_fully_qualified,
     [
       {@body_anchor,
        "_ = Elixir.Module.create(Helper, quote(do: :ok), __ENV__)\n" <> @body_anchor}
     ], [:unsupported_scope]},
    {:kernel_defmodule_remote,
     [{@last_helper, @last_helper <> "Kernel.defmodule Helper do\n@moduledoc false\nend\n"}],
     [:unsupported_scope]},
    {:kernel_use_remote, [{@manifest_alias, @manifest_alias <> "Kernel.use(GenServer)\n"}],
     [:unsupported_scope]},
    {:special_forms_alias_remote,
     [{@body_anchor, "Kernel.SpecialForms.alias(String, as: Log)\n" <> @body_anchor}],
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
    {:second_run_clause, [{@first_helper, "def run(_ignored), do: :ok\n\n" <> @first_helper}],
     [:unsupported_scope]},
    {:alias_rebinding_after_definitions,
     [
       {@manifest_alias, @manifest_alias <> "alias IO, as: Out\n"},
       {@body_anchor, ~S|Out.puts("started")| <> "\n" <> @body_anchor},
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
       {@body_anchor, ~S|IO.puts("started")| <> "\n" <> @body_anchor}
     ], [:unsupported_scope]},
    {:require_as,
     [{"use Mix.Task\n", "use Mix.Task\nrequire SdrAgent.Prototype.SafeLog, as: Quiet\n"}],
     [:unsupported_scope]},
    {:unsupported_alias_form,
     [{@manifest_alias, @manifest_alias <> ~S|alias :"Elixir.String", as: Text| <> "\n"}],
     [:unsupported_scope]},
    # Inside the grammar, aliases expand in order and a delegation is flagged
    {:alias_through_earlier_alias,
     [
       {@manifest_alias,
        "alias SdrAgent.Prototype\n" <> "alias Prototype.SpotcheckManifest, as: Manifest\n"}
     ], []},
    {:defdelegate_to_io,
     [{@manifest_alias, @manifest_alias <> "defdelegate puts(text), to: IO\n"}],
     [:indirect_dispatch]}
  ]

  @violations ~w(no_module not_mix_task no_moduledoc no_run run_shape outside_body body_prologue
                 enter_count enter_arity read_before_enter missing_reader start_call env_read
                 file_call say_shape other_channel abnormal_exit indirect_dispatch
                 unsupported_scope)a

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

    for {label, replacements, expected} <- @variants do
      test "variant #{label} has exactly #{inspect(Enum.sort(expected))}" do
        source = variant(unquote(Macro.escape(replacements)))
        refute source == @conforming, "no change"
        assert {:ok, _ast} = Code.string_to_quoted(source), "does not parse"
        assert ImportTaskSource.violations(source) == unquote(Enum.sort(expected))
      end
    end

    test "every closed violation is exercised by some variant, and no other is expected" do
      exercised = Enum.flat_map(@variants, fn {_label, _replacements, expected} -> expected end)

      for violation <- @violations do
        assert violation in exercised, "#{violation} is not exercised"
      end

      assert Enum.uniq(exercised) -- @violations == []
    end
  end

  describe "the real task file" do
    test "lib/mix/tasks/sdr.prototype.import.ex has no violation" do
      assert ImportTaskSource.violations(File.read!(@task)) == []
    end
  end
end
