defmodule SdrAgent.Prototype.OwnerAllowanceControlsTest do
  @moduledoc """
  Security and compatibility controls for D-269's receipt-bound allowance.
  These earn no RED credit: the behavior delta's RED is OwnerAllowanceTest.
  All file changes below target per-test, owned scratch directories only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.OwnerAllowanceFixtures, as: A
  alias SdrAgent.Prototype.Authority

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp check(root, worksheet) do
    bytes = Jason.encode!(worksheet)
    Authority.check_worksheet(bytes, sha(bytes), root)
  end

  test "only the exact integer100 and the exact closed allowance shape are valid" do
    root = PrototypeFixtures.scratch_dir!()
    base = A.worksheet(root)
    assert {:ok, %{remaining: 100}} = check(root, base)

    for total <- [nil, 0, 99, 101, 100.0, "100"] do
      assert check(root, %{base | "total" => total}) == {:error, :worksheet_invalid}
    end

    for key <- ["routes", "previous_bindings", "extra"] do
      assert check(root, Map.put(base, key, 0)) == {:error, :worksheet_invalid}
    end

    assert check(root, Map.delete(base, "receipt")) == {:error, :worksheet_invalid}
    assert check(root, put_in(base, ["receipt", "extra"], true)) == {:error, :worksheet_invalid}
    assert check(root, %{base | "receipt" => []}) == {:error, :worksheet_invalid}
  end

  test "the old shared60 historical worksheet cannot provision this additional allowance" do
    root = PrototypeFixtures.scratch_dir!()

    old = %{
      "schema" => "d237-budget-worksheet/1",
      "shared_total" => 60,
      "window_starts_at" => "2026-10-28T02:38:32.000000Z",
      "as_of" => "2026-10-30T17:00:00Z",
      "routes" => [],
      "previous_bindings" => %{"consumed" => 0, "evidence" => %{}}
    }

    assert check(root, old) == {:error, :worksheet_invalid}
  end

  test "the worksheet digest, duplicate keys, malformed JSON and byte bound fail closed" do
    root = PrototypeFixtures.scratch_dir!()
    bytes = root |> A.worksheet() |> Jason.encode!()

    assert Authority.check_worksheet(bytes, sha("different"), root) ==
             {:error, :worksheet_invalid}

    duplicate = String.replace(bytes, "\"total\":100", "\"total\":100,\"total\":100")
    refute duplicate == bytes

    for bad <- [duplicate, "{", "[]", String.duplicate(" ", 16_384) <> bytes] do
      assert Authority.check_worksheet(bad, sha(bad), root) == {:error, :worksheet_invalid}
    end
  end

  test "a caller-selected different receipt digest cannot create authority" do
    root = PrototypeFixtures.scratch_dir!()
    base = A.worksheet(root)

    for digest <- [sha("invented authority"), String.upcase(A.receipt_sha256()), nil, []] do
      assert check(root, put_in(base, ["receipt", "sha256"], digest)) ==
               {:error, :worksheet_invalid}
    end
  end

  test "missing, substituted, symlinked or non-private receipt files are unbounded" do
    for kind <- [:missing, :substituted, :symlink, :wide_mode] do
      root = PrototypeFixtures.scratch_dir!()
      base = A.worksheet(root)
      path = Path.join(root, base["receipt"]["path"])

      case kind do
        :missing ->
          File.rm!(path)

        :substituted ->
          File.write!(path, "not the owner authorization")

        :symlink ->
          target = Path.join(root, "target.receipt")
          File.rename!(path, target)
          File.ln_s!(target, path)

        :wide_mode ->
          File.chmod!(path, 0o644)
      end

      assert check(root, base) == {:error, :budget_unbounded}, inspect(kind)
    end
  end

  test "traversal and a non-private evidence root never resolve the receipt" do
    root = PrototypeFixtures.scratch_dir!()
    base = A.worksheet(root)

    for path <- ["../owner100.receipt", "/tmp/owner100.receipt"] do
      assert check(root, put_in(base, ["receipt", "path"], path)) ==
               {:error, :budget_unbounded}
    end

    File.chmod!(root, 0o755)
    assert check(root, base) == {:error, :budget_unbounded}
  end

  test "the same pinned authorization at a different safe path is still the same authority" do
    root = PrototypeFixtures.scratch_dir!()
    worksheet = A.worksheet(root, "another-owner100.receipt")
    assert {:ok, %{remaining: 100}} = check(root, worksheet)
  end
end
