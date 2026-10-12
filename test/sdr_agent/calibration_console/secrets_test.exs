defmodule SdrAgent.CalibrationConsole.SecretsTest do
  @moduledoc """
  The calibration console's per-machine secrets (R0-07 slice D review): the
  endpoint `secret_key_base` and the token signing secret it serves with
  are never the checked-in test values. They are generated once, strong and
  random, into a 0600 file in a 0700 directory owned by this user, reused on
  every later start (sessions survive a restart), and refused when the file
  or directory is a symlink, not owned by this user, or readable by group or
  world. Every test uses its own temporary directory.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.CalibrationConsole.Secrets

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "calibration-secrets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {physical, 0} = System.cmd("pwd", ["-P"], cd: tmp)
    tmp = String.trim(physical)
    dir = Path.join([tmp, "state", "sdr-agent", "calibration"])
    %{tmp: tmp, dir: dir, path: Path.join(dir, "secrets")}
  end

  defp mode(path), do: File.lstat!(path).mode &&& 0o777

  defp refused!(ctx, uid \\ nil) do
    assert {:error, reason} = Secrets.load_or_create(ctx.path, uid)
    refute reason =~ ctx.secrets.secret_key_base
    refute reason =~ ctx.secrets.token_signing_secret
    reason
  end

  test "the default path is ~/.local/state/sdr-agent/calibration/secrets" do
    assert Secrets.default_path() ==
             Path.join(System.user_home!(), ".local/state/sdr-agent/calibration/secrets")
  end

  describe "first use" do
    test "creates the file 0600 in a 0700 directory", ctx do
      assert {:ok, _secrets} = Secrets.load_or_create(ctx.path)
      assert File.dir?(ctx.dir)
      assert mode(ctx.dir) == 0o700
      assert File.regular?(ctx.path)
      assert mode(ctx.path) == 0o600
      assert File.ls!(ctx.dir) == ["secrets"]
    end

    test "generates strong values that are not the checked-in test secrets", ctx do
      assert {:ok, secrets} = Secrets.load_or_create(ctx.path)

      for key <- [:secret_key_base, :token_signing_secret] do
        value = Map.fetch!(secrets, key)
        assert {:ok, raw} = Base.decode64(value)
        assert byte_size(raw) >= 64
      end

      refute secrets.secret_key_base == secrets.token_signing_secret

      checked_in = [
        Application.fetch_env!(:sdr_agent, :token_signing_secret),
        Application.fetch_env!(:sdr_agent, SdrAgentWeb.Endpoint)[:secret_key_base]
      ]

      refute secrets.secret_key_base in checked_in
      refute secrets.token_signing_secret in checked_in
    end

    test "simultaneous first uses agree on one set of values", ctx do
      results =
        1..6
        |> Enum.map(fn _ -> Task.async(fn -> Secrets.load_or_create(ctx.path) end) end)
        |> Task.await_many(30_000)

      assert [{:ok, _}] = Enum.uniq(results)
      assert File.ls!(ctx.dir) == ["secrets"]
    end
  end

  test "a later use reuses the same values and leaves the file unchanged", ctx do
    assert {:ok, first} = Secrets.load_or_create(ctx.path)
    before = File.read!(ctx.path)
    assert {:ok, ^first} = Secrets.load_or_create(ctx.path)
    assert File.read!(ctx.path) == before
    assert mode(ctx.path) == 0o600
  end

  describe "refuses, without revealing a value," do
    setup ctx do
      {:ok, secrets} = Secrets.load_or_create(ctx.path)
      %{secrets: secrets}
    end

    for file_mode <- [0o640, 0o644, 0o604, 0o660, 0o666] do
      test "a secrets file with mode #{Integer.to_string(file_mode, 8)}", ctx do
        File.chmod!(ctx.path, unquote(file_mode))
        assert refused!(ctx) =~ "readable or writable by group or others"
      end
    end

    for dir_mode <- [0o750, 0o755, 0o705, 0o770] do
      test "a secrets directory with mode #{Integer.to_string(dir_mode, 8)}", ctx do
        File.chmod!(ctx.dir, unquote(dir_mode))
        assert refused!(ctx) =~ "readable or writable by group or others"
      end
    end

    test "a file and directory owned by another user", ctx do
      assert refused!(ctx, Store.effective_uid() + 1) =~ "not owned by this user"
    end

    test "a symlinked secrets file", ctx do
      real = Path.join(ctx.tmp, "elsewhere")
      File.rename!(ctx.path, real)
      File.ln_s!(real, ctx.path)
      assert refused!(ctx) =~ "is not a regular file"
    end

    test "a symlinked secrets directory", ctx do
      real = Path.join(ctx.tmp, "elsewhere-dir")
      File.rename!(ctx.dir, real)
      File.ln_s!(real, ctx.dir)
      assert refused!(ctx) =~ "is not a directory"
    end

    test "a malformed secrets file", ctx do
      File.write!(ctx.path, "secret_key_base=short\n")
      assert refused!(ctx) =~ "is malformed"
    end

    test "a duplicated key or an unknown line", ctx do
      good = File.read!(ctx.path)
      [first | _] = String.split(good, "\n", trim: true)

      for body <- [good <> first <> "\n", good <> "junk\n", good <> "other_key=x\n"] do
        File.write!(ctx.path, body)
        assert refused!(ctx) =~ "is malformed"
      end
    end
  end
end
