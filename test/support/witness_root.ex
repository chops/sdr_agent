defmodule SdrAgent.Test.WitnessRoot do
  @moduledoc """
  Physical witness store roots for tests (S12d enablement). They live under
  the project's gitignored `tmp/witness-roots`, because the store root must
  have symlink-free ancestry, be owned by the effective UID and not be
  group- or world-writable. System temp paths fail that rule: macOS
  `/var -> /private/var` is a symlink and Linux `/tmp` is mode 1777. The
  rule is not relaxed for tests.
  """

  @doc "Creates a fresh root (mode 0700) and returns its absolute physical path."
  def mkdir!(prefix) do
    base = Path.expand("tmp/witness-roots")
    File.mkdir_p!(base)
    Enum.each([Path.dirname(base), base], &File.chmod!(&1, 0o755))
    root = Path.join(base, "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end
end
