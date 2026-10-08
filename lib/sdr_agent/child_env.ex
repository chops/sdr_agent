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
      base allowlist (`PATH HOME USER LOGNAME LANG TMPDIR TZ` and the exact
      `LC_*` locale names) and the exact names the launcher adds for its
      tool (`xdg/0` gives the XDG base directories; there are no namespace
      wildcards);
    * the application's own secrets (`SDR_AUDIT_ANCHOR_PRIVATE_KEY`,
      `SDR_WEBHOOK_HMAC_KEY`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`,
      `DATABASE_URL`) are removed unconditionally, even when absent from the
      snapshot, and any secret-looking name (ending in `_KEY`, `_TOKEN`,
      `_SECRET`, `_PASSWORD` or `_CREDENTIALS`) is removed even when
      allowlisted;
    * `set` pairs are applied last (the launcher's own values, e.g. the
      per-call wire-witness ids); a `set` entry cannot give a secret or
      secret-looking name a value — it becomes a removal.

  `cmd/2` returns the `:env` value for `System.cmd/3` (`{name, nil}`
  removes); `port/2` the `{:env, ...}` value for `Port.open/2` (charlists,
  `false` removes). `system_cmd/3` is the default runner for launchers with
  an injectable command and refuses to start a child without `:env`.

  Scope: this builds overrides against a snapshot of the current names;
  the OS still inherits any name added between building the options and
  the spawn. The application adds no environment variable at runtime, and
  its own secrets are removed regardless; a future runtime environment
  writer must not introduce credentials. `test/sdr_agent/child_env_inventory_test.exs`
  fails for any launch in `lib/` not wired through this module.
  """

  @base ~w(PATH HOME USER LOGNAME LANG TMPDIR TZ LC_ALL LC_CTYPE LC_MESSAGES
            LC_COLLATE LC_NUMERIC LC_TIME LC_MONETARY)
  @xdg ~w(XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR)
  # The application's own secrets: removed in every child even when absent
  # from the snapshot the removal list is built from.
  @always_removed ~w(SDR_AUDIT_ANCHOR_PRIVATE_KEY SDR_WEBHOOK_HMAC_KEY SECRET_KEY_BASE
                     TOKEN_SIGNING_SECRET DATABASE_URL)
  @secret ~r/(\A|_)(KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS)\z/i

  @doc "The exact XDG base-directory names a launcher may allow (never the whole namespace)."
  def xdg, do: @xdg

  @doc """
  `System.cmd/3` `:env`: removes every name of the current environment but
  `allow` (plus the base) and the application's known secrets always, then
  applies `set`. A `set` entry may not give a secret-looking or known-secret
  name a value: such an entry becomes a removal.
  """
  @spec cmd([String.t()], [{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def cmd(allow, set \\ []) do
    overlay =
      Map.new(set, fn {name, value} -> {name, if(secret?(name), do: nil, else: value)} end)

    removals =
      for name <- Enum.uniq(Map.keys(System.get_env()) ++ @always_removed),
          not Map.has_key?(overlay, name),
          not kept?(name, allow),
          do: {name, nil}

    removals ++ Enum.to_list(overlay)
  end

  @doc "`Port.open/2` `{:env, ...}`: as `cmd/2`, as charlists with `false` for removal."
  @spec port([String.t()], [{String.t(), String.t() | nil}]) :: [{charlist(), charlist() | false}]
  def port(allow, set \\ []) do
    for {name, value} <- cmd(allow, set) do
      {String.to_charlist(name), if(is_nil(value), do: false, else: String.to_charlist(value))}
    end
  end

  @doc """
  The default runner for launchers that take an injectable command
  (`System.cmd/3` with a mandatory `:env` built by this module): refuses to
  start a child without an explicit environment.
  """
  def system_cmd(command, args, opts) do
    unless Keyword.has_key?(opts, :env),
      do:
        raise(ArgumentError, "ChildEnv.system_cmd/3 requires an :env built by SdrAgent.ChildEnv")

    System.cmd(command, args, opts)
  end

  @doc "Whether `name` passes to a child with `allow` (never a secret or secret-looking name)."
  @spec kept?(String.t(), [String.t()]) :: boolean()
  def kept?(name, allow), do: not secret?(name) and name in (@base ++ allow)

  defp secret?(name), do: name in @always_removed or Regex.match?(@secret, name)
end
