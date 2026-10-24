defmodule SdrAgent.Test.PostgresLogContract do
  @moduledoc """
  The approved 5b PostgreSQL server-log baseline (#156 sections 3.2 and 3.3,
  D-178), pinned here independently of `priv/postgres/log_settings.json`, so a
  correctly typed but unapproved value in that file fails.

  Each entry is `{name, json_value, rendered_line, {setting, unit}}`:

    * `json_value`: the value in the canonical JSON file;
    * `rendered_line`: the `postgresql.conf` line both renderers emit
      (devenv's `toStr` spelling: `yes`/`no`, strings single-quoted with
      `'` doubled, numbers bare);
    * `{setting, unit}`: the effective `pg_settings` row on PostgreSQL 18.6,
      measured on a throwaway cluster on 2026-10-20 (booleans read `on`/`off`;
      `1d` is `1440` min; `50MB` is `51200` kB).

  The three preload settings are part of the contract as explicit empty
  strings. Also pinned: the benign extension and loaded-module identities the
  audit accepts (`plpgsql` 1.0 and `citext` 1.8, installed by migration
  `20261006212604`), and `dynamic_library_path = '$libdir'`, which restricts
  only the search for relative module names. It does not stop an absolute-path
  `LOAD` or a SUPERUSER session change: these settings and the audit are
  defaults and metadata observations, not isolation.

  Calibrated on PostgreSQL 18.6, 2026-10-20 (throwaway cluster):
  `pg_get_loaded_modules()` reports `file_name` as the basename only
  (`auto_explain.dylib` whether loaded by name or from a foreign absolute
  path), and `module_name` from the module's own magic block (`auto_explain`
  loaded from a file named `citext.dylib` reports `auto_explain`). So the audit
  requires `module_name` to equal the file's stem and the pinned version, but
  cannot prove a module's directory; a byte-identical copy of a benign module at
  a foreign path is indistinguishable through this interface.
  """

  @baseline [
    {"debug_print_parse", false, "debug_print_parse = no", {"off", ""}},
    {"debug_print_plan", false, "debug_print_plan = no", {"off", ""}},
    {"debug_print_rewritten", false, "debug_print_rewritten = no", {"off", ""}},
    {"local_preload_libraries", "", "local_preload_libraries = ''", {"", ""}},
    {"log_destination", "stderr", "log_destination = 'stderr'", {"stderr", ""}},
    {"log_directory", "log", "log_directory = 'log'", {"log", ""}},
    {"log_duration", false, "log_duration = no", {"off", ""}},
    {"log_error_verbosity", "terse", "log_error_verbosity = 'terse'", {"terse", ""}},
    {"log_file_mode", "0600", "log_file_mode = '0600'", {"0600", ""}},
    {"log_filename", "postgresql-%Y-%m-%d_%H%M%S.log",
     "log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'", {"postgresql-%Y-%m-%d_%H%M%S.log", ""}},
    {"log_min_duration_sample", -1, "log_min_duration_sample = -1", {"-1", "ms"}},
    {"log_min_duration_statement", -1, "log_min_duration_statement = -1", {"-1", "ms"}},
    {"log_min_error_statement", "panic", "log_min_error_statement = 'panic'", {"panic", ""}},
    {"log_parameter_max_length", 0, "log_parameter_max_length = 0", {"0", "B"}},
    {"log_parameter_max_length_on_error", 0, "log_parameter_max_length_on_error = 0", {"0", "B"}},
    {"log_rotation_age", "1d", "log_rotation_age = '1d'", {"1440", "min"}},
    {"log_rotation_size", "50MB", "log_rotation_size = '50MB'", {"51200", "kB"}},
    {"log_statement", "none", "log_statement = 'none'", {"none", ""}},
    {"log_timezone", "UTC", "log_timezone = 'UTC'", {"UTC", ""}},
    {"log_transaction_sample_rate", 0, "log_transaction_sample_rate = 0", {"0", ""}},
    {"log_truncate_on_rotation", false, "log_truncate_on_rotation = no", {"off", ""}},
    {"logging_collector", true, "logging_collector = yes", {"on", ""}},
    {"session_preload_libraries", "", "session_preload_libraries = ''", {"", ""}},
    {"shared_preload_libraries", "", "shared_preload_libraries = ''", {"", ""}}
  ]

  @benign_extensions %{"plpgsql" => "1.0", "citext" => "1.8"}
  @benign_modules %{"plpgsql" => "18.6", "citext" => "18.6"}

  @doc "The pinned baseline entries, sorted by name."
  def baseline, do: @baseline

  @doc "The exact set of setting names in the contract."
  def names, do: Enum.map(@baseline, &elem(&1, 0))

  @doc "The canonical JSON object the settings file must decode to."
  def json_map, do: Map.new(@baseline, fn {name, value, _, _} -> {name, value} end)

  @doc "The exact text both renderers emit for the contract keys (sorted, newline-terminated)."
  def rendered_text, do: Enum.map_join(@baseline, "", fn {_, _, line, _} -> line <> "\n" end)

  @doc "Expected `pg_settings` `{setting, unit}` per name."
  def effective, do: Map.new(@baseline, fn {name, _, _, eff} -> {name, eff} end)

  @doc "The JSON type each setting must have: `:boolean`, `:string`, `:integer` or `:number`."
  def json_type("log_transaction_sample_rate"), do: :number

  def json_type(name) do
    {^name, value, _, _} = List.keyfind(@baseline, name, 0)

    cond do
      is_boolean(value) -> :boolean
      is_binary(value) -> :string
      is_integer(value) -> :integer
    end
  end

  @doc "Benign extensions: name => pinned version."
  def benign_extensions, do: @benign_extensions

  @doc "Benign loaded modules: module name => pinned version (file `<name>.so` or `<name>.dylib`)."
  def benign_modules, do: @benign_modules
end
