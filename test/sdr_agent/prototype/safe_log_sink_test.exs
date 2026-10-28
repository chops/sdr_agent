defmodule SdrAgent.Prototype.SafeLogSinkTest do
  @moduledoc """
  IF-8 file sink (S-d) of `SdrAgent.Prototype.SafeLog`: DRAFT RED r2 for
  Codex 6793b950 (S1b; not committed). The proposed contract:

  - **Static checks** (`{:error, :log_file_unsafe}`, no filesystem or
    logger change). `attach(file: path)` takes an absolute path. Its
    immediate parent must be, by `lstat`, a real directory of mode 0700.
    A symlink above the parent is accepted only when root (uid 0) owns it,
    as with the macOS platform aliases `/tmp` and `/var` →
    `/private/...`; any other symlink in the chain is refused. An existing
    file must be, by `lstat`, a regular file of mode 0600 with one link.
  - **Handle binding.** The sink writes through ONE device that SafeLog
    opens itself. The `:default` handler becomes `logger_std_h` with
    `type: {:device, device}`, so the logger never opens, reopens or
    rotates the path.
    - An existing file is opened for append, then checked before the
      first write: the device's fstat must be the checked object, still
      regular, 0600 and single-link, and the parent must still be the
      checked 0700 directory. Otherwise `:log_file_unsafe`, with nothing
      written.
    - An absent file is created exclusively. The path must still be the
      created object before it is set to 0600; the device must then show
      0600, and the parent is rechecked. Otherwise `:attach_failed`; the
      owned empty file is kept and never deleted.
  - **Order.** The file is bound first. Then SafeLog's filter is installed
    (ExceptionFilter first), and only then is `:default` redirected,
    keeping the original handler's level, filters, filter default and
    formatter. A failure after the file or the filter exists gives
    `:attach_failed` and keeps the safe fallback; the caller stops before
    reading any input.
  - **State.** SafeLog keeps module-private state: the original
    `:default` (captured once) and the installed sink's exact config.
    - A same-path repeat revalidates the file, the parent and the
      installed ownership, and never replaces the saved original.
    - A different path while a sink is active is `:attach_failed` and
      changes nothing.
    - `detach/0` restores the original only while `:default` is still
      exactly the owned sink; otherwise it returns `:foreign_handler` and
      keeps everything. It then removes SafeLog's own filter, closes the
      device and clears the state. The file is kept.
    - A `file: nil` attachment never touches handlers.

  Races are synchronized by the test-build hooks
  `{SdrAgent.Prototype.SafeLog, name}` in this process's dictionary:
  `:after_precheck` (path), `:after_open` (device), `:after_bind`
  (device). The primary filters and `:default` are VM-wide, so this module
  is `async: false`. Every test restores them and removes its owned
  scratch roots. A test that leaves a foreign state behind cleans it up
  itself.
  """
  use ExUnit.Case, async: false

  require Logger

  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.PrototypeFixtures

  @marker "CANARY-d237-safelog-s1nk"
  @withheld "prototype: log content withheld"
  @filter_id :sdr_prototype_content_free
  @exception_filter :sdr_agent_exception_filter

  setup do
    {:ok, default} = :logger.get_handler_config(:default)

    on_exit(fn ->
      _ = detach()
      own = {&SafeLog.filter/2, []}

      with {@filter_id, ^own} <- List.keyfind(primary_filters(), @filter_id, 0),
           do: :logger.remove_primary_filter(@filter_id)

      restore_default(default)
    end)

    %{dir: PrototypeFixtures.scratch_dir!(), default: default}
  end

  @doc false
  # A pass-through handler filter: a fixture marking a non-default
  # original `:default` configuration.
  def pass(event, _extra), do: event

  defp restore_default(default) do
    if :logger.get_handler_config(:default) != {:ok, default} do
      _ = :logger.remove_handler(:default)
      _ = :logger.add_handler(:default, default.module, Map.drop(default, [:id, :module]))
    end
  end

  # Dynamic calls: until S-d's GREEN, Elixir 1.20 infers the held refusals
  # and would warn on comparisons with the contract's results.
  defp attach_file(path), do: Function.capture(SafeLog, :attach, 1).(file: path)
  defp detach, do: Function.capture(SafeLog, :detach, 0).()

  defp hook(name, fun), do: Process.put({SafeLog, name}, fun)

  defp primary_filters, do: :logger.get_primary_config().filters

  defp logger_state,
    do: {primary_filters(), Enum.sort_by(:logger.get_handler_config(), & &1.id)}

  defp mode(path) do
    case File.lstat(path) do
      {:ok, stat} -> {stat.type, Bitwise.band(stat.mode, 0o777), stat.links}
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_file!(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  defp bound_device do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: :logger_std_h, config: %{type: {:device, device}}}} -> device
      other -> {:not_a_device_sink, other}
    end
  end

  # The sink's device is the very object at `path` (fstat versus lstat).
  defp bound_to?(path) do
    with device when is_pid(device) <- bound_device(),
         {:ok, info} <- :file.read_file_info(device, time: :posix),
         {:ok, stat} <- File.lstat(path) do
      opened = File.Stat.from_record(info)
      {opened.major_device, opened.inode} == {stat.major_device, stat.inode}
    else
      _other -> false
    end
  end

  defp sync_and_read(path) do
    assert :logger_std_h.filesync(:default) == :ok
    File.read!(path)
  end

  # A non-default original `:default`: another level and one extra filter.
  defp non_default_original! do
    assert :logger.update_handler_config(:default, :level, :notice) == :ok

    assert :logger.add_handler_filter(:default, :s1b_fixture, {&__MODULE__.pass/2, :fixture}) ==
             :ok

    {:ok, original} = :logger.get_handler_config(:default)
    original
  end

  defp ancestors(path), do: path |> Path.split() |> Enum.scan(&Path.join(&2, &1)) |> Enum.drop(-1)

  defp assert_unsafe(path, label) do
    before = logger_state()
    result = attach_file(path)
    assert result == {:error, :log_file_unsafe}, "#{label}: #{inspect(result)}"
    assert logger_state() == before, "#{label}: the refusal changed the logger"
  end

  describe "attach(file: path) installs a device-bound private sink" do
    test "an absent file is created exclusively at 0600; real log calls land code-only or withheld",
         %{dir: dir} do
      path = Path.join(dir, "app.log")

      assert attach_file(path) == :ok
      assert mode(path) == {:regular, 0o600, 1}
      assert bound_to?(path), "the sink does not write through the created file's device"

      ids = Enum.map(primary_filters(), &elem(&1, 0))

      assert Enum.find_index(ids, &(&1 == @exception_filter)) <
               Enum.find_index(ids, &(&1 == @filter_id)),
             "ExceptionFilter does not run before SafeLog: #{inspect(ids)}"

      Logger.error("sink #{@marker}")
      assert SafeLog.event(:boot, result: :refused, reason: :binding_absent) == :ok
      content = sync_and_read(path)

      assert content =~ @withheld
      assert content =~ "prototype: boot"
      refute content =~ @marker, "the file sink received the marker"
      assert mode(path) == {:regular, 0o600, 1}, "writing changed the file's mode or links"
    end

    test "an existing private regular file is appended through its own device, never truncated",
         %{dir: dir} do
      path = private_file!(Path.join(dir, "app.log"), "earlier line\n")

      assert attach_file(path) == :ok
      assert bound_to?(path)
      Logger.error("append #{@marker}")
      content = sync_and_read(path)

      assert String.starts_with?(content, "earlier line\n"), "the earlier bytes were lost"
      assert content =~ @withheld
      refute content =~ @marker
    end

    test "the sink keeps the original handler's level, filters, filter default and formatter",
         %{dir: dir} do
      original = non_default_original!()
      path = Path.join(dir, "app.log")

      assert attach_file(path) == :ok
      sink = :logger.get_handler_config(:default)

      assert match?({:ok, %{module: :logger_std_h, config: %{type: {:device, _device}}}}, sink),
             "the default handler is not the device sink: #{inspect(sink)}"

      kept = [:level, :filters, :filter_default, :formatter]
      assert Map.take(elem(sink, 1), kept) == Map.take(original, kept)
    end

    test "the logger never reopens the path: a file put at the path afterwards receives nothing",
         %{dir: dir} do
      path = Path.join(dir, "app.log")
      assert attach_file(path) == :ok

      moved = Path.join(dir, "moved.log")
      File.rename!(path, moved)
      private_file!(path, "")
      Logger.error("after the rename #{@marker}")

      assert :logger_std_h.filesync(:default) == :ok
      assert File.read!(moved) =~ @withheld, "the bound (moved) file got no line"
      assert File.read!(path) == "", "the logger followed the path to a new file"
    end
  end

  describe "lifecycle and ownership" do
    test "attach, same-path repeat, detach, second detach and reattach preserve the original exactly",
         %{dir: dir} do
      original = non_default_original!()
      path = Path.join(dir, "app.log")

      assert attach_file(path) == :ok
      sink = :logger.get_handler_config(:default)
      device = bound_device()

      assert attach_file(path) == :ok, "a same-path repeat was refused"
      assert :logger.get_handler_config(:default) == sink, "the repeat replaced the sink"

      assert detach() == :ok
      assert :logger.get_handler_config(:default) == {:ok, original}
      refute List.keymember?(primary_filters(), @filter_id, 0)
      refute is_pid(device) and Process.alive?(device), "detach left the device open"
      assert mode(path) == {:regular, 0o600, 1}, "detach removed or changed the file"

      assert detach() == :ok, "a second detach was refused"
      assert :logger.get_handler_config(:default) == {:ok, original}

      assert attach_file(path) == :ok, "reattach was refused"
      assert bound_to?(path)
      Logger.error("reattached #{@marker}")
      assert sync_and_read(path) =~ @withheld

      assert detach() == :ok
      assert :logger.get_handler_config(:default) == {:ok, original}
    end

    test "a different path while a sink is active: attach_failed, nothing changes, no file created",
         %{dir: dir, default: default} do
      path = Path.join(dir, "app.log")
      assert attach_file(path) == :ok
      before = logger_state()
      other = Path.join(dir, "other.log")

      assert attach_file(other) == {:error, :attach_failed}
      refute File.exists?(other), "the second path was created"
      assert logger_state() == before, "the second attach changed the logger"
      assert bound_to?(path)

      assert detach() == :ok
      assert :logger.get_handler_config(:default) == {:ok, default}
    end

    test "a same-path repeat revalidates the file: a widened mode refuses and is not repaired",
         %{dir: dir, default: default} do
      path = Path.join(dir, "app.log")
      assert attach_file(path) == :ok
      before = logger_state()
      File.chmod!(path, 0o644)

      assert attach_file(path) == {:error, :attach_failed}
      assert logger_state() == before
      assert mode(path) == {:regular, 0o644, 1}, "the mode was repaired"

      assert detach() == :ok
      assert :logger.get_handler_config(:default) == {:ok, default}
    end

    test "a foreign :default: a repeat refuses, detach returns foreign_handler and keeps everything",
         %{dir: dir, default: default} do
      path = Path.join(dir, "app.log")
      assert attach_file(path) == :ok
      {:ok, sink} = :logger.get_handler_config(:default)

      foreign = %{
        config: %{type: :standard_error},
        level: :error,
        filter_default: :log,
        filters: [],
        formatter: sink.formatter
      }

      assert :logger.remove_handler(:default) == :ok
      assert :logger.add_handler(:default, :logger_std_h, foreign) == :ok
      {:ok, foreign_now} = :logger.get_handler_config(:default)
      filters = primary_filters()

      assert attach_file(path) == {:error, :attach_failed}
      assert detach() == {:error, :foreign_handler}
      assert :logger.get_handler_config(:default) == {:ok, foreign_now}
      assert primary_filters() == filters, "detach removed a filter while refusing"
      assert detach() == {:error, :foreign_handler}, "the sink state was dropped"

      # This test's own cleanup: put the owned sink back, then detach for real.
      assert :logger.remove_handler(:default) == :ok
      assert :logger.add_handler(:default, :logger_std_h, Map.drop(sink, [:id, :module])) == :ok
      assert detach() == :ok
      assert :logger.get_handler_config(:default) == {:ok, default}
    end

    test "a file: nil attachment is independent: detach restores no handler it did not replace",
         %{default: default} do
      assert SafeLog.attach(file: nil) == :ok
      assert detach() == :ok
      assert :logger.get_handler_config(:default) == {:ok, default}
      refute List.keymember?(primary_filters(), @filter_id, 0)
    end
  end

  describe "a failed install (deterministic)" do
    test "a foreign callback under SafeLog's id: attach_failed; the owned empty file is kept",
         %{dir: dir} do
      foreign = {&SdrAgent.Logger.ExceptionFilter.filter/2, []}

      on_exit(fn ->
        with {@filter_id, ^foreign} <- List.keyfind(primary_filters(), @filter_id, 0),
             do: :logger.remove_primary_filter(@filter_id)
      end)

      assert :logger.add_primary_filter(@filter_id, foreign) == :ok
      before = logger_state()
      path = Path.join(dir, "app.log")

      assert attach_file(path) == {:error, :attach_failed}
      assert logger_state() == before, "a failed install changed the filters or the handlers"
      assert mode(path) == {:regular, 0o600, 1}, "the owned created file was not kept private"
      assert File.read!(path) == ""
      assert detach() == {:error, :foreign_filter}
      assert logger_state() == before
    end

    test "no :default handler to replace: attach_failed; the file and SafeLog's filter stay",
         %{dir: dir} do
      assert :logger.remove_handler(:default) == :ok
      path = Path.join(dir, "app.log")

      assert attach_file(path) == {:error, :attach_failed}
      assert File.read!(path) == "", "the owned created file was not kept"
      assert List.keymember?(primary_filters(), @filter_id, 0), "the safe fallback filter is gone"
      assert :logger.get_handler_config(:default) == {:error, {:not_found, :default}}
    end
  end

  describe "static unsafe paths: log_file_unsafe, nothing changes" do
    test "an existing file that is not mode 0600", %{dir: dir} do
      path = Path.join(dir, "app.log")
      File.write!(path, "kept\n")
      File.chmod!(path, 0o644)

      assert_unsafe(path, "mode 0644")
      assert File.read!(path) == "kept\n"
      assert mode(path) == {:regular, 0o644, 1}
    end

    test "a symlink, even to a private regular file; its target is never written", %{dir: dir} do
      outside = PrototypeFixtures.scratch_dir!()
      target = private_file!(Path.join(outside, "target.log"), "target\n")
      path = Path.join(dir, "app.log")
      File.ln_s!(target, path)

      assert_unsafe(path, "symlink")
      assert File.read!(target) == "target\n"
      assert match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
    end

    test "a hard link (more than one link)", %{dir: dir} do
      other = private_file!(Path.join(dir, "other.log"), "other\n")
      path = Path.join(dir, "app.log")
      File.ln!(other, path)

      assert_unsafe(path, "hard link")
      assert File.read!(other) == "other\n"
    end

    test "a directory", %{dir: dir} do
      path = Path.join(dir, "app.log")
      File.mkdir!(path)

      assert_unsafe(path, "directory")
      assert File.ls!(path) == []
    end

    test "a missing parent directory, which is never created", %{dir: dir} do
      assert_unsafe(Path.join([dir, "missing", "app.log"]), "missing parent")
      refute File.exists?(Path.join(dir, "missing"))
    end

    test "a parent directory that is not mode 0700, which is never re-moded" do
      dir = PrototypeFixtures.scratch_dir!(0o755)
      path = Path.join(dir, "app.log")

      assert_unsafe(path, "parent 0755")
      assert elem(mode(dir), 1) == 0o755, "the parent directory was re-moded"
      refute File.exists?(path)
    end

    test "an immediate parent that is a symlink to a private directory", %{dir: dir} do
      real = PrototypeFixtures.scratch_dir!()
      link = Path.join(dir, "linked")
      File.ln_s!(real, link)

      assert_unsafe(Path.join(link, "app.log"), "symlinked parent")
      assert File.ls!(real) == []
    end

    test "a user-owned symlink above the parent, even to a private directory", %{dir: dir} do
      real = PrototypeFixtures.scratch_dir!()
      logs = Path.join(real, "logs")
      File.mkdir!(logs)
      File.chmod!(logs, 0o700)
      alias_link = Path.join(dir, "alias")
      File.ln_s!(real, alias_link)

      assert_unsafe(Path.join([alias_link, "logs", "app.log"]), "user-owned ancestor symlink")
      refute File.exists?(Path.join(logs, "app.log"))
    end

    test "a relative path, which creates nothing" do
      name =
        "d237-s1b-sink-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ".log"

      # Only if a wrong implementation created it: this random name is the test's own.
      on_exit(fn -> File.rm(name) end)

      assert_unsafe(name, "relative path")
      refute File.exists?(name)
    end

    test "a parent under a root-owned platform alias (macOS /tmp, /var) is accepted", %{dir: dir} do
      aliases =
        for ancestor <- ancestors(dir),
            match?({:ok, %File.Stat{type: :symlink, uid: 0}}, File.lstat(ancestor)),
            do: ancestor

      # Construction check: on macOS the scratch roots lie under such an alias.
      if :os.type() == {:unix, :darwin},
        do: assert(aliases != [], "no root-owned alias above #{dir}")

      assert attach_file(Path.join(dir, "app.log")) == :ok
    end
  end

  describe "handle-binding races (synchronized hooks)" do
    test "an existing file swapped for a symlink after the checks: refused, the target never written",
         %{dir: dir} do
      path = private_file!(Path.join(dir, "app.log"), "existing\n")
      outside = PrototypeFixtures.scratch_dir!()
      target = private_file!(Path.join(outside, "target.log"), "target\n")

      hook(:after_precheck, fn _path ->
        File.rename!(path, Path.join(outside, "moved.log"))
        File.ln_s!(target, path)
      end)

      assert_unsafe(path, "symlink swap")
      assert File.read!(target) == "target\n"
      assert mode(target) == {:regular, 0o600, 1}
    end

    test "an existing file's mode widened after the checks: refused, never repaired", %{dir: dir} do
      path = private_file!(Path.join(dir, "app.log"), "existing\n")
      hook(:after_precheck, fn _path -> File.chmod!(path, 0o644) end)

      assert_unsafe(path, "mode widening")
      assert mode(path) == {:regular, 0o644, 1}, "the mode was repaired"
      assert File.read!(path) == "existing\n"
    end

    test "an existing file given a second link after the checks: refused", %{dir: dir} do
      path = private_file!(Path.join(dir, "app.log"), "existing\n")
      hook(:after_precheck, fn _path -> File.ln!(path, Path.join(dir, "second.log")) end)

      assert_unsafe(path, "link widening")
      assert File.read!(path) == "existing\n"
    end

    test "an absent file swapped after its exclusive creation: attach_failed, the foreign file untouched",
         %{dir: dir} do
      path = Path.join(dir, "app.log")
      moved = Path.join(PrototypeFixtures.scratch_dir!(), "owned.log")
      before = logger_state()

      hook(:after_open, fn _device ->
        File.rename!(path, moved)
        File.write!(path, "foreign\n")
        File.chmod!(path, 0o644)
      end)

      assert attach_file(path) == {:error, :attach_failed}
      assert logger_state() == before
      assert mode(path) == {:regular, 0o644, 1}, "the foreign file was chmod-ed"
      assert File.read!(path) == "foreign\n"
      assert File.read!(moved) == "", "the owned created file was not kept"
    end

    test "the parent replaced by a fresh private directory after the checks: attach_failed",
         %{dir: dir} do
      path = Path.join(dir, "app.log")
      aside = Path.join(PrototypeFixtures.scratch_dir!(), "moved-parent")
      before = logger_state()

      hook(:after_precheck, fn _path ->
        File.rename!(dir, aside)
        File.mkdir!(dir)
        File.chmod!(dir, 0o700)
      end)

      assert attach_file(path) == {:error, :attach_failed}
      assert logger_state() == before
      refute File.exists?(Path.join(aside, "app.log"))
    end
  end
end
