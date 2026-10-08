defmodule SdrAgent.ChildEnv do
  @moduledoc """
  Explicit environment allowlist for every external process the application
  launches (security fix: secrets must not reach child processes).

  `System.cmd/3` and `Port.open/2` children inherit the whole BEAM
  environment unless told otherwise. When the server runs under
  `bin/with-secrets SDR_AUDIT_ANCHOR_PRIVATE_KEY -- bin/demo run`, that
  environment holds the audit-anchor signing key. So every launcher builds
  its child environment here:

    * every name of the current environment is **removed**, except the
      base allowlist (`PATH HOME USER LOGNAME LANG TMPDIR TZ` and `LC_*`) and
      the names the launcher adds for its tool;
    * a secret-looking name — `SDR_AUDIT_ANCHOR_PRIVATE_KEY`, or one ending
      in `_KEY`, `_TOKEN`, `_SECRET`, `_PASSWORD` or `_CREDENTIALS` — is
      removed even when allowlisted;
    * `set` pairs are applied last (they are the launcher's own values,
      e.g. the per-call wire-witness ids, and never come from the parent).

  `cmd/2` returns the `:env` value for `System.cmd/3` (`{name, nil}`
  removes); `port/2` the `{:env, ...}` value for `Port.open/2` (charlists,
  `false` removes). An allowlist entry ending in `*` is a prefix.
  """

  @base ~w(PATH HOME USER LOGNAME LANG TMPDIR TZ LC_*)
  @secret ~r/(\A|_)(KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS)\z/i

  @doc "`System.cmd/3` `:env`: removes all but `allow` (plus the base), then applies `set`."
  @spec cmd([String.t()], [{String.t(), String.t()}]) :: [{String.t(), String.t() | nil}]
  def cmd(allow, set \\ []) do
    set_names = MapSet.new(set, &elem(&1, 0))

    removals =
      for {name, _value} <- System.get_env(),
          not MapSet.member?(set_names, name),
          not kept?(name, allow),
          do: {name, nil}

    removals ++ set
  end

  @doc "`Port.open/2` `{:env, ...}`: as `cmd/2`, as charlists with `false` for removal."
  @spec port([String.t()], [{String.t(), String.t()}]) :: [{charlist(), charlist() | false}]
  def port(allow, set \\ []) do
    for {name, value} <- cmd(allow, set) do
      {String.to_charlist(name), if(is_nil(value), do: false, else: String.to_charlist(value))}
    end
  end

  @doc "Whether `name` passes to a child with `allow` (never a secret-looking name)."
  @spec kept?(String.t(), [String.t()]) :: boolean()
  def kept?(name, allow) do
    not Regex.match?(@secret, name) and Enum.any?(@base ++ allow, &matches?(name, &1))
  end

  defp matches?(name, pattern) do
    case String.split_at(pattern, -1) do
      {prefix, "*"} -> String.starts_with?(name, prefix)
      _exact -> name == pattern
    end
  end
end
