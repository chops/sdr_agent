defmodule SdrAgent.Prototype.SafeLog do
  @moduledoc """
  The content-free logging channel of the D-237 prototype (interfaces r6
  IF-8). Every slice uses it.

  - `event/2` emits one log event whose refs must match its code's pinned
    shape; `say/2` prints one stdout line of the same shapes (counts, ids
    and closed atoms only, never content).
  - `attach/0` installs the primary logger filter
    `:sdr_prototype_content_free` (after `ExceptionFilter`) and the file
    sink. It is the first statement of every `sdr.prototype.*` task and runs
    in `Application.start/2` when the switch is set.
  - The filter keeps only events of a code in `codes/0` whose refs have
    exactly that code's keys and value types, rebuilt from the code and the
    validated refs with the fixed message `"prototype: <code>"`. Every
    other event becomes `"prototype: log content withheld"`.

  Ref value types: `uuid` (a canonical lowercase 36-character UUID),
  `count` (an integer 0..1,000,000, or the bound shown), and a closed enum
  of atoms. `shapes/0` is the pinned table; `reasons/1` gives each reason
  enum.

  RED stage (D-237 S1): the closed code, shape and reason sets are the
  contract; `event/2`, `say/2`, `attach/0,1` and `detach/0` return
  `{:error, :not_implemented}` and filter nothing.
  """

  @boot_reasons [
    :none,
    :switch_invalid,
    :switch_outside_dev,
    :agent_env_configured,
    :binding_absent,
    :binding_without_switch,
    :binding_not_exact,
    :instance_mismatch,
    :policy_mismatch,
    :database_mismatch,
    :live_identity_unavailable,
    :witness_store_configured,
    :suppression_not_store,
    :users_not_exact
  ]

  @setup_reasons [
    :none,
    :wrong_env,
    :flag_unset,
    :switch_unset,
    :session_unset,
    :invalid_agent,
    :invalid_correlation,
    :invalid_arguments,
    :repo_target_mismatch,
    :cluster_identity_mismatch,
    :app_running,
    :seed_invalid,
    :credential_path_exists,
    :database_exists,
    :storage_failed,
    :migration_failed,
    :database_not_resumable,
    :database_not_fresh,
    :bootstrap_failed,
    :credential_stale,
    :boot_refused,
    :seed_failed
  ]

  @import_reasons [
    :none,
    :no_named_person,
    :role_mailbox,
    :email_unavailable,
    :link_unconfirmed,
    :role_unconfirmed,
    :source_conflict,
    :insufficient_source,
    :not_selected,
    :contact_cap_exceeded,
    :dossier_conflict,
    :dossier_invalid,
    :spotcheck_invalid,
    :artifact_invalid,
    :digest_mismatch,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :import_failed
  ]

  @provision_reasons [
    :none,
    :worksheet_invalid,
    :budget_unbounded,
    :budget_below_ceiling,
    :grant_exists,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :provision_failed
  ]

  @op_reasons [
    :none,
    :invalid_arguments,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :not_found,
    :stale_review,
    :digest_mismatch,
    :seed_differs,
    :seed_invalid,
    :op_failed
  ]

  @shapes %{
    boot: [result: {:enum, [:ok, :refused]}, reason: {:enum, @boot_reasons}],
    setup_phase: [
      phase: {:count, 0..3},
      result: {:enum, [:ok, :refused, :rolled_back]},
      reason: {:enum, @setup_reasons}
    ],
    seed_result: [revisions: :count, result: {:enum, [:ok, :replay, :refused]}],
    import_row: [
      row_index: {:count, 0..14},
      result: {:enum, [:imported, :replay, :skipped, :refused]},
      reason: {:enum, @import_reasons}
    ],
    import_summary: [imported: :count, replayed: :count, refused: :count, cap_used: :count],
    provisioned: [
      grant_id: :uuid,
      result: {:enum, [:created, :replay, :refused]},
      reason: {:enum, @provision_reasons}
    ],
    op_result: [
      command: {:enum, [:assign, :review, :approve, :reject, :revoke, :seed, :status]},
      id: :uuid,
      result: {:enum, [:ok, :refused]},
      reason: {:enum, @op_reasons}
    ],
    bundle_written: [bundle_id: :uuid, items: :count],
    status_counts: [
      invocations: :count,
      released: :count,
      withheld: :count,
      captured: :count,
      attempts_left: :count
    ]
  }

  @type code ::
          :boot
          | :setup_phase
          | :seed_result
          | :import_row
          | :import_summary
          | :provisioned
          | :op_result
          | :bundle_written
          | :status_counts

  @doc "The closed set of codes."
  @spec codes() :: [code()]
  def codes, do: Map.keys(@shapes) |> Enum.sort()

  @doc "The pinned per-code ref shapes."
  @spec shapes() :: %{code() => keyword()}
  def shapes, do: @shapes

  @doc "A closed reason enum: `:boot`, `:setup`, `:import`, `:provision` or `:op`."
  @spec reasons(:boot | :setup | :import | :provision | :op) :: [atom()]
  def reasons(:boot), do: @boot_reasons
  def reasons(:setup), do: @setup_reasons
  def reasons(:import), do: @import_reasons
  def reasons(:provision), do: @provision_reasons
  def reasons(:op), do: @op_reasons

  @doc "Emits one content-free log event of `code` with `refs`."
  @spec event(code(), keyword()) :: :ok | {:error, :not_implemented}
  def event(_code, _refs), do: red({:error, :not_implemented})

  @doc "Prints one content-free stdout line of `code` with `refs`."
  @spec say(code(), keyword()) :: :ok | {:error, :not_implemented}
  def say(_code, _refs), do: red({:error, :not_implemented})

  @doc "Installs the content-free primary filter and the file sink."
  @spec attach() :: :ok | {:error, :not_implemented}
  def attach, do: red({:error, :not_implemented})

  @doc "As `attach/0`; `file:` names the sink file (`nil`: no file sink)."
  @spec attach(keyword()) :: :ok | {:error, :not_implemented}
  def attach(_opts), do: red({:error, :not_implemented})

  @doc "Removes the filter and the file sink (tests only)."
  @spec detach() :: :ok | {:error, :not_implemented}
  def detach, do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
