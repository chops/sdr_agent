# Compiled only with the D-237 prototype authority; absent in production.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule Mix.Tasks.Sdr.Prototype.Import do
    @moduledoc """
    Imports selected dossier rows through the D-237 prototype operator APIs.

        mix sdr.prototype.import --agent codex_cli --dossier FILE --sha256 HEX \
          --spotcheck FILE --spotcheck-sha256 HEX --artifacts-dir DIR --rows r1,r2

    Each of the seven options is required exactly once, with a nonempty
    string value; unknown options and positional arguments refuse. Agent,
    digest, content and row-selection validation remain with Session and
    the existing readers/import planner. Paths, row ids and values are
    never printed. The only environment read is SDR_PROTOTYPE_SESSION.

    Mix loads app.config through the requirement before terminal launch.
    The body starts only OpenTelemetry, enters Session, and checks the real
    import guard before any protected input read. Every non-success guard
    result is returned whole and tagged to TaskBoundary for abort70, never
    converted to an input refusal or inspected for its code.

    DossierImport owns the precheck and each row transaction. Completed
    rows stay committed after a later row refusal; replay uses no new slot.
    On success the cap read precedes every row line. A returned cap refusal
    prints the completed rows then a closed refusal; a raised cap read
    prints no row prefix. Failed rows never trigger a cap read. Only
    SafeLog's closed counts, row indices and codes reach stdout. Exceptions
    and partial output are presented only by TaskBoundary.

    This task does not seed, activate, enqueue, call a model or send outreach.
    Lexical source checks do not prove the fresh-terminal launch/OTel/guard
    route or successful database import; those require runtime evidence.
    """
    use Mix.Task

    alias SdrAgent.Prototype.ContainmentGuard
    alias SdrAgent.Prototype.DossierImport
    alias SdrAgent.Prototype.DossierParser
    alias SdrAgent.Prototype.ImportOutcome
    alias SdrAgent.Prototype.SafeLog
    alias SdrAgent.Prototype.Session
    alias SdrAgent.Prototype.SpotcheckManifest, as: Manifest
    alias SdrAgent.Prototype.TaskBoundary

    @shortdoc "Import selected real-prototype dossier rows without outreach"
    @requirements ["app.config"]
    # :keep is string-typed and preserves duplicates so exact-key checking
    # refuses them instead of silently accepting OptionParser's last value.
    @switches [
      agent: :keep,
      dossier: :keep,
      sha256: :keep,
      spotcheck: :keep,
      spotcheck_sha256: :keep,
      artifacts_dir: :keep,
      rows: :keep
    ]
    @option_names @switches |> Keyword.keys() |> Enum.sort()

    @impl Mix.Task
    def run(args) do
      attached = SafeLog.attach(file: nil)
      TaskBoundary.launch(:import, attached, fn -> body(args) end)
    end

    defp body(args) do
      {:ok, _started} = Application.ensure_all_started(:opentelemetry)

      with {:ok, opts} <- parse(args),
           correlation = System.get_env("SDR_PROTOTYPE_SESSION"),
           {:ok, %{actor: actor}} <-
             at(:session, Session.enter(agent: opts.agent, session_correlation: correlation)),
           {:guard, :ok} <- {:guard, ContainmentGuard.guard(:import)},
           {:ok, dossier} <- at(:dossier, DossierParser.read(opts.dossier, opts.dossier_sha256)),
           {:ok, manifest} <-
             at(
               :spotcheck,
               Manifest.read(
                 opts.spotcheck,
                 opts.spotcheck_sha256,
                 {dossier, opts.dossier_sha256}
               )
             ),
           {:ok, rows} <-
             at(
               :prepare,
               DossierImport.prepare(
                 dossier,
                 opts.dossier_sha256,
                 manifest,
                 opts.rows,
                 opts.artifacts
               )
             ) do
        finish(DossierImport.import(rows, actor), rows, actor)
      else
        {:guard, _result} = guard_refusal -> guard_refusal
        {:error, stage, error} -> refuse(ImportOutcome.reason(stage, error))
      end
    end

    defp finish({:ok, summary}, rows, actor) do
      case DossierImport.cap_used(actor) do
        {:ok, used} ->
          completed_rows(summary, rows)

          :ok =
            SafeLog.say(:import_summary,
              imported: length(summary.imported),
              replayed: length(summary.replayed),
              refused: 0,
              cap_used: used
            )

          :ok

        {:error, code} ->
          completed_rows(summary, rows)
          refuse(ImportOutcome.reason(:cap_used, code))
      end
    end

    defp finish({:error, %{failed_row: nil, code: code}}, _rows, _actor),
      do: refuse(ImportOutcome.reason(:import, code))

    defp finish({:error, %{failed_row: id, code: code} = summary}, rows, _actor) do
      completed_rows(summary, rows)
      failed = Enum.find(rows, fn row -> row.row_id == id end)

      :ok =
        SafeLog.say(:import_row,
          row_index: failed.row_index,
          result: :refused,
          reason: ImportOutcome.reason(:import, code)
        )

      :refused
    end

    defp completed_rows(summary, rows) do
      Enum.each(rows, fn row ->
        result =
          cond do
            row.row_id in summary.imported -> :imported
            row.row_id in summary.replayed -> :replay
            true -> nil
          end

        if result do
          :ok = SafeLog.say(:import_row, row_index: row.row_index, result: result, reason: :none)
        end
      end)
    end

    defp refuse(reason) do
      :ok = SafeLog.say(:import_refused, reason: reason)
      :refused
    end

    defp at(_stage, {:ok, value}), do: {:ok, value}
    defp at(stage, {:error, error}), do: {:error, stage, error}

    defp parse(args) do
      with {opts, [], []} <- OptionParser.parse(args, strict: @switches),
           true <- Enum.sort(Keyword.keys(opts)) == @option_names,
           true <- Enum.all?(opts, fn {_key, value} -> is_binary(value) and value != "" end) do
        {:ok,
         %{
           agent: Keyword.fetch!(opts, :agent),
           dossier: Keyword.fetch!(opts, :dossier),
           dossier_sha256: Keyword.fetch!(opts, :sha256),
           spotcheck: Keyword.fetch!(opts, :spotcheck),
           spotcheck_sha256: Keyword.fetch!(opts, :spotcheck_sha256),
           artifacts: Keyword.fetch!(opts, :artifacts_dir),
           rows: opts |> Keyword.fetch!(:rows) |> String.split(",", trim: false)
         }}
      else
        _invalid -> {:error, :arguments, :invalid}
      end
    end
  end
end
