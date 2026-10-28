defmodule SdrAgent.Prototype.SafeLogContractTest.Capture do
  @moduledoc false
  # A test-only `:logger` handler: sends every event it receives to the pid
  # in its config, so a test can assert an event's level, message and
  # metadata exactly. Added and removed by the test that uses it.

  def log(event, %{config: %{pid: pid}}), do: send(pid, {:logged, event})
end

defmodule SdrAgent.Prototype.SafeLogContractTest do
  @moduledoc """
  IF-8 content-free logging (interfaces r6; F6, R2): the closed contracts
  of `SdrAgent.Prototype.SafeLog` beyond `safe_log_test.exs`, per Codex
  b069e93f (the SafeLog reached-RED rulings). Synthetic canary markers
  only.

  - `filter/2` closed shapes: every code, the count bounds and ranges,
    the canonical UUID, the per-code enums, missing, duplicate and extra
    keys, non-keyword refs and unknown codes; the validated standard
    metadata (ExceptionFilter's `scan_limit` set) of a rebuilt or withheld
    event; invalid levels and malformed events fail closed, never raising.
  - Ruling 2, levels: a successful event at `:info`; a refusal, a
    rollback and a malformed event at `:warning`. The test logger level is
    `:warning`, so the `:info` case raises the primary level to `:info`
    and restores it (this module is `async: false`); a test-only handler
    records the events.
  - Ruling 3: malformed `say/2` input prints exactly
    `"prototype: log content withheld\\n"`.
  - Ruling 1: `attach(file: nil)` leaves `SdrAgent.Logger.ExceptionFilter`
    BEFORE SafeLog's filter in the primary filter list (`:logger` applies
    primary filters in list order), each exactly once, also when repeated;
    every other attach form refuses without changing the logger (S-d, the
    file sink, is held).

  The primary filter and level are VM-wide, so this module is
  `async: false` and restores them after every test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.Prototype.SafeLogContractTest.Capture

  @marker "CANARY-d237-safelog-c0n7"
  @withheld "prototype: log content withheld"
  @filter_id :sdr_prototype_content_free
  @exception_filter :sdr_agent_exception_filter
  @handler :sdr_prototype_safe_log_contract_capture

  setup do
    on_exit(fn ->
      _ = SafeLog.detach()
      _ = :logger.remove_primary_filter(@filter_id)
    end)

    :ok
  end

  defp standard_meta do
    %{
      pid: self(),
      gl: Process.group_leader(),
      time: :logger.timestamp(),
      line: 12,
      mfa: {SafeLog, :event, 2},
      file: "lib/sdr_agent/prototype/example.ex",
      domain: [:elixir]
    }
  end

  defp tagged(code, refs) do
    %{
      level: :warning,
      msg: {:string, "tagged #{@marker}"},
      meta: Map.merge(standard_meta(), %{sdr_prototype_code: code, sdr_prototype_refs: refs})
    }
  end

  defp filtered(event), do: SafeLog.filter(event, :sdr_prototype_content_free)

  defp withheld?(result) do
    match?(%{msg: {:string, @withheld}, meta: %{sdr_prototype_code: :withheld}}, result) and
      not Map.has_key?(result.meta, :sdr_prototype_refs) and
      not (inspect(result) =~ @marker)
  end

  defp shape_order(code, refs) do
    for {key, _type} <- Map.fetch!(SafeLog.shapes(), code), do: {key, Keyword.fetch!(refs, key)}
  end

  defp filter_ids, do: Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))

  # Records every event through the test-only handler, with the primary
  # level set to `level`; both are restored when the test exits.
  defp capture_events(level) do
    previous = Logger.level()

    on_exit(fn ->
      _ = :logger.remove_handler(@handler)
      Logger.configure(level: previous)
    end)

    :ok = :logger.add_handler(@handler, Capture, %{config: %{pid: self()}, level: :all})
    Logger.configure(level: level)
  end

  defp received_events(code) do
    {:messages, messages} = Process.info(self(), :messages)

    for {:logged, %{meta: %{sdr_prototype_code: ^code}} = event} <- messages,
        do: {event.level, event.msg, event.meta[:sdr_prototype_refs]}
  end

  defp position(ids, id), do: Enum.find_index(ids, &(&1 == id))

  # One valid refs list per code, in shape order.
  defp valid_refs do
    uuid = Ecto.UUID.generate()

    %{
      boot: [result: :refused, reason: :binding_absent],
      setup_phase: [phase: 2, result: :rolled_back, reason: :migration_failed],
      seed_result: [revisions: 4, result: :replay],
      import_row: [row_index: 14, result: :skipped, reason: :role_mailbox],
      import_summary: [imported: 1, replayed: 0, refused: 2, cap_used: 3],
      provisioned: [grant_id: uuid, result: :created, reason: :none],
      op_result: [command: :approve, id: uuid, result: :refused, reason: :stale_review],
      bundle_written: [bundle_id: uuid, items: 7],
      status_counts: [
        invocations: 5,
        released: 1,
        withheld: 2,
        captured: 0,
        attempts_left: 1_000_000
      ]
    }
  end

  describe "filter/2 closed shapes" do
    test "every code's valid refs, given in any order, are rebuilt in shape order" do
      table = valid_refs()
      # Construction check: the table covers exactly the closed code set.
      assert Enum.sort(Map.keys(table)) == SafeLog.codes()

      for {code, refs} <- table do
        result = filtered(tagged(code, Enum.reverse(refs)))
        line = "prototype: #{code}"

        assert match?(%{msg: {:string, ^line}, meta: %{sdr_prototype_code: ^code}}, result),
               "#{code}: not rebuilt: #{inspect(result)}"

        assert result.meta.sdr_prototype_refs == shape_order(code, refs),
               "#{code}: refs not in shape order: #{inspect(result.meta.sdr_prototype_refs)}"

        assert result.level == :warning
        refute inspect(result) =~ @marker, "#{code}: the marker survived"
      end
    end

    test "counts: 0 and 1,000,000 are kept; out of range, floats and strings are withheld" do
      base = [imported: 0, replayed: 0, refused: 0, cap_used: 0]

      for value <- [0, 1_000_000] do
        result = filtered(tagged(:import_summary, Keyword.put(base, :imported, value)))

        assert match?(%{msg: {:string, "prototype: import_summary"}}, result),
               "count #{value} was not kept: #{inspect(result)}"
      end

      for value <- [-1, 1_000_001, 1.0, "1", nil, :one] do
        result = filtered(tagged(:import_summary, Keyword.put(base, :imported, value)))
        assert withheld?(result), "count #{inspect(value)} was not withheld: #{inspect(result)}"
      end
    end

    test "ranged counts: each bound is kept and one past it is withheld" do
      setup = [phase: 0, result: :ok, reason: :none]
      row = [row_index: 0, result: :imported, reason: :none]

      for {code, refs, key, kept, refused} <- [
            {:setup_phase, setup, :phase, [0, 3], [-1, 4]},
            {:import_row, row, :row_index, [0, 14], [-1, 15]}
          ] do
        for value <- kept do
          result = filtered(tagged(code, Keyword.put(refs, key, value)))

          assert match?(%{meta: %{sdr_prototype_code: ^code}}, result),
                 "#{code} #{key}=#{value} was not kept: #{inspect(result)}"
        end

        for value <- refused do
          result = filtered(tagged(code, Keyword.put(refs, key, value)))
          assert withheld?(result), "#{code} #{key}=#{value} was not withheld: #{inspect(result)}"
        end
      end
    end

    test "uuids: only the canonical lowercase 36-character form is kept" do
      uuid = Ecto.UUID.generate()
      refs = &[bundle_id: &1, items: 1]

      assert match?(
               %{msg: {:string, "prototype: bundle_written"}},
               filtered(tagged(:bundle_written, refs.(uuid)))
             ),
             "a canonical uuid was not kept"

      bad = [
        String.upcase(uuid),
        String.replace(uuid, "-", ""),
        String.replace(uuid, ~r/^./, "g"),
        " " <> uuid,
        uuid <> "\n",
        String.to_charlist(uuid),
        @marker,
        nil
      ]

      for value <- bad do
        result = filtered(tagged(:bundle_written, refs.(value)))
        assert withheld?(result), "uuid #{inspect(value)} was not withheld: #{inspect(result)}"
      end
    end

    test "enums: only the code's own closed set; strings and other codes' reasons are withheld" do
      uuid = Ecto.UUID.generate()

      bad = [
        {:import_row, [row_index: 0, result: :imported, reason: :binding_absent]},
        {:op_result, [command: :assign, id: uuid, result: :ok, reason: :worksheet_invalid]},
        {:op_result, [command: :delete, id: uuid, result: :ok, reason: :none]},
        {:boot, [result: :rolled_back, reason: :none]},
        {:boot, [result: "ok", reason: :none]},
        {:boot, [result: :ok, reason: nil]},
        {:seed_result, [revisions: 1, result: :imported]}
      ]

      for {code, refs} <- bad do
        result = filtered(tagged(code, refs))
        assert withheld?(result), "#{code} #{inspect(refs)} was not withheld: #{inspect(result)}"
      end
    end

    test "missing, duplicated and extra keys, and refs that are not a keyword list, are withheld" do
      bad = [
        [result: :ok],
        [result: :ok, result: :ok],
        [result: :ok, reason: :none, reason: :none],
        [result: :ok, reason: :none, note: @marker],
        %{result: :ok, reason: :none},
        [{"result", :ok}, {"reason", :none}],
        [{:result, :ok} | :tail],
        nil,
        @marker
      ]

      for refs <- bad do
        result = filtered(tagged(:boot, refs))
        assert withheld?(result), "refs #{inspect(refs)} were not withheld: #{inspect(result)}"
      end
    end

    test "a code that is not one of the closed atoms is withheld" do
      for code <- ["boot", nil, :withheld, :"prototype: boot", 1] do
        result = filtered(tagged(code, result: :ok, reason: :none))
        assert withheld?(result), "code #{inspect(code)} was not withheld: #{inspect(result)}"
      end
    end
  end

  describe "filter/2 metadata, levels and failures" do
    test "a rebuilt or a withheld event keeps exactly the validated standard metadata" do
      standard = standard_meta()
      extra = %{note: @marker, crash_reason: {:error, @marker}, request_id: @marker}
      tag = %{sdr_prototype_code: :boot, sdr_prototype_refs: [result: :ok, reason: :none]}
      meta = standard |> Map.merge(extra) |> Map.merge(tag)

      rebuilt = filtered(%{level: :warning, msg: {:string, @marker}, meta: meta})

      assert match?(%{meta: %{sdr_prototype_code: :boot}}, rebuilt),
             "a valid event was not rebuilt: #{inspect(rebuilt)}"

      assert rebuilt.meta == Map.merge(standard, tag)

      untagged = %{level: :error, msg: {:string, @marker}, meta: Map.merge(standard, extra)}
      withheld = filtered(untagged)
      assert withheld?(withheld), "an untagged event was not withheld: #{inspect(withheld)}"
      assert withheld.meta == Map.put(standard, :sdr_prototype_code, :withheld)
    end

    test "each invalid standard metadata value is dropped" do
      atoms = for i <- 1..17, do: :"domain_#{i}"

      bad = [
        pid: @marker,
        gl: @marker,
        time: 1.5,
        line: "12",
        mfa: {@marker, :f, 1},
        mfa: {SafeLog, :event, -1},
        mfa: @marker,
        file: String.duplicate("a", 1_025),
        file: [1.5],
        domain: [@marker],
        domain: atoms,
        domain: :elixir
      ]

      for {key, value} <- bad do
        meta = %{
          key => value,
          sdr_prototype_code: :boot,
          sdr_prototype_refs: [result: :ok, reason: :none]
        }

        result = filtered(%{level: :error, msg: {:string, "x"}, meta: meta})

        assert match?(%{meta: %{sdr_prototype_code: :boot}}, result),
               "#{key}: the valid tag was not rebuilt: #{inspect(result)}"

        refute Map.has_key?(result.meta, key), "#{key}=#{inspect(value)} was kept"
        refute inspect(result) =~ @marker, "#{key}: the marker survived"
      end
    end

    test "an invalid or missing level becomes :error; a valid level is kept" do
      refs = [result: :ok, reason: :none]

      for {level, expected} <- [bogus: :error, info: :info, emergency: :emergency] do
        event = %{tagged(:boot, refs) | level: level}
        result = filtered(event)
        assert match?(%{level: ^expected}, result), "level #{level}: #{inspect(result)}"
      end

      result = filtered(Map.delete(tagged(:boot, refs), :level))
      assert match?(%{level: :error}, result), "missing level: #{inspect(result)}"
    end

    test "malformed events never raise and are withheld, never ignored or passed through" do
      bad = [
        :garbage,
        nil,
        %{},
        %{level: :error},
        %{level: :warning, msg: {:string, @marker}, meta: [note: @marker]},
        %{level: :warning, msg: {:string, @marker}, meta: @marker},
        %{level: :error, msg: @marker, meta: %{sdr_prototype_code: :boot}}
      ]

      for event <- bad do
        result =
          try do
            filtered(event)
          rescue
            error -> {:raised, error}
          catch
            kind, value -> {:caught, kind, value}
          end

        assert withheld?(result), "#{inspect(event)}: not withheld: #{inspect(result)}"
        assert result.level in [:error, :warning]
      end
    end
  end

  describe "event/2 levels (Codex b069e93f ruling 2)" do
    test "a successful event is logged at :info with the fixed message and its validated refs" do
      capture_events(:info)
      refs = [revisions: 2, result: :ok]

      result = SafeLog.event(:seed_result, Enum.reverse(refs))

      assert received_events(:seed_result) == [{:info, {:string, "prototype: seed_result"}, refs}],
             "no single :info seed_result event (event/2 returned #{inspect(result)})"

      assert result == :ok
    end

    test "a refusal, a rollback and a malformed event are logged at :warning" do
      capture_events(:warning)

      refused = SafeLog.event(:boot, result: :refused, reason: :binding_absent)

      rolled_back =
        SafeLog.event(:setup_phase, phase: 1, result: :rolled_back, reason: :storage_failed)

      malformed = SafeLog.event(:boot, result: :ok, reason: :none, note: @marker)

      assert received_events(:boot) ==
               [
                 {:warning, {:string, "prototype: boot"},
                  [result: :refused, reason: :binding_absent]}
               ],
             "no single :warning boot refusal (event/2 returned #{inspect(refused)})"

      assert received_events(:setup_phase) ==
               [
                 {:warning, {:string, "prototype: setup_phase"},
                  [phase: 1, result: :rolled_back, reason: :storage_failed]}
               ],
             "no single :warning setup_phase rollback (event/2 returned #{inspect(rolled_back)})"

      assert received_events(:withheld) == [{:warning, {:string, @withheld}, nil}],
             "no single :warning withheld line (event/2 returned #{inspect(malformed)})"

      {:messages, messages} = Process.info(self(), :messages)
      refute inspect(messages) =~ @marker, "a logged event carried the marker"
      assert [refused, rolled_back, malformed] == [:ok, :ok, :ok]
    end
  end

  describe "say/2 (Codex b069e93f ruling 3)" do
    test "malformed refs print exactly the fixed withheld line, with no code or value" do
      uuid = Ecto.UUID.generate()

      bad = [
        {:no_such_code, [note: @marker]},
        {:op_result, [command: :assign, id: @marker, result: :ok, reason: :none]},
        {:op_result, [command: :assign, id: uuid, result: :ok]},
        {:bundle_written, [bundle_id: uuid, items: 1, note: @marker]},
        {"op_result", [command: :assign, id: uuid, result: :ok, reason: :none]}
      ]

      for {code, refs} <- bad do
        {result, out} = with_io(fn -> SafeLog.say(code, refs) end)

        assert out == "prototype: log content withheld\n",
               "#{inspect(code)}: printed #{inspect(out)} (returned #{inspect(result)})"

        assert result == :ok
      end
    end

    test "a valid status line has every ref in shape order, counts as integers" do
      refs = [invocations: 3, released: 1, withheld: 1, captured: 0, attempts_left: 2]
      {result, out} = with_io(fn -> SafeLog.say(:status_counts, Enum.reverse(refs)) end)

      assert out ==
               "prototype: status_counts invocations=3 released=1 withheld=1 captured=0 attempts_left=2\n",
             "printed #{inspect(out)} (returned #{inspect(result)})"

      assert result == :ok
    end
  end

  describe "attach (Codex b069e93f ruling 1; S-c is file: nil only)" do
    test "attach(file: nil) runs ExceptionFilter before SafeLog, each exactly once, also when repeated" do
      for round <- 1..3 do
        assert SafeLog.attach(file: nil) == :ok, "round #{round}: attach refused"
        ids = filter_ids()

        assert Enum.count(ids, &(&1 == @filter_id)) == 1,
               "round #{round}: SafeLog's filter not present exactly once: #{inspect(ids)}"

        assert Enum.count(ids, &(&1 == @exception_filter)) == 1,
               "round #{round}: ExceptionFilter not present exactly once: #{inspect(ids)}"

        assert position(ids, @exception_filter) < position(ids, @filter_id),
               "round #{round}: ExceptionFilter does not run before SafeLog: #{inspect(ids)}"
      end
    end

    test "every other attach form refuses without changing the filters or the handlers" do
      filters = :logger.get_primary_config().filters
      handlers = Enum.sort_by(:logger.get_handler_config(), & &1.id)

      for opts <- [
            [file: "/nonexistent/d237/app.log"],
            [],
            [file: nil, extra: true],
            [file: :default]
          ] do
        result = SafeLog.attach(opts)
        assert match?({:error, _reason}, result), "#{inspect(opts)}: #{inspect(result)}"

        assert :logger.get_primary_config().filters == filters,
               "#{inspect(opts)} changed the filters"
      end

      assert match?({:error, _reason}, SafeLog.attach())
      assert :logger.get_primary_config().filters == filters, "attach/0 changed the filters"
      assert Enum.sort_by(:logger.get_handler_config(), & &1.id) == handlers
    end
  end
end
