# 5b (D-178): the program behind render-pg-log-settings.sh, run with `jq -n`.
# Input: a file holding exactly one JSON document, the settings object (jq
# reads a stream, so a second document is refused, Codex 5b G1). Output: one
# string of postgresql.conf lines (sorted, each newline-terminated), or an
# error (no output) for anything outside the contract's exact key set and
# JSON types.
def types: {
  "debug_print_parse": "boolean", "debug_print_plan": "boolean",
  "debug_print_rewritten": "boolean", "local_preload_libraries": "string",
  "log_destination": "string", "log_directory": "string",
  "log_duration": "boolean", "log_error_verbosity": "string",
  "log_file_mode": "string", "log_filename": "string",
  "log_min_duration_sample": "integer", "log_min_duration_statement": "integer",
  "log_min_error_statement": "string", "log_parameter_max_length": "integer",
  "log_parameter_max_length_on_error": "integer", "log_rotation_age": "string",
  "log_rotation_size": "string", "log_statement": "string",
  "log_timezone": "string", "log_transaction_sample_rate": "number",
  "log_truncate_on_rotation": "boolean", "logging_collector": "boolean",
  "session_preload_libraries": "string", "shared_preload_libraries": "string"
};

# A string may not hold a control character (U+0000..U+001F, U+007F) or a
# backslash: those would be configuration syntax, not a value.
def plain: explode | all(. >= 32 and . != 127 and . != 92);

def typed($t):
  if $t == "integer" then type == "number" and (tojson | test("^-?[0-9]+$"))
  elif $t == "number" then type == "number"
  elif $t == "string" then type == "string" and plain
  else type == $t end;

def quote: "'" + gsub("'"; "''") + "'";

def render:
  if type == "boolean" then (if . then "yes" else "no" end)
  elif type == "number" then tojson
  else quote end;

[inputs] as $docs
| if ($docs | length) != 1 then error("not exactly one JSON document") else $docs[0] end
| if type != "object" then error("not an object")
elif (keys | sort) != (types | keys | sort) then error("keys outside the contract")
else
  to_entries
  | map(types[.key] as $t | if (.value | typed($t)) then . else error("wrong type") end)
  | sort_by(.key)
  | map(.key + " = " + (.value | render) + "\n")
  | join("")
end
