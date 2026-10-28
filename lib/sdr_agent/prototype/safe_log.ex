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
    in `Application.start/2` when the switch is set. `attach(file: nil)`
    installs the filter alone; `detach/0` removes it (tests).
  - The filter keeps only events of a code in `codes/0` whose refs have
    exactly that code's keys and value types, rebuilt from the code and the
    validated refs with the fixed message `"prototype: <code>"`. Every
    other event becomes `"prototype: log content withheld"`.

  Ref value types: `uuid` (a canonical lowercase 36-character UUID),
  `count` (an integer 0..1,000,000, or the bound shown), and a closed enum
  of atoms. `shapes/0` is the pinned table; `reasons/1` gives each reason
  enum. Refs must have exactly the code's keys, each once, in any order;
  a retained event carries them in shape order.

  A retained or withheld event keeps its level (an invalid or missing
  level becomes `:error`) and only the standard metadata whose value has a
  bounded safe shape, the same set as `SdrAgent.Logger.ExceptionFilter`'s
  `scan_limit` event: `pid`/`gl` pids, `time` and `line` integers, `mfa`
  an `{atom, atom, arity}`, `file` a string or charlist of at most 1,024,
  `domain` a list of at most 16 atoms. Nothing else of the event is kept.
  The filter never raises, never returns `:ignore` or `:stop` and never
  passes an event through: an internal failure yields the withheld event
  at `:error`.

  Levels (Codex b069e93f ruling 2): `event/2` logs a valid event at
  `:warning` when its `result` is `:refused` or `:rolled_back`, at `:info`
  otherwise, and a malformed one at `:warning`. `say/2` prints a malformed
  one as the same fixed line, `"prototype: log content withheld"` (ruling 3).

  Staged GREEN (D-237 S1b, Codex b069e93f): `filter/2`, `event/2`,
  `say/2`, `attach(file: nil)` and `detach/0` are implemented. The file
  sink (S-d) is held: `attach/0` and every other `attach/1` form refuse
  `{:error, :not_implemented}` without changing the logger.
  """

  require Logger

  @filter_id :sdr_prototype_content_free
  @withheld "prototype: log content withheld"
  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]
  @max_file 1_024
  @max_domain 16

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

  @doc """
  Emits one content-free log event of `code` with `refs`: the fixed message
  `"prototype: <code>"` with the metadata `sdr_prototype_code` and
  `sdr_prototype_refs` (in shape order), at `:warning` for a `:refused` or
  `:rolled_back` result and `:info` otherwise. Refs that do not match the
  code's pinned shape log `"prototype: log content withheld"` at `:warning`
  instead, with `sdr_prototype_code: :withheld` and no ref value. Always
  `:ok`.
  """
  @spec event(code(), keyword()) :: :ok
  def event(code, refs) do
    case validate(code, refs) do
      {:ok, ordered} ->
        # Structural keys, read only by the content-free filter; never for the formatter.
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.log(event_level(ordered), "prototype: #{code}",
          sdr_prototype_code: code,
          sdr_prototype_refs: ordered
        )

      :error ->
        # Structural key, read only by the content-free filter; never for the formatter.
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.log(:warning, @withheld, sdr_prototype_code: :withheld)
    end

    :ok
  end

  defp event_level(refs) do
    if Keyword.get(refs, :result) in [:refused, :rolled_back], do: :warning, else: :info
  end

  @doc """
  Prints one stdout line of `code` with `refs` in shape order
  (`prototype: <code> key=value ...`). Refs that do not match the code's
  pinned shape print exactly `"prototype: log content withheld"`, with no
  code or value. Always `:ok`.
  """
  @spec say(code(), keyword()) :: :ok
  def say(code, refs) do
    line =
      case validate(code, refs) do
        {:ok, ordered} -> Enum.join(["prototype: #{code}" | Enum.map(ordered, &pair/1)], " ")
        :error -> @withheld
      end

    IO.puts(line)
  end

  # A validated ref: a closed atom, a bounded integer or a canonical UUID.
  defp pair({key, value}), do: "#{key}=#{value}"

  @doc """
  The primary filter `:sdr_prototype_content_free` as a pure `:logger`
  filter function: returns the event rebuilt from its validated code and
  refs (message `"prototype: <code>"`), or the withheld event (message
  `"prototype: log content withheld"`, level and validated standard
  metadata kept, `sdr_prototype_code: :withheld`). Never `:ignore`.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(event, _extra) do
    rebuild(event)
  catch
    _kind, _reason -> withheld(:error, %{})
  end

  defp rebuild(event) do
    level = level_of(event)
    meta = meta_of(event)
    code = Map.get(meta, :sdr_prototype_code)

    case validate(code, Map.get(meta, :sdr_prototype_refs)) do
      {:ok, refs} ->
        tag = %{sdr_prototype_code: code, sdr_prototype_refs: refs}

        %{
          level: level,
          msg: {:string, "prototype: #{code}"},
          meta: Map.merge(standard(meta), tag)
        }

      :error ->
        withheld(level, meta)
    end
  end

  defp withheld(level, meta),
    do: %{
      level: level,
      msg: {:string, @withheld},
      meta: meta |> standard() |> Map.put(:sdr_prototype_code, :withheld)
    }

  defp level_of(%{level: level}) when level in @levels, do: level
  defp level_of(_event), do: :error

  defp meta_of(%{meta: meta}) when is_map(meta), do: meta
  defp meta_of(_event), do: %{}

  # ExceptionFilter's validated standard metadata; everything else dropped.
  defp standard(meta), do: meta |> Enum.filter(&safe_standard?/1) |> Map.new()

  defp safe_standard?({:pid, pid}), do: is_pid(pid)
  defp safe_standard?({:gl, pid}), do: is_pid(pid)
  defp safe_standard?({:time, time}), do: is_integer(time)
  defp safe_standard?({:line, line}), do: is_integer(line)

  defp safe_standard?({:mfa, {m, f, a}}),
    do: is_atom(m) and is_atom(f) and is_integer(a) and a >= 0

  defp safe_standard?({:file, file}) when is_binary(file),
    do: byte_size(file) <= @max_file and String.valid?(file)

  defp safe_standard?({:file, file}) when is_list(file),
    do: length(file) <= @max_file and Enum.all?(file, &(is_integer(&1) and &1 in 0..0x10FFFF))

  defp safe_standard?({:domain, domain}) when is_list(domain),
    do: length(domain) <= @max_domain and Enum.all?(domain, &is_atom/1)

  defp safe_standard?(_entry), do: false

  # `{:ok, refs in shape order}` when `refs` has exactly the code's keys,
  # each once and of its pinned type; `:error` otherwise (an unknown code
  # included). No atom is ever created.
  defp validate(code, refs) when is_map_key(@shapes, code) and is_list(refs) do
    shape = Map.fetch!(@shapes, code)

    with true <- Keyword.keyword?(refs),
         true <- length(refs) == length(shape),
         true <- Enum.sort(Keyword.keys(refs)) == Enum.sort(Keyword.keys(shape)),
         true <- Enum.all?(shape, fn {key, type} -> valid?(type, Keyword.fetch!(refs, key)) end) do
      {:ok, Enum.map(shape, fn {key, _type} -> {key, Keyword.fetch!(refs, key)} end)}
    else
      _invalid -> :error
    end
  end

  defp validate(_code, _refs), do: :error

  defp valid?(:uuid, value), do: uuid?(value)
  defp valid?(:count, value), do: is_integer(value) and value in 0..1_000_000
  defp valid?({:count, range}, value), do: is_integer(value) and value in range
  defp valid?({:enum, values}, value), do: is_atom(value) and value in values

  defp uuid?(
         <<a::binary-size(8), ?-, b::binary-size(4), ?-, c::binary-size(4), ?-, d::binary-size(4),
           ?-, e::binary-size(12)>>
       ),
       do: Enum.all?([a, b, c, d, e], &lower_hex?/1)

  defp uuid?(_value), do: false

  defp lower_hex?(part),
    do: part |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  @doc """
  Installs the content-free primary filter and the file sink. Held (S-d,
  the file sink, Codex b069e93f): it refuses `{:error, :not_implemented}`
  and changes nothing.
  """
  @spec attach() :: :ok | {:error, atom()}
  def attach, do: red({:error, :not_implemented})

  @doc """
  `attach(file: nil)` installs the primary filter `:sdr_prototype_content_free`
  with no file sink, with `SdrAgent.Logger.ExceptionFilter` before it.
  `:logger` applies primary filters in list order and puts a newly added
  one first, so SafeLog's filter is added (unless already installed
  exactly) and then ExceptionFilter is re-attached. Idempotent: each is
  installed once, and SafeLog's filter is never removed on the way, so a
  repeated attach leaves no unfiltered window.

  Any failure returns `{:error, :attach_failed}`, and the caller (a task,
  startup) must stop BEFORE reading any input: the error does not
  establish that SafeLog's filter is installed. A foreign callback under
  SafeLog's id is refused unchanged and never assumed content-free, and a
  failed first add installs nothing. Only when SafeLog's own filter was
  installed before a later step failed does it stay, as a safe fallback.
  Any other option list refuses `{:error, :not_implemented}` without
  changing the logger (S-d is held).
  """
  @spec attach(keyword()) :: :ok | {:error, atom()}
  def attach(file: nil) do
    with :ok <- ensure_filter(),
         :ok <- SdrAgent.Logger.ExceptionFilter.attach() do
      :ok
    else
      _failure -> {:error, :attach_failed}
    end
  end

  def attach(_opts), do: {:error, :not_implemented}

  defp ensure_filter do
    case installed() do
      :absent -> :logger.add_primary_filter(@filter_id, own_filter())
      :own -> :ok
      :foreign -> {:error, :foreign_filter}
    end
  end

  # What is registered under SafeLog's filter id: nothing, SafeLog's own
  # callback, or a foreign one (Codex db38fb96 R1).
  defp installed do
    case List.keyfind(:logger.get_primary_config().filters, @filter_id, 0) do
      nil -> :absent
      {@filter_id, filter} -> if filter == own_filter(), do: :own, else: :foreign
    end
  end

  defp own_filter, do: {&__MODULE__.filter/2, []}

  @doc """
  Removes SafeLog's own primary filter alone (tests):
  `SdrAgent.Logger.ExceptionFilter` and every handler are left as they are.
  `:ok` also when nothing is registered under SafeLog's id. A foreign
  callback under that id is refused `{:error, :foreign_filter}` and left in
  place (Codex db38fb96 R1).
  """
  @spec detach() :: :ok | {:error, term()}
  def detach do
    case installed() do
      :absent -> :ok
      :own -> remove_own()
      :foreign -> {:error, :foreign_filter}
    end
  end

  defp remove_own do
    case :logger.remove_primary_filter(@filter_id) do
      :ok -> :ok
      {:error, {:not_found, @filter_id}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Held stub result of attach/0 (S-d), typed dynamic() so callers'
  # success clauses compile against it (Elixir 1.20 infers literal
  # returns); read-only, nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
