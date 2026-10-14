defmodule SdrAgent.CalibrationConsole.CalibratePrepareTest do
  @moduledoc """
  R0-07 packet 8.14.9 round 4 (contract/entity PASS at 87b8f0b, Codex
  65d641ce): the console's first-run setup, `Calibrate.prepare/1`, and the
  read-only `Evidence.check_dir/1`.

  `prepare/1` takes exactly `root` and `evidence_dir` (absolute, the
  latter `root/evidence`), checks the root by the launch-record rules, and
  creates the evidence directory only by an exclusive `mkdir`, the creator
  alone setting 0700. An existing name is only inspected by E2's rule and
  never changed. Nothing under the root other than a new evidence
  directory is ever written.

  `:calibration_setup_failed` (an I/O failure on a valid root) has no
  hermetic test in this scope; it is covered by review of the code.
  """
  use ExUnit.Case, async: false

  import Bitwise

  defmodule StaleProbe do
    @moduledoc false
    # OS facts for a synthetic launch record whose owner (pid 4242) is
    # alive at the claim and gone afterwards, so recovery takes a ticket.
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{4242 => "Mon 10:00 owner"} end, name: __MODULE__)

    def owner_gone, do: Agent.update(__MODULE__, fn _ -> %{} end)
    def self_pid, do: {:ok, 4242}

    def start_identity(pid) do
      case Agent.get(__MODULE__, &Map.fetch(&1, pid)) do
        {:ok, identity} -> {:ok, identity}
        :error -> :absent
      end
    end

    def group_members(_pgid), do: {:ok, []}
  end

  alias SdrAgent.CalibrationConsole.Calibrate
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.LaunchRecord

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "calibration")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    %{root: root, evidence: Path.join(root, "evidence"), tmp: tmp}
  end

  describe "prepare/1" do
    test "creates a missing evidence directory, 0700, by its own mkdir", ctx do
      defined!()
      assert prepare(ctx) == {:ok, :created}
      assert {File.dir?(ctx.evidence), mode(ctx.evidence)} == {true, 0o700}
      assert Evidence.check_dir(ctx.evidence) == :ok

      # The directory it created is the one later calls keep.
      created = inode(ctx.evidence)
      assert prepare(ctx) == {:ok, :existing}
      assert inode(ctx.evidence) == created
    end

    test "an existing safe empty directory is kept: same inode, mode and (no) contents", ctx do
      File.mkdir!(ctx.evidence)
      File.chmod!(ctx.evidence, 0o700)
      before = {inode(ctx.evidence), mode(ctx.evidence), File.ls!(ctx.evidence)}
      defined!()

      assert prepare(ctx) == {:ok, :existing}
      assert {inode(ctx.evidence), mode(ctx.evidence), File.ls!(ctx.evidence)} == before
    end

    test "leaves an existing safe directory exactly as it is", ctx do
      File.mkdir!(ctx.evidence)
      File.chmod!(ctx.evidence, 0o700)
      File.write!(Path.join(ctx.evidence, "kept.json"), "{}")
      before = {inode(ctx.evidence), mode(ctx.evidence), File.ls!(ctx.evidence)}
      defined!()

      assert prepare(ctx) == {:ok, :existing}
      assert {inode(ctx.evidence), mode(ctx.evidence), File.ls!(ctx.evidence)} == before
      assert File.read!(Path.join(ctx.evidence, "kept.json")) == "{}"
    end

    test "an existing empty 0755 directory is refused, never chmod-ed or replaced", ctx do
      File.mkdir!(ctx.evidence)
      File.chmod!(ctx.evidence, 0o755)
      before = {inode(ctx.evidence), mode(ctx.evidence)}
      defined!()

      assert prepare(ctx) == {:error, :evidence_dir_unsafe}
      assert {inode(ctx.evidence), mode(ctx.evidence)} == before
    end

    test "a symlink or a file at the name is refused and left untouched", ctx do
      target = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(target)
      File.chmod!(target, 0o700)
      File.ln_s!(target, ctx.evidence)
      defined!()

      assert prepare(ctx) == {:error, :evidence_dir_unsafe}
      assert File.read_link(ctx.evidence) == {:ok, target}

      File.rm!(ctx.evidence)
      File.write!(ctx.evidence, "not a directory")
      assert prepare(ctx) == {:error, :evidence_dir_unsafe}
      assert File.read!(ctx.evidence) == "not a directory"
    end

    for name <- [:missing, :symlink, :ancestor_symlink, :group_readable, :unwritable] do
      test "an unsafe root (#{name}) is refused and nothing is created", ctx do
        {root, cleanup} = unsafe_root(ctx, unquote(name))
        on_exit(cleanup)
        evidence = Path.join(root, "evidence")
        defined!()

        assert Calibrate.prepare(root: root, evidence_dir: evidence) ==
                 {:error, :calibration_root_unsafe}

        refute File.exists?(evidence), "something was created"
      end
    end

    test "a held launch record and its recovery ticket are unchanged", ctx do
      start_supervised!(StaleProbe)
      opts = [probe: StaleProbe]
      {:ok, claimed} = LaunchRecord.claim(ctx.root, opts)

      {:ok, _pending} =
        LaunchRecord.advance(
          ctx.root,
          claimed,
          :launch_pending,
          %{invocation_id: Ash.UUIDv7.generate()},
          opts
        )

      StaleProbe.owner_gone()
      {:ok, _recovery} = LaunchRecord.recover(ctx.root, opts)
      lock = Path.join(ctx.root, "run.lock")
      assert File.dir?(Path.join(lock, "recover")), "no recovery ticket was taken"
      before = {mode(lock), tree(lock)}
      defined!()

      assert prepare(ctx) == {:ok, :created}
      assert {mode(lock), tree(lock)} == before
    end

    # Codex setup@f408377: a path the kernel resolves through a symlink
    # must not be checked lexically and then written elsewhere. A
    # non-canonical path (`.` or `..`, or not its own expansion) is refused
    # before any filesystem access.
    test "a root reached through alias/.. is refused, and nothing is written anywhere", ctx do
      %{lexical: lexical, actual: actual, root: root} = alias_root!(ctx)
      defined!()

      assert Calibrate.prepare(root: root, evidence_dir: Path.join(root, "evidence")) ==
               {:error, :calibration_options_invalid}

      refute File.exists?(Path.join(actual, "evidence")), "written under the actual root"
      refute File.exists?(Path.join(lexical, "evidence")), "written under the lexical root"
    end

    test "an unsafe actual directory behind alias/.. is never reported as existing", ctx do
      %{lexical: lexical, actual: actual, root: root} = alias_root!(ctx)
      File.mkdir!(Path.join(lexical, "evidence"))
      File.chmod!(Path.join(lexical, "evidence"), 0o700)
      File.mkdir!(Path.join(actual, "evidence"))
      File.chmod!(Path.join(actual, "evidence"), 0o755)
      defined!()

      assert Calibrate.prepare(root: root, evidence_dir: Path.join(root, "evidence")) ==
               {:error, :calibration_options_invalid}

      assert mode(Path.join(actual, "evidence")) == 0o755
    end

    test "malformed input is refused before any filesystem access", ctx do
      defined!()

      for input <- [
            [],
            [root: ctx.root],
            [evidence_dir: ctx.evidence],
            [root: ctx.root, evidence_dir: ctx.evidence, extra: 1],
            [root: ctx.root, evidence_dir: ctx.evidence, root: ctx.root],
            [root: "relative", evidence_dir: "relative/evidence"],
            [root: ctx.root, evidence_dir: Path.join(ctx.root, "other")],
            %{root: ctx.root, evidence_dir: ctx.evidence},
            nil
          ] do
        assert Calibrate.prepare(input) == {:error, :calibration_options_invalid}, inspect(input)
        refute File.exists?(ctx.evidence)
      end
    end

    test "two concurrent calls: exactly one creates; the directory ends 0700 with one inode",
         ctx do
      defined!()

      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> prepare(ctx) end) end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &(&1 == {:ok, :created})) == 1, inspect(results)

      assert Enum.all?(
               results,
               &(&1 in [{:ok, :created}, {:ok, :existing}, {:error, :evidence_dir_unsafe}])
             ),
             inspect(results)

      assert mode(ctx.evidence) == 0o700
      assert prepare(ctx) == {:ok, :existing}
    end
  end

  describe "Evidence.check_dir/1" do
    test "a safe directory is :ok; a group-readable, missing or linked one is unsafe", ctx do
      File.mkdir!(ctx.evidence)
      File.chmod!(ctx.evidence, 0o700)
      assert function_exported?(Evidence, :check_dir, 1), "Evidence.check_dir/1 is not defined"
      assert Evidence.check_dir(ctx.evidence) == :ok

      File.chmod!(ctx.evidence, 0o750)
      assert Evidence.check_dir(ctx.evidence) == {:error, :evidence_dir_unsafe}
      assert mode(ctx.evidence) == 0o750

      assert Evidence.check_dir(Path.join(ctx.root, "missing")) == {:error, :evidence_dir_unsafe}

      link = Path.join(ctx.root, "linked")
      File.ln_s!(ctx.evidence, link)
      assert Evidence.check_dir(link) == {:error, :evidence_dir_unsafe}
    end

    # The check judges exactly the path it is given: a non-canonical one
    # is unsafe, never its lexical expansion.
    test "a non-canonical path is unsafe, even when its expansion is safe", ctx do
      %{lexical: lexical, root: root} = alias_root!(ctx)
      assert Evidence.check_dir(lexical) == :ok
      assert Evidence.check_dir(root) == {:error, :evidence_dir_unsafe}
      assert Evidence.check_dir(Path.join(lexical, ".")) == {:error, :evidence_dir_unsafe}
      assert Evidence.check_dir(lexical <> "/") == {:error, :evidence_dir_unsafe}
    end
  end

  ## Fixtures

  # After the fixtures: a missing entry point fails as an assertion.
  defp defined! do
    assert Code.ensure_loaded?(Calibrate)
    assert function_exported?(Calibrate, :prepare, 1), "Calibrate.prepare/1 is not defined"
  end

  defp prepare(ctx), do: Calibrate.prepare(root: ctx.root, evidence_dir: ctx.evidence)

  # An unsafe root and its cleanup: missing, a symlink, under a symlinked
  # ancestor, or a mode other than 0700 (group-readable, unwritable).
  defp unsafe_root(ctx, :missing), do: {Path.join(ctx.tmp, "absent"), fn -> :ok end}

  defp unsafe_root(ctx, :symlink) do
    link = Path.join(ctx.tmp, "root-link")
    File.ln_s!(ctx.root, link)
    {link, fn -> File.rm(link) end}
  end

  defp unsafe_root(ctx, :ancestor_symlink) do
    real = Path.join(ctx.tmp, "real-parent")
    File.mkdir_p!(Path.join(real, "calibration"))
    File.chmod!(Path.join(real, "calibration"), 0o700)
    link = Path.join(ctx.tmp, "parent-link")
    File.ln_s!(real, link)
    {Path.join(link, "calibration"), fn -> File.rm(link) end}
  end

  defp unsafe_root(ctx, :group_readable) do
    File.chmod!(ctx.root, 0o750)
    {ctx.root, fn -> File.chmod(ctx.root, 0o700) end}
  end

  defp unsafe_root(ctx, :unwritable) do
    File.chmod!(ctx.root, 0o500)
    {ctx.root, fn -> File.chmod(ctx.root, 0o700) end}
  end

  # Codex's reproduction: a safe lexical `calibration`, an unsafe (0755)
  # `other/calibration`, and `alias -> other/child`, so the kernel resolves
  # `alias/../calibration` to `other/calibration`.
  defp alias_root!(ctx) do
    other = Path.join(ctx.tmp, "other")
    actual = Path.join(other, "calibration")
    File.mkdir_p!(Path.join(other, "child"))
    File.mkdir_p!(actual)
    File.chmod!(actual, 0o755)
    File.ln_s!(Path.join(other, "child"), Path.join(ctx.tmp, "alias"))
    %{lexical: ctx.root, actual: actual, root: Path.join([ctx.tmp, "alias", "..", "calibration"])}
  end

  defp tree(path) do
    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn file ->
      {file, if(File.regular?(file), do: File.read!(file)), mode(file)}
    end)
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    mode &&& 0o777
  end

  defp inode(path) do
    {:ok, %File.Stat{inode: inode}} = File.lstat(path)
    inode
  end
end
