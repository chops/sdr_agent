# ADR-0016 throwaway-cluster guard. Sourced by adversarial.sh and
# throwaway-cluster.sh; never executed directly. Bash only.
#
# The harness installs, uninstalls, seeds and truncates. It must only ever
# reach a cluster that throwaway-cluster.sh created. Everything below runs
# BEFORE any database connection, and every refusal happens before the first
# psql call:
#
#   1. libpq environment overrides (every PG* variable, PSQLRC) are unset;
#      later connections pass every parameter explicitly.
#   2. The port is canonical decimal (no sign, no leading zero, no
#      whitespace), in the dynamic range 49152-65535, and never 5520 (the
#      dev cluster) or 4120 (the app) in any spelling.
#   3. The cluster root is a private temporary directory that
#      throwaway-cluster.sh created: an absolute PHYSICAL path (no symlink
#      component, no . or .. segment) under /private/tmp/ or
#      /private/var/folders/, owned by this user, mode 700, holding the
#      creation marker.
#   4. PGDATA is exactly <root>/pgdata, physically, and not a symlink.
#   5. The manifest written at initdb time (root, pgdata, port, system
#      identifier) is a regular file in the root, owned by this user, mode
#      600, and agrees with the inputs.
#   6. pg_controldata of that PGDATA reports the manifest's system
#      identifier; postmaster.pid names that PGDATA, port and 127.0.0.1,
#      and its PID is alive and is the only TCP listener on the port.
#
# Only then does guard_connect_identity make one read-only connection and
# compare system_identifier, data_directory and port with the manifest.

GUARD_TEMP_PREFIXES='/private/tmp/ /private/var/folders/'
GUARD_MARKER='.d168-throwaway-root'
GUARD_FORBIDDEN_PORTS='5520 4120'

guard_refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 2; }

# Unset every libpq/psql environment override, whatever its value, then
# refuse if any survived. (No compgen: Nix's non-interactive bash lacks it.)
guard_scrub_env() {
  local v
  for v in $(env | sed -n 's/^\(PG[A-Za-z0-9_]*\)=.*/\1/p; s/^\(PSQL[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done
  if env | grep -qE '^(PG|PSQL)[A-Za-z0-9_]*='; then guard_refuse "a PG*/PSQL* environment variable could not be unset"; fi
}

# guard_port VALUE -> prints the canonical port or refuses.
guard_port() {
  local p=$1 f
  [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] || guard_refuse "port '$p' is not canonical decimal (sign, leading zero, space or non-digit)"
  for f in $GUARD_FORBIDDEN_PORTS; do
    [ "$((10#$p))" -eq "$f" ] && guard_refuse "port $p is a protected endpoint"
  done
  { [ "$((10#$p))" -ge 49152 ] && [ "$((10#$p))" -le 65535 ]; } || guard_refuse "port $p is outside 49152-65535"
  printf '%s\n' "$((10#$p))"
}

# guard_physical_dir PATH -> refuses unless PATH is an existing directory
# whose physical path equals its lexical spelling.
guard_physical_dir() {
  local d=$1 phys
  case "$d" in /*) ;; *) guard_refuse "'$d' is not an absolute path" ;; esac
  case "$d/" in */./*|*/../*|*//*) guard_refuse "'$d' has a ., .. or empty segment" ;; esac
  [ -d "$d" ] || guard_refuse "'$d' is not a directory"
  phys=$(cd -P -- "$d" 2>/dev/null && pwd -P) || guard_refuse "'$d' cannot be resolved"
  [ "$phys" = "$d" ] || guard_refuse "'$d' is not physical (resolves to '$phys')"
}

# "uid mode" of a path (BSD stat on macOS; a Nix shell may put GNU stat first).
guard_stat() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%u %Lp' "$1" 2>/dev/null ;;
    *) stat -c '%u %a' "$1" 2>/dev/null ;;
  esac
}

# guard_root ROOT: a private temporary root created by throwaway-cluster.sh.
guard_root() {
  local r=$1 ok=no pre st
  guard_physical_dir "$r"
  for pre in $GUARD_TEMP_PREFIXES; do case "$r" in "$pre"?*/?*) ok=yes ;; esac; done
  [ "$ok" = yes ] || guard_refuse "root '$r' is not under a private temporary prefix ($GUARD_TEMP_PREFIXES)"
  st=$(guard_stat "$r")
  [ "$st" = "$(id -u) 700" ] || guard_refuse "root '$r' is not owned by uid $(id -u) with mode 700 (got '$st')"
  [ -f "$r/$GUARD_MARKER" ] && [ ! -L "$r/$GUARD_MARKER" ] || guard_refuse "root '$r' has no creation marker"
  [ "$(/bin/cat "$r/$GUARD_MARKER")" = "$r" ] || guard_refuse "root '$r' marker names another path"
}

# guard_manifest_get FILE KEY -> the single value of KEY.
guard_manifest_get() {
  local n v
  n=$(grep -c "^$2=" "$1")
  [ "$n" = 1 ] || guard_refuse "manifest key '$2' appears $n times"
  v=$(grep "^$2=" "$1"); printf '%s\n' "${v#*=}"
}

# guard_verify: validates ADV_MANIFEST, ADV_PORT and ADV_PGDATA without any
# database connection and exports GUARD_ROOT, GUARD_PGDATA, GUARD_PORT,
# GUARD_SYSID. Needs GUARD_CONTROLDATA (pg_controldata path).
guard_verify() {
  local m=${ADV_MANIFEST:-} root st port mport mdata sysid csys pidf pid lpids line
  guard_scrub_env
  [ -n "$m" ] || guard_refuse "ADV_MANIFEST is not set"
  [ -n "${ADV_PORT:-}" ] || guard_refuse "ADV_PORT is not set"
  [ -n "${ADV_PGDATA:-}" ] || guard_refuse "ADV_PGDATA is not set"
  port=$(guard_port "$ADV_PORT") || exit 2

  root=$(dirname -- "$m")
  guard_root "$root"
  [ "$m" = "$root/manifest" ] || guard_refuse "manifest must be <root>/manifest"
  [ -f "$m" ] && [ ! -L "$m" ] || guard_refuse "manifest '$m' is not a regular file"
  st=$(guard_stat "$m")
  [ "$st" = "$(id -u) 600" ] || guard_refuse "manifest is not owned by uid $(id -u) with mode 600 (got '$st')"
  [ "$(guard_manifest_get "$m" d168_throwaway_manifest)" = 1 ] || guard_refuse "not a d168 throwaway manifest"
  [ "$(guard_manifest_get "$m" root)" = "$root" ] || guard_refuse "manifest root disagrees with its location"

  mport=$(guard_manifest_get "$m" port)
  [ "$(guard_port "$mport")" = "$mport" ] || exit 2
  [ "$mport" = "$port" ] || guard_refuse "ADV_PORT $port is not the manifest port"

  mdata=$(guard_manifest_get "$m" pgdata)
  [ "$mdata" = "$root/pgdata" ] || guard_refuse "manifest pgdata is not <root>/pgdata"
  [ "$ADV_PGDATA" = "$mdata" ] || guard_refuse "ADV_PGDATA '$ADV_PGDATA' is not the manifest pgdata (spell it physically)"
  [ ! -L "$mdata" ] || guard_refuse "pgdata is a symlink"
  guard_physical_dir "$mdata"

  sysid=$(guard_manifest_get "$m" system_identifier)
  [[ "$sysid" =~ ^[1-9][0-9]{5,19}$ ]] || guard_refuse "manifest system identifier is malformed"
  csys=$("$GUARD_CONTROLDATA" "$mdata" 2>/dev/null | awk -F: '/^Database system identifier/ {gsub(/ /, "", $2); print $2}')
  [ "$csys" = "$sysid" ] || guard_refuse "pg_controldata identifier '$csys' is not the manifest's"

  pidf="$mdata/postmaster.pid"
  [ -f "$pidf" ] && [ ! -L "$pidf" ] || guard_refuse "no postmaster.pid: the throwaway cluster is not running"
  pid=$(sed -n 1p "$pidf")
  [ "$(sed -n 2p "$pidf")" = "$mdata" ] || guard_refuse "postmaster.pid names another data directory"
  [ "$(sed -n 4p "$pidf")" = "$port" ] || guard_refuse "postmaster.pid port is not $port"
  [ "$(sed -n 6p "$pidf")" = 127.0.0.1 ] || guard_refuse "postmaster.pid listen address is not 127.0.0.1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || guard_refuse "postmaster PID '$pid' is not alive"
  lpids=$("${GUARD_LSOF:-lsof}" -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u | tr '\n' ' ')
  [ "$lpids" = "$pid " ] || guard_refuse "TCP listeners on $port are '$lpids', not only postmaster $pid"

  GUARD_ROOT=$root GUARD_PGDATA=$mdata GUARD_PORT=$port GUARD_SYSID=$sysid
  export GUARD_ROOT GUARD_PGDATA GUARD_PORT GUARD_SYSID
}

# guard_conninfo DB USER -> an explicit libpq connection string.
guard_conninfo() {
  printf 'host=127.0.0.1 hostaddr=127.0.0.1 port=%s dbname=%s user=%s sslmode=disable connect_timeout=10 application_name=d168-throwaway\n' \
    "$GUARD_PORT" "$1" "$2"
}

# guard_connect_identity PSQL: the first connection. Refuses unless the
# server reports the manifest's identifier, data directory and port.
guard_connect_identity() {
  local out want
  out=$("$1" -X -q -At -F'|' -d "$(guard_conninfo postgres postgres)" \
    -c "SELECT system_identifier, current_setting('data_directory'), current_setting('port'), inet_server_port() FROM pg_catalog.pg_control_system()" 2>/dev/null)
  want="$GUARD_SYSID|$GUARD_PGDATA|$GUARD_PORT|$GUARD_PORT"
  [ "$out" = "$want" ] || guard_refuse "server identity '$out' is not the manifest's '$want'"
}
