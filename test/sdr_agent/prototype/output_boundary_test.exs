defmodule SdrAgent.Prototype.OutputBoundaryTest do
  @moduledoc "Synthetic boundary regressions for the accepted S4 output/file contracts."
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Prototype.Output

  @authority SdrAgent.Prototype.Authority

  defp bundle_context do
    ctx = prototype_drafted!()
    root = exclusive_root!("s4-output-boundary")
    dir = Path.join(root, "bundles")
    previous = Application.fetch_env(:sdr_agent, Output)
    Application.put_env(:sdr_agent, Output, bundle_dir: dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, Output, value)
        :error -> Application.delete_env(:sdr_agent, Output)
      end
    end)

    Map.merge(ctx, %{root: root, bundle_dir: dir})
  end

  test "unknown kind, malformed identity and absent rows return closed not-found errors" do
    ctx = prototype_drafted!()
    assert Output.view(:unknown, ctx.draft.id, ctx.operator) == {:error, :not_found}
    assert Output.view(:run, "not-an-id", ctx.operator) == {:error, :not_found}

    for kind <- Output.kinds() do
      assert Output.view(kind, Ecto.UUID.generate(), ctx.operator) == {:error, :not_found}
    end
  end

  test "a forged tenant on a real delegation cannot read any view" do
    ctx = prototype_drafted!()
    foreign = %{ctx.operator | tenant_id: Ecto.UUID.generate()}

    for kind <- Output.kinds() do
      assert Output.view(kind, ctx.draft.id, foreign) == {:error, :forbidden}
    end
  end

  test "a pending view refuses a draft that has already been approved" do
    ctx = prototype_drafted!()
    assert {:ok, _} = operator_approve(ctx, ctx.draft)
    assert Output.view(:pending_revision, ctx.draft.id, ctx.operator) == {:error, :forbidden}
  end

  test "tampering an approval digest refuses its view" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)

    tamper!("UPDATE approvals SET revision_content_sha256 = $1 WHERE id = $2", [
      :crypto.hash(:sha256, "different"),
      Ecto.UUID.dump!(approval.id)
    ])

    assert Output.view(:approval, approval.id, ctx.operator) == {:error, :digest_mismatch}
  end

  test "bundle identity is validated before creating a directory or file" do
    ctx = bundle_context()

    for id <- ["../escape", "not-a-uuid", nil] do
      assert {:error, _} = Output.write_bundle([{:run, ctx.run.id}], ctx.operator, id)
    end

    refute File.exists?(ctx.bundle_dir)
    assert File.ls!(ctx.root) == []
  end

  test "an invalid later item writes no partial bundle" do
    ctx = bundle_context()
    items = [{:pending_revision, ctx.draft.id}, {:run, Ecto.UUID.generate()}]
    assert Output.write_bundle(items, ctx.operator, Ecto.UUID.generate()) == {:error, :not_found}
    refute File.exists?(ctx.bundle_dir)
  end

  test "empty and malformed bundle lists refuse without writing" do
    ctx = bundle_context()

    for items <- [[], [:bad], [{:run, ctx.run.id} | :improper]] do
      assert {:error, _} = Output.write_bundle(items, ctx.operator, Ecto.UUID.generate())
    end

    refute File.exists?(ctx.bundle_dir)
  end

  test "bundle directory symlink is refused without touching its target" do
    ctx = bundle_context()
    target = Path.join(ctx.root, "elsewhere")
    File.mkdir!(target)
    File.chmod!(target, 0o700)
    File.ln_s!(target, ctx.bundle_dir)

    assert {:error, _} =
             Output.write_bundle([{:run, ctx.run.id}], ctx.operator, Ecto.UUID.generate())

    assert File.ls!(target) == []
  end

  test "a non-private existing bundle directory is refused, not adopted or chmodded" do
    ctx = bundle_context()
    File.mkdir!(ctx.bundle_dir)
    File.chmod!(ctx.bundle_dir, 0o755)

    assert {:error, _} =
             Output.write_bundle([{:run, ctx.run.id}], ctx.operator, Ecto.UUID.generate())

    assert File.ls!(ctx.bundle_dir) == []
    assert Bitwise.band(File.stat!(ctx.bundle_dir).mode, 0o777) == 0o755
  end

  test "a bundle destination symlink is refused and its target is never overwritten" do
    ctx = bundle_context()
    File.mkdir!(ctx.bundle_dir)
    File.chmod!(ctx.bundle_dir, 0o700)
    target = Path.join(ctx.root, "sentinel")
    File.write!(target, "unchanged")
    id = Ecto.UUID.generate()
    File.ln_s!(target, Path.join(ctx.bundle_dir, id <> ".json"))

    assert {:error, _} = Output.write_bundle([{:run, ctx.run.id}], ctx.operator, id)
    assert File.read!(target) == "unchanged"
  end

  test "credential generation is unpadded base64url, independent for each exclusive file" do
    root = PrototypeFixtures.scratch_dir!()
    assert {:ok, first} = call(@authority, :write_credential, [Path.join(root, "first")])
    assert {:ok, second} = call(@authority, :write_credential, [Path.join(root, "second")])
    assert first =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert second =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    refute first == second
  end

  test "a credential symlink refuses, preserving its target" do
    root = PrototypeFixtures.scratch_dir!()
    target = Path.join(root, "target")
    path = Path.join(root, "credential")
    File.write!(target, "unchanged")
    File.ln_s!(target, path)
    assert call(@authority, :write_credential, [path]) == {:error, :credential_path_exists}
    assert File.read!(target) == "unchanged"
  end

  test "a credential with a missing parent fails with a fixed value-free error" do
    root = PrototypeFixtures.scratch_dir!()
    path = Path.join([root, "absent", "credential"])
    assert call(@authority, :write_credential, [path]) == {:error, :credential_write_failed}
    assert File.ls!(root) == []
  end
end
