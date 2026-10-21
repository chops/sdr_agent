defmodule SdrAgent.Test.WitnessRoot do
  @moduledoc """
  Physical witness store roots for tests (S12d enablement). They live under
  the project's gitignored `tmp/witness-roots`, because the store root must
  have symlink-free ancestry, be owned by the effective UID and not be
  group- or world-writable. System temp paths fail that rule: macOS
  `/var -> /private/var` is a symlink and Linux `/tmp` is mode 1777. The
  rule is not relaxed for tests.

  Roots left by earlier test VMs stay in that persistent directory, so a
  name must be fresh across VMs, not only within one (#208): each root is
  `<prefix>-<suffix>` with a random 32-hex suffix, created with an atomic
  `mkdir`. A candidate that already exists is skipped, never adopted; after
  5 taken candidates the call refuses. Any other `mkdir` error propagates at
  once. The prefix is kept verbatim (some callers pass spaces or control
  characters on purpose, to test store-path refusal). Callers remove their
  own root (`on_exit`).
  """

  @attempts 5

  @doc """
  Creates a fresh root (mode 0700) and returns its absolute physical path.

  `suffixes:` replaces the random candidates (tests of the collision path):
  1 to #{@attempts} of them, each one non-empty filename component.
  """
  def mkdir!(prefix, opts \\ []) do
    base = Path.expand("tmp/witness-roots")
    File.mkdir_p!(base)
    Enum.each([Path.dirname(base), base], &File.chmod!(&1, 0o755))

    suffixes =
      Keyword.get_lazy(opts, :suffixes, fn -> Enum.map(1..@attempts, fn _ -> random() end) end)

    suffixes!(suffixes)
    allocate!(base, prefix, suffixes)
  end

  defp allocate!(_base, _prefix, []),
    do: raise("#208: no fresh witness root: every candidate already exists")

  defp allocate!(base, prefix, [suffix | rest]) do
    root = Path.join(base, "#{prefix}-#{suffix}")

    case File.mkdir(root) do
      :ok ->
        File.chmod!(root, 0o700)
        root

      {:error, :eexist} ->
        allocate!(base, prefix, rest)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory", path: root
    end
  end

  defp suffixes!(suffixes) when is_list(suffixes) and length(suffixes) in 1..@attempts,
    do: Enum.each(suffixes, &suffix!/1)

  defp suffixes!(_suffixes),
    do: raise(ArgumentError, "#208: suffixes: must be a list of 1 to #{@attempts} candidates")

  defp suffix!(s) when is_binary(s) and s not in ["", ".", ".."] do
    if String.contains?(s, ["/", <<0>>]),
      do: raise(ArgumentError, "#208: a suffix must be one filename component")
  end

  defp suffix!(_s), do: raise(ArgumentError, "#208: a suffix must be one filename component")

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
