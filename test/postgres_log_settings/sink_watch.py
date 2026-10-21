#!/usr/bin/env python3
"""5b sink test: process watcher and file-evidence tools (macOS).

Plan: claude-5b-sink-plan r2 as amended by r3, r4, r5, r6 and R6-1
(handoff tmp). Run with the locked-nixpkgs python3 (`-I`), never as a
library of the application. Every subcommand fails closed: an observation
that cannot be made is uncertainty (exit 3, "HOLD"), never absence.

Exit codes: 0 ok; 2 refusal (a precondition is not met, nothing started);
3 HOLD (uncertainty; nothing more is signalled or deleted); 4 FAIL (a
definite negative result); 64 usage.

This file starts processes ONLY in `supervise` (the reviewed launcher) and
in `selftest-*` subcommands (registered synthetic fixtures). It never
connects to a database and never reads a file outside the manifest's
owned roots, except the store paths it validates.
"""

import ctypes
import ctypes.util
import errno
import hashlib
import json
import os
import re
import secrets
import select
import signal
import socket
import stat
import subprocess
import sys
import time

EXIT_OK, EXIT_REFUSE, EXIT_HOLD, EXIT_FAIL, EXIT_USAGE = 0, 2, 3, 4, 64

# ---------------------------------------------------------------- constants
# Locked package paths (plan r2 2.2); every instance must reference exactly these.
PKG = {
    "postgresql": "/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6",
    "process-compose": "/nix/store/lm69y4badkbglz1brkq9ayx0494hhz4i-process-compose-1.120.0",
    "devenv-tasks": "/nix/store/hzxxyiv8y0nlbrksjiqxck3ksh0m9x34-rust_devenv-tasks-2.2.1",
    "socat": "/nix/store/j1ly4dmdyi9mis8s6lkaf5j3p2rfxn4d-socat-1.8.1.3",
    "coreutils": "/nix/store/q5fm76ljl27nai13va4ya1y8n9sf3n87-coreutils-9.11",
    "bash": "/nix/store/yqk6qhawnigv832m2zhcbs25nb37r73i-bash-5.3p15",
    "bash-interactive": "/nix/store/401wfz3g4kmjhi96qq29qbqz4143bwdq-bash-interactive-5.3p15",
    "gnugrep": "/nix/store/ldbcfcxcigbl5ddxb7bk3nlxb600f9yv-gnugrep-3.12",
}
PG_BIN = PKG["postgresql"] + "/bin"
PC_BIN = PKG["process-compose"] + "/bin/process-compose"
DT_BIN = PKG["devenv-tasks"] + "/bin/devenv-tasks"
# Executable images allowed in the owned tree (r6 1.2 fact 3).
EXEC_ALLOW_PREFIXES = tuple(PKG[k] + "/bin/" for k in PKG)

FORBIDDEN_PORTS = {5520, 4120}
PORT_RANGE = (20000, 29999)

# kqueue EVFILT_PROC flags (MacOSX26.2.sdk sys/event.h; r4 3.1). Python has no
# KQ_NOTE_EXITSTATUS, so the SDK literal is used.
NOTE_EXIT = 0x80000000
NOTE_FORK = 0x40000000
NOTE_EXEC = 0x20000000
NOTE_EXITSTATUS = 0x04000000
NOTE_PDATAMASK = 0x000FFFFF
PROC_FFLAGS = NOTE_EXIT | NOTE_EXITSTATUS | NOTE_FORK | NOTE_EXEC

# libproc
PROC_PIDTBSDINFO = 3
PROC_PPID_ONLY = 6
PROC_PIDPATHINFO_MAXSIZE = 4096

# Launch envelope keys (r2 4.3 with r3 1.2 PGHOST deviation; r4/r5 assertions).
ENV_KEYS = (
    "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "TZ",
    "PGDATA", "PGHOST", "PGPORT", "PC_SOCKET_PATH", "PC_TUI_ENABLED",
)
ENV_MUST_BE_ABSENT = (
    "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
    "XDG_DATA_HOME", "DEVENV_CONTAINER", "SQLITE_TMPDIR", "PC_LOG_FILE",
    "PC_API_TOKEN_PATH", "PROC_COMP_CONFIG", "PC_CONFIG_FILES", "PGUSER",
    "PGDATABASE", "PGPASSWORD", "PGSERVICE", "PGSERVICEFILE", "PGSYSCONFDIR",
    "PGPASSFILE", "DATABASE_URL", "DEVENV_CMDLINE", "DEVENV_TASKS_QUIET",
)

# Per-instance copy edits (r2 6.3; r3 3.4). Keys: JSON-copy deltas.
EDITS = {
    "B": {},
    "D": {},
    "R": None,  # reference build: no edits at all, port 5520, never started
    "P": {
        "log_error_verbosity": "default",
        "log_min_error_statement": "error",
        "log_parameter_max_length": -1,
        "log_parameter_max_length_on_error": -1,
        "log_min_duration_statement": 100,
    },
    "A": {"shared_preload_libraries": "auto_explain"},
    # self-test copies (r2 T6, r3 7.1 T7)
    "S": {},
    "S-T6": {"log_rotation_size": "50XB"},
    "S-T7": {"hot_standby": False},
}

DB_ALLOW = {
    "B": ["postgres", "b_canary_r1", "b_canary_r2", "b_audit", "b_canary_s5"],
    "P": ["postgres", "p_canary_r1", "p_canary_r2", "p_audit", "p_load"],
    "A": ["postgres", "a_ext", "a_plain"],
    "D": ["postgres"],
    "S": ["postgres", "s_probe", "s_canary_s5"],
}

# Marker channels (r2 7.2, C1-C8).
MARKER_KINDS = ("S_u", "M_u", "S_c", "M_c", "L", "E", "Q", "T", "D", "F")
PRIMARY_KINDS = ("E", "F")

TIMEOUTS = {
    "ready": 120, "ready_T7": 60, "stop_launcher": 30, "stop_pc": 20,
    "stop_dt": 20, "kill_wait": 10, "barrier": 90, "drain": 15, "s5": 300,
}

# Backend process title: "postgres: <user> <db> [local] ..." or an address.
BACKEND_RE = re.compile(r"postgres: \S+ \S+ (\[local\]|\d+\.\d+\.\d+\.\d+)")
# /bin/sh and its macOS target, used by pg_ctl and initdb (deviation D-1).
SYSTEM_SH = {"/bin/sh", os.path.realpath("/private/var/select/sh")}

# Collector file name pattern (contract log_filename).
COLLECTOR_RE = re.compile(r"^postgresql-\d{4}-\d{2}-\d{2}_\d{6}\.log$")


# ---------------------------------------------------------------- utilities
class Hold(Exception):
    """Uncertainty: stop, keep everything, signal nothing more."""


class Refuse(Exception):
    """A precondition failed before anything was started."""


class Fail(Exception):
    """A definite negative result."""


def jdump(obj, path=None):
    text = json.dumps(obj, indent=2, sort_keys=True, default=str)
    if path is None:
        sys.stdout.write(text + "\n")
        return
    tmp = path + ".tmp-%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text + "\n")
    os.replace(tmp, path)


def jload(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        return json.load(f)


def now():
    """Monotonic seconds (repair plan section 0). Every deadline and every ordering
    comparison uses it; on macOS it is system-wide, so values written by the watcher and
    by the snapshot processes compare [A: confirmed by T16/T23 ordering at selftest].
    Wall-clock time is recorded separately (`wall`) for display only."""
    return time.monotonic()


def wall():
    return time.time()


def me():
    return os.getuid()


def run(argv, env=None, timeout=60, cwd=None):
    """Run a short helper; return (rc, stdout, stderr). Never via a shell."""
    p = subprocess.run(argv, env=env, cwd=cwd, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


TOOL_ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "TZ": "UTC"}


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file_nofollow(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    h = hashlib.sha256()
    with os.fdopen(fd, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def runtime_for_root(root):
    """devenv runtime dir: /tmp/devenv-<sha256(<root>/.devenv)[0:7]> (r2 2.3)."""
    h = hashlib.sha256((root + "/.devenv").encode()).hexdigest()[:7]
    return "/tmp/devenv-" + h, "/private/tmp/devenv-" + h


def physical(path):
    """True if `path` has no symlinked component (realpath equals itself)."""
    return os.path.realpath(path) == os.path.abspath(path)


def lstat_rec(path):
    st = os.lstat(path)
    return {
        "dev": st.st_dev, "ino": st.st_ino, "mode": stat.S_IMODE(st.st_mode),
        "type": filetype(st.st_mode), "uid": st.st_uid, "gid": st.st_gid,
        "nlink": st.st_nlink, "size": st.st_size, "mtime": st.st_mtime,
    }


def filetype(mode):
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISFIFO(mode):
        return "fifo"
    return "special"


# ---------------------------------------------------------------- libproc
class ProcBsdInfo(ctypes.Structure):
    # struct proc_bsdinfo (sys/proc_info.h); size 136 verified on macOS 15.7.5
    # with /usr/bin/python3 (r3 2.1). T16 re-verifies with the selected interpreter.
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
    ]


_libproc = None


def libproc():
    global _libproc
    if _libproc is None:
        name = ctypes.util.find_library("proc")
        if not name:
            raise Hold("libproc not found")
        _libproc = ctypes.CDLL(name, use_errno=True)
    return _libproc


def bsdinfo(pid):
    """Current identity of `pid`, or None if it does not exist. Raises Hold on other errors."""
    b = ProcBsdInfo()
    n = libproc().proc_pidinfo(int(pid), PROC_PIDTBSDINFO, ctypes.c_uint64(0),
                               ctypes.byref(b), ctypes.sizeof(b))
    if n == ctypes.sizeof(b):
        return {
            "pid": int(b.pbi_pid), "ppid": int(b.pbi_ppid), "pgid": int(b.pbi_pgid),
            "uid": int(b.pbi_uid), "comm": b.pbi_comm.decode("utf-8", "replace"),
            "birth_us": int(b.pbi_start_tvsec) * 1000000 + int(b.pbi_start_tvusec),
        }
    e = ctypes.get_errno()
    if n == 0 and e in (0, errno.ESRCH):
        return None
    if e == errno.ESRCH:
        return None
    raise Hold("proc_pidinfo(%d) failed: n=%d errno=%d" % (pid, n, e))


def child_pids(ppid):
    """Children of `ppid` via proc_listpids(PROC_PPID_ONLY); bytes returned / 4."""
    size = 4096 * 4
    buf = (ctypes.c_int * 4096)()
    n = libproc().proc_listpids(PROC_PPID_ONLY, ctypes.c_uint32(int(ppid)), buf, size)
    if n < 0:
        raise Hold("proc_listpids(ppid=%d) failed errno=%d" % (ppid, ctypes.get_errno()))
    return [int(buf[i]) for i in range(n // 4) if buf[i] > 0]


def pidpath(pid):
    buf = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    n = libproc().proc_pidpath(int(pid), buf, PROC_PIDPATHINFO_MAXSIZE)
    if n <= 0:
        e = ctypes.get_errno()
        if e == errno.ESRCH:
            return None
        raise Hold("proc_pidpath(%d) failed errno=%d" % (pid, e))
    return buf.value.decode("utf-8", "replace")


def proc_args(pid):
    """Process title/args (`ps -ww -o args=`); None if gone."""
    rc, out, _ = run(["/bin/ps", "-ww", "-o", "args=", "-p", str(pid)], env=TOOL_ENV)
    if rc != 0:
        return None
    return out.strip()


def proc_cwd(pid):
    rc, out, err = run(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                       env=TOOL_ENV)
    if rc not in (0, 1):
        raise Hold("lsof cwd pid %d rc=%d" % (pid, rc))
    for line in out.splitlines():
        if line.startswith("n"):
            return line[1:]
    return None


def decode_status(data):
    st = int(data) & NOTE_PDATAMASK
    if os.WIFEXITED(st):
        return {"kind": "exited", "code": os.WEXITSTATUS(st), "raw": st}
    if os.WIFSIGNALED(st):
        return {"kind": "signaled", "signal": os.WTERMSIG(st), "raw": st}
    return {"kind": "unknown", "raw": st}


# ---------------------------------------------------------------- lsof parsing
def tcp_listeners(port):
    """All TCP LISTEN records on `port`: [{'pid':..,'addr':..}]. Hold on lsof error (r4 4.1)."""
    rc, out, err = run(["/usr/sbin/lsof", "-nP", "-a", "-iTCP:%d" % port, "-sTCP:LISTEN",
                        "-F", "pfn"], env=TOOL_ENV)
    if rc not in (0, 1) or (rc == 1 and out.strip()) or err.strip():
        raise Hold("lsof listeners port %d rc=%d err=%r" % (port, rc, err.strip()[:200]))
    recs, pid = [], None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            recs.append({"pid": pid, "addr": line[1:]})
    return recs


def netstat_listen(port):
    rc, out, err = run(["/usr/sbin/netstat", "-anv", "-p", "tcp"], env=TOOL_ENV)
    if rc != 0:
        raise Hold("netstat rc=%d" % rc)
    hits = []
    for line in out.splitlines():
        cols = line.split()
        if len(cols) >= 6 and "LISTEN" in cols and cols[3].endswith("." + str(port)):
            hits.append(cols[3])
    return hits


def open_handles_under(path):
    """Processes with any open file under `path` (lsof +D). Hold on any lsof error."""
    rc, out, err = run(["/usr/sbin/lsof", "-n", "-P", "-F", "pcn", "+D", path], env=TOOL_ENV,
                       timeout=180)
    if rc == 1 and not out.strip() and not err.strip():
        return []
    if rc == 0 and not err.strip():
        pids = sorted({int(l[1:]) for l in out.splitlines() if l.startswith("p")})
        return pids
    raise Hold("lsof +D %s rc=%d err=%r" % (path, rc, err.strip()[:200]))


def writable_fds(pid):
    """Writable regular files open by `pid` (supplementary tripwire only, r3 4.2)."""
    rc, out, err = run(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", str(pid), "-F", "ftan"],
                       env=TOOL_ENV)
    if rc not in (0, 1):
        return None
    files, cur = [], {}
    for line in out.splitlines():
        tag, val = line[:1], line[1:]
        if tag == "f":
            if cur:
                files.append(cur)
            cur = {"fd": val}
        elif tag in ("a", "t", "n"):
            cur[tag] = val
    if cur:
        files.append(cur)
    return [f.get("n") for f in files if f.get("t") == "REG" and f.get("a") in ("w", "u")]


# ---------------------------------------------------------------- manifest
def manifest_new(args):
    """Create an instance root and its manifest (r2 3, r3/r4 envelope)."""
    kind, inst = args["kind"], args["inst"]
    if kind not in EDITS:
        raise Refuse("unknown instance kind %s" % kind)
    scratch, evidence = args["scratch"], args["evidence"]
    for d in (scratch, evidence):
        st = os.lstat(d)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != me() or stat.S_IMODE(st.st_mode) != 0o700:
            raise Refuse("REFUSE-ROOT parent %s must be a 0700 dir owned by me" % d)
        if not physical(d):
            raise Refuse("REFUSE-ROOT parent %s is not physical" % d)
    root = args.get("root")
    if not root:
        import tempfile
        root = tempfile.mkdtemp(prefix="sink-%s-" % inst, dir=scratch)
    validate_root(root)
    rt, rt_canon = runtime_for_root(root)
    port = 5520 if kind == "R" else (args.get("port") or pick_port())
    m = {
        "schema": "5b-sink-manifest/1", "inst": inst, "kind": kind,
        "head": args["head"], "worktree": args["worktree"],
        "root": root, "root_lstat": lstat_rec(root),
        "dotfile": root + "/.devenv", "state": root + "/.devenv/state",
        "pgdata": root + "/.devenv/state/postgres",
        "runtime": rt, "runtime_canonical": rt_canon,
        "pc_socket": rt + "/pc.sock", "native_socket": rt + "/processes/native.sock",
        "pg_socket_dir": rt + "/postgres",
        "pg_socket": rt + "/postgres/.s.PGSQL.%d" % port,
        "port": port, "listen": "127.0.0.1",
        "db_allow": DB_ALLOW.get(kind[0], ["postgres"]),
        "edits": EDITS[kind],
        "packages": PKG,
        "evidence": evidence + "/" + inst,
        "home": root + "/home", "tmpdir": root + "/tmp",
    }
    m["launch_env"] = launch_env(m)
    os.mkdir(m["evidence"], 0o700)
    for d in (m["home"], m["tmpdir"]):
        os.mkdir(d, 0o700)
    jdump(m, m["evidence"] + "/manifest.json")
    jdump({"manifest": m["evidence"] + "/manifest.json", "root": root, "port": port})
    return EXIT_OK


def launch_env(m):
    user = os.environ.get("USER") or ""
    if not user:
        import pwd
        user = pwd.getpwuid(me()).pw_name
    return {
        "PATH": PKG["bash-interactive"] + "/bin:" + PKG["coreutils"] + "/bin",
        "HOME": m["home"], "TMPDIR": m["tmpdir"], "USER": user, "LOGNAME": user,
        "LANG": "C", "LC_ALL": "C", "TZ": "UTC",
        "PGDATA": m["pgdata"], "PGHOST": m["pg_socket_dir"], "PGPORT": str(m["port"]),
        "PC_SOCKET_PATH": m["pc_socket"], "PC_TUI_ENABLED": "false",
    }


def validate_root(root):
    st = os.lstat(root)
    if stat.S_ISLNK(st.st_mode):
        raise Refuse("REFUSE-ROOT %s is a symlink" % root)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != me() or stat.S_IMODE(st.st_mode) != 0o700:
        raise Refuse("REFUSE-ROOT %s must be a 0700 dir owned by me" % root)
    if not physical(root):
        raise Refuse("REFUSE-ROOT %s has a symlinked ancestor" % root)
    rc, _, _ = run(["git", "-C", os.path.dirname(root), "rev-parse", "--show-toplevel"],
                   env=dict(TOOL_ENV, PATH=os.environ.get("PATH", TOOL_ENV["PATH"])))
    if rc == 0:
        raise Refuse("REFUSE-ROOT %s is inside a git checkout" % root)


def pick_port():
    for _ in range(50):
        p = secrets.randbelow(PORT_RANGE[1] - PORT_RANGE[0]) + PORT_RANGE[0]
        if p in FORBIDDEN_PORTS:
            continue
        if not tcp_listeners(p):
            return p
    raise Refuse("no free port found")


def load_manifest(path):
    m = jload(path)
    if m.get("schema") != "5b-sink-manifest/1":
        raise Refuse("bad manifest schema")
    if m["port"] in FORBIDDEN_PORTS and m["kind"] != "R":
        raise Refuse("forbidden port %d" % m["port"])
    return m


# ---------------------------------------------------------------- runtime claim
def claim_runtime(m):
    """Atomic exclusive claim (r2 4.1): mkdir without -p; EEXIST refuses."""
    try:
        os.mkdir(m["runtime"], 0o700)
    except FileExistsError:
        raise Refuse("REFUSE-RUNTIME-EXISTS %s" % m["runtime"])
    rec = lstat_rec(m["runtime"])
    if rec["type"] != "dir" or rec["uid"] != me() or rec["mode"] != 0o700:
        raise Hold("claimed runtime has unexpected type/owner/mode: %r" % rec)
    if os.path.realpath(m["runtime"]) != m["runtime_canonical"]:
        raise Hold("runtime realpath %s != %s" % (os.path.realpath(m["runtime"]),
                                                   m["runtime_canonical"]))
    if os.listdir(m["runtime"]):
        raise Hold("claimed runtime not empty")
    claim = {"runtime": m["runtime"], "lstat": rec, "t": now()}
    jdump(claim, m["evidence"] + "/runtime-claim.json")
    return claim


def recheck_runtime(m):
    claim = jload(m["evidence"] + "/runtime-claim.json")
    rec = lstat_rec(m["runtime"])
    for k in ("dev", "ino", "uid", "mode", "type"):
        if rec[k] != claim["lstat"][k]:
            raise Hold("runtime %s changed: %s %r != %r" % (m["runtime"], k, rec[k],
                                                            claim["lstat"][k]))
    return rec


# ---------------------------------------------------------------- preflight
def preflight(m, first_start):
    """Envelope and write-target constraints before any launch (r3 4.1, r4 1, r5)."""
    env = m["launch_env"]
    if tuple(sorted(env)) != tuple(sorted(ENV_KEYS)):
        raise Refuse("REFUSE-ENV launch env keys %r" % sorted(env))
    for k in ENV_MUST_BE_ABSENT:
        if k in env:
            raise Refuse("REFUSE-ENV %s present" % k)
    art = jload(m["evidence"] + "/artifacts.json")
    if env["PC_SOCKET_PATH"] != art["baked"]["pc_socket"]:
        raise Refuse("REFUSE-ENV PC_SOCKET_PATH %s != baked %s" % (env["PC_SOCKET_PATH"],
                                                                  art["baked"]["pc_socket"]))
    if os.path.dirname(art["baked"]["pc_socket"]) != m["runtime"]:
        raise Refuse("REFUSE-ENV attach/new-server socket not under claimed runtime")
    # TMPDIR: the SQLite temp-dir predicate (r4 1.1) and Go/Rust temp dirs.
    t = m["tmpdir"]
    rec = lstat_rec(t)
    if rec["type"] != "dir" or rec["uid"] != me() or rec["mode"] != 0o700 or \
            not os.access(t, os.W_OK | os.X_OK):
        raise Refuse("REFUSE-ENV TMPDIR %s fails the owned writable dir predicate" % t)
    if lstat_rec(m["home"])["mode"] != 0o700:
        raise Refuse("REFUSE-ENV HOME not 0700")
    if first_start:
        for p in (m["pc_socket"], m["pg_socket_dir"]):
            if os.path.lexists(p):
                raise Refuse("REFUSE-RUNTIME %s exists before first start" % p)
    if tcp_listeners(m["port"]):
        raise Refuse("REFUSE-PORT %d has a listener" % m["port"])
    return {"ok": True}


# ---------------------------------------------------------------- artifacts / provenance
STORE_RE = re.compile(r"/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+")


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def one(pattern, text, what):
    hits = sorted(set(re.findall(pattern, text)))
    if len(hits) != 1:
        raise Refuse("REFUSE-PROVENANCE %s: expected exactly one match, got %r" % (what, hits))
    return hits[0]


def artifacts(m, launcher):
    """Follow and hash the generated launch artifacts; record baked values (r2 6)."""
    a = {"launcher": launcher, "inst": m["inst"], "head": m["head"]}
    lt = read_text(launcher)
    a["yaml"] = one(r"--config=(/nix/store/[a-z0-9]{32}-process-compose\.yaml)", lt, "yaml")
    a["pc_socket_baked"] = one(r"--unix-socket=([^' ]+)'", lt, "unix-socket")
    yt = read_text(a["yaml"])
    a["tasks"] = one(r"--task-file (/nix/store/[a-z0-9]{32}-tasks\.json)", yt, "tasks.json")
    tasks = json.loads(read_text(a["tasks"]))
    pg = [t for t in tasks if t.get("name") == "devenv:processes:postgres"]
    if len(pg) != 1:
        raise Refuse("REFUSE-PROVENANCE postgres task not unique")
    a["task_cmd"] = pg[0]["command"]
    a["task_env"] = pg[0].get("env")
    a["task_ready_notify"] = (pg[0].get("process", {}).get("ready") or {}).get("notify")
    ct = read_text(a["task_cmd"])
    a["start"] = one(r"(/nix/store/[a-z0-9]{32}-start-postgres)/bin/start-postgres", ct, "start")
    st = read_text(a["start"] + "/bin/start-postgres")
    a["setup"] = one(r"(/nix/store/[a-z0-9]{32}-setup-postgres)/bin/setup-postgres", st, "setup")
    su = read_text(a["setup"] + "/bin/setup-postgres")
    a["conf"] = one(r"(/nix/store/[a-z0-9]{32}-postgresql\.conf)", su, "conf")
    files = {
        "launcher": launcher, "yaml": a["yaml"], "tasks": a["tasks"],
        "task_cmd": a["task_cmd"], "start": a["start"] + "/bin/start-postgres",
        "setup": a["setup"] + "/bin/setup-postgres", "conf": a["conf"],
    }
    a["files"] = {k: {"path": v, "sha256": sha256_file_nofollow(v)} for k, v in files.items()}
    texts = {k: read_text(v) for k, v in files.items()}
    a["yaml_environment_empty"] = bool(re.search(r"^\s*environment: \[\]\s*$", texts["yaml"], re.M))
    a["has_log_configuration"] = "log_configuration" in texts["yaml"]
    a["baked"] = {
        "pc_socket": a["pc_socket_baked"],
        "log_location": one(r"log_location:\s*\n?\s*(\S+process-compose\.log)", texts["yaml"],
                            "log_location"),
    }
    # W1: non-store absolute paths baked into the artifacts (r3 4.1).
    nonstore = set()
    for t in texts.values():
        for p in re.findall(r"(?:^|[^A-Za-z0-9_.-])(/[A-Za-z][A-Za-z0-9_./-]*)", t):
            if not p.startswith("/nix/store/"):
                nonstore.add(p)
    a["nonstore_paths"] = sorted(nonstore)
    # Package references (excluding the instance's generated artifacts).
    gen_names = ("-devenv-up", "-process-compose.yaml", "-tasks.json",
                 "-devenv-processes-postgres", "-start-postgres", "-setup-postgres",
                 "-postgresql.conf", "-devenv-container-copy", "-devenv-enterShell",
                 "-devenv-files-cleanup")
    refs = set()
    for t in texts.values():
        refs.update(STORE_RE.findall(t))
    a["package_refs"] = sorted(r for r in refs if not r.endswith(gen_names))
    a["normalized"] = {k: normalize(v, m) for k, v in texts.items()}
    return a


def normalize(text, m):
    t = text.replace(m["root"], "<ROOT>").replace(m["runtime"], "<RUNTIME>")
    p = str(m["port"])
    t = re.sub(r"(port = )%s\b" % p, r"\1<PORT>", t)
    t = re.sub(r"(-p )%s\b" % p, r"\1<PORT>", t)
    t = re.sub(r'("main": )%s\b' % p, r"\1<PORT>", t)
    t = re.sub(r"(\.s\.PGSQL\.)%s\b" % p, r"\1<PORT>", t)
    t = re.sub(r"/nix/store/[a-z0-9]{32}-(devenv-up|process-compose\.yaml|tasks\.json|"
               r"devenv-processes-postgres|start-postgres|setup-postgres|postgresql\.conf|"
               r"devenv-container-copy|devenv-enterShell|devenv-files-cleanup)",
               r"<ART:\1>", t)
    return t


def conf_diff(ref_conf, inst_conf):
    def parse(t):
        d = {}
        for line in t.splitlines():
            if not line.strip():
                continue
            k, _, v = line.partition(" = ")
            d[k] = v
        return d
    r, i = parse(ref_conf), parse(inst_conf)
    keys = sorted(set(r) | set(i))
    return {k: (r.get(k), i.get(k)) for k in keys if r.get(k) != i.get(k)}


def json_value_line(v):
    """devenv toStr spelling (impl-contract 7 amendment 1)."""
    if v is True:
        return "yes"
    if v is False:
        return "no"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def provenance_check(m, a, ref):
    """r2 6.1/6.2: package equality, normalized semantic diff with only reviewed deltas."""
    problems = []
    if sorted(a["package_refs"]) != sorted(ref["package_refs"]):
        problems.append(("package_refs", sorted(set(a["package_refs"]) ^ set(ref["package_refs"]))))
    expect_pkgs = sorted(PKG.values())
    for r in a["package_refs"]:
        if r not in expect_pkgs:
            problems.append(("unexpected_package", r))
    allowed_nonstore = {
        m["root"] + "/.devenv/state/process-compose",
        m["root"] + "/.devenv/state/process-compose/process-compose.log",
        m["root"] + "/.devenv", m["runtime"], m["runtime"] + "/pc.sock",
        m["runtime"] + "/postgres", "/dev/null",
    }
    extra = [p for p in a["nonstore_paths"] if p not in allowed_nonstore]
    if extra:
        problems.append(("W1_nonstore_paths", extra))
    for k, nt in a["normalized"].items():
        if k == "conf":
            continue
        if k == "setup":
            # setup only differs from the reference by its normalized conf reference
            if nt != ref["normalized"][k]:
                problems.append(("normalized_diff", k))
            continue
        if nt != ref["normalized"][k]:
            problems.append(("normalized_diff", k))
    d = conf_diff(ref["normalized"]["conf"], a["normalized"]["conf"])
    edits = m["edits"] or {}
    expected = {k: (None if k not in ref_conf_keys(ref) else ref_conf_value(ref, k),
                    json_value_line(v)) for k, v in edits.items()}
    if d != expected:
        problems.append(("conf_delta", {"observed": d, "reviewed": expected}))
    if not a["yaml_environment_empty"] or a["task_env"] != {}:
        problems.append(("generated_env_maps_not_empty", [a["yaml_environment_empty"],
                                                          a["task_env"]]))
    if a["task_ready_notify"] is not False:
        problems.append(("ready_notify", a["task_ready_notify"]))
    if a["has_log_configuration"]:
        problems.append(("yaml_log_configuration_present", True))
    return problems


def ref_conf_keys(ref):
    return {l.partition(" = ")[0] for l in ref["normalized"]["conf"].splitlines() if l.strip()}


def ref_conf_value(ref, k):
    for l in ref["normalized"]["conf"].splitlines():
        key, _, v = l.partition(" = ")
        if key == k:
            return v
    return None


def contract_check(m, a, expected_contract_path):
    """B: generated conf minus topology byte-equals the pinned expected contract (r2 6.3)."""
    conf = read_text(a["conf"]).rstrip("\n") + "\n"
    topo_re = re.compile(r"^(listen_addresses|port|unix_socket_directories) = ")
    topo = [l for l in conf.splitlines() if topo_re.match(l)]
    rest = "".join(l + "\n" for l in conf.splitlines() if l and not topo_re.match(l))
    want_topo = sorted([
        "listen_addresses = '127.0.0.1'", "port = %d" % m["port"],
        "unix_socket_directories = '%s/postgres'" % m["runtime"],
    ])
    problems = []
    if sorted(topo) != want_topo:
        problems.append(("topology", topo))
    if rest != read_text(expected_contract_path):
        problems.append(("contract_lines_differ", True))
    return problems


# ---------------------------------------------------------------- inventory (r2 11.1, r4/r5)
def classify_path(m, rel_root, rel, rec):
    """Return (class, searched, append_only) or raise Fail for an unknown entry."""
    R, T, D = m["root"], m["runtime"], m["pgdata"]
    full = rel_root + ("/" + rel if rel else "")
    t = rec["type"]
    if t == "symlink":
        raise Fail("FAIL-SYMLINK %s" % full)
    if t in ("fifo", "special"):
        raise Fail("FAIL-SPECIAL %s" % full)
    if t == "file" and rec["nlink"] > 1:
        raise Fail("FAIL-HARDLINK %s" % full)
    if t == "dir":
        return ("dir", False, False)
    sockets = {T + "/pc.sock": "manager-socket", T + "/processes/native.sock": "manager-socket",
               m["pg_socket"]: "pg-socket"}
    if t == "socket":
        if full in sockets:
            return (sockets[full], False, False)
        raise Fail("FAIL-SOCKET %s" % full)
    if t != "file":
        raise Fail("FAIL-TYPE %s" % full)
    if full.startswith(R + "/.git/") or full in (
            R + "/flake.nix", R + "/flake.lock", R + "/devenv.nix",
            R + "/priv/postgres/log_settings.json"):
        return ("copy-source", True, False)
    if full == R + "/.devenv/state/process-compose/process-compose.log":
        return ("manager-aggregate-sink", True, True)
    user = m["launch_env"]["USER"]
    if full == R + "/tmp/process-compose-%s.log" % user:
        return ("manager-internal-log", True, True)
    if full in (R + "/.devenv/tasks.db", R + "/.devenv/tasks.db-wal", R + "/.devenv/tasks.db-shm",
                R + "/.devenv/tasks.db-journal"):
        return ("manager-cache", True, False)
    if full in (T + "/processes/logs/postgres.stdout.log", T + "/processes/logs/postgres.stderr.log"):
        return ("per-process-sink", True, True)
    if full == T + "/processes/native-manager.pid":
        return ("manager-state", True, False)
    if full == m["pg_socket"] + ".lock":
        return ("pg-runtime-state", True, False)
    if full.startswith(D + "/log/"):
        if COLLECTOR_RE.match(os.path.basename(full)) and os.path.dirname(full) == D + "/log":
            if rec["mode"] != 0o600:
                raise Fail("FAIL-COLLECTOR-MODE %s %o" % (full, rec["mode"]))
            return ("collector-sink", True, True)
        raise Fail("FAIL-UNKNOWN-IN-LOG %s" % full)
    if full == D + "/current_logfiles":
        return ("collector-metadata", True, False)
    if full in (D + "/" + n for n in ("PG_VERSION", "postgresql.conf", "postgresql.auto.conf",
                                       "pg_hba.conf", "pg_ident.conf", "postmaster.opts",
                                       "postmaster.pid", ".devenv_initialized", "standby.signal")):
        return ("pg-config-state", True, False)
    storage = ("base", "global", "pg_wal", "pg_xact", "pg_multixact", "pg_subtrans", "pg_commit_ts",
               "pg_logical", "pg_notify", "pg_replslot", "pg_serial", "pg_snapshots", "pg_stat",
               "pg_stat_tmp", "pg_twophase", "pg_dynshmem")
    for s in storage:
        if full.startswith(D + "/" + s + "/"):
            return ("pg-storage", False, False)
    if full.startswith(D + "/pg_tblspc/"):
        raise Fail("FAIL-TABLESPACE %s" % full)
    raise Fail("FAIL-UNKNOWN %s" % full)


def walk(top):
    """Yield (relpath, lstat_rec) without following symlinks or crossing devices."""
    top_dev = os.lstat(top).st_dev
    stack = [""]
    while stack:
        rel = stack.pop()
        path = top + ("/" + rel if rel else "")
        try:
            entries = list(os.scandir(path))
        except PermissionError:
            raise Fail("FAIL-UNREADABLE %s" % path)
        for e in entries:
            r = (rel + "/" if rel else "") + e.name
            rec = lstat_rec(top + "/" + r)
            if rec["dev"] != top_dev:
                raise Fail("FAIL-DEVICE %s" % (top + "/" + r))
            yield r, rec
            if rec["type"] == "dir":
                stack.append(r)


HARNESS_SINK_RE = re.compile(r"^(launcher\.(out|err)|client-[A-Za-z0-9_.-]+\.(out|err))$")


def harness_sinks(m):
    """Launcher and client output captures under the instance evidence dir (searched)."""
    out = []
    ev = m["evidence"]
    for dirpath, dirnames, filenames in os.walk(ev):
        dirnames[:] = [d for d in dirnames if not d.startswith("SNAP-") and d != "ctl"]
        for f in filenames:
            if HARNESS_SINK_RE.match(f):
                p = os.path.join(dirpath, f)
                rec = lstat_rec(p)
                if rec["type"] != "file" or rec["nlink"] > 1:
                    raise Fail("FAIL-HARNESS-SINK %s" % p)
                out.append({"path": p, "class": "harness-sink", "searched": True,
                            "append_only": f.startswith("launcher."), "lstat": rec})
    return out


def inventory(m):
    out = {"t": now(), "entries": []}
    for top in (m["root"], m["runtime"]):
        if not os.path.lexists(top):
            out["entries"].append({"top": top, "absent": True})
            continue
        for rel, rec in walk(top):
            klass, searched, append_only = classify_path(m, top, rel, rec)
            full = top + "/" + rel
            if searched and not os.access(full, os.R_OK):
                raise Fail("FAIL-UNREADABLE %s" % full)
            out["entries"].append({"path": full, "class": klass, "searched": searched,
                                   "append_only": append_only, "lstat": rec})
    if os.path.isdir(m.get("evidence", "")):
        out["entries"].extend(harness_sinks(m))
    return out


# ---------------------------------------------------------------- snapshots (r5 4.2)
def write_all(fd, data, writer):
    """Write every byte, checking progress (repair H5). Zero progress is HOLD."""
    off = 0
    while off < len(data):
        n = writer(fd, data[off:])
        if not isinstance(n, int) or n <= 0:
            raise Hold("snapshot write made no progress (%r) at %d of %d" % (n, off, len(data)))
        off += n


def snap_file(src, dst, writer=None):
    """One open of the source: fstat, read exactly L bytes, write every byte to `dst` with
    checked progress, fsync, then re-read the copy and require its length and sha256 to
    equal the bytes read (repair H5). Any mismatch is HOLD; the partial copy is retained."""
    writer = writer or os.write
    fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st1 = os.fstat(fd)
        if not stat.S_ISREG(st1.st_mode):
            raise Hold("snapshot source not regular: %s" % src)
        L = st1.st_size
        h = hashlib.sha256()
        out = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        got = 0
        try:
            while got < L:
                chunk = os.read(fd, min(1 << 20, L - got))
                if not chunk:
                    raise Hold("short read on %s (%d of %d)" % (src, got, L))
                h.update(chunk)
                write_all(out, chunk, writer)
                got += len(chunk)
            os.fsync(out)
        finally:
            os.close(out)
        st2 = os.fstat(fd)
        if (st2.st_dev, st2.st_ino) != (st1.st_dev, st1.st_ino) or st2.st_size < L:
            raise Hold("snapshot source changed under read: %s" % src)
    finally:
        os.close(fd)
    src_sha = h.hexdigest()
    copy = read_verified_bytes(dst, L, src_sha)
    return {"dev": st1.st_dev, "ino": st1.st_ino, "len": L, "sha256": src_sha,
            "copy_len": len(copy), "copy_sha256": src_sha, "proof": "file-read"}


def read_verified_bytes(path, want_len, want_sha):
    """Read a snapshot copy once (no follow) and require its length and sha256."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Hold("snapshot copy not regular: %s" % path)
        parts, got = [], 0
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            parts.append(chunk)
            got += len(chunk)
    finally:
        os.close(fd)
    data = b"".join(parts)
    if len(data) != want_len or sha256_bytes(data) != want_sha:
        raise Hold("snapshot copy %s does not match its record (len %d vs %d)" % (
            path, len(data), want_len))
    return data


def prefix_sha(path, L):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        h, got = hashlib.sha256(), 0
        while got < L:
            chunk = os.read(fd, min(1 << 20, L - got))
            if not chunk:
                return {"dev": st.st_dev, "ino": st.st_ino, "size": st.st_size, "sha256": None}
            h.update(chunk)
            got += len(chunk)
        return {"dev": st.st_dev, "ino": st.st_ino, "size": st.st_size, "sha256": h.hexdigest()}
    finally:
        os.close(fd)


def socket_rec(path):
    if not os.path.lexists(path):
        return {"present": False}
    r = lstat_rec(path)
    r["present"] = True
    return r


def snapshot(m, name, out_dir, prev=None):
    """Snapshot every searched sink; check append-only prefixes against `prev` (r5 3.3)."""
    os.makedirs(out_dir, 0o700)
    inv = inventory(m)
    rec = {"name": name, "t": now(), "wall": wall(), "files": {}, "sockets": {}, "violations": []}
    for e in inv["entries"]:
        if e.get("absent") or not e["searched"]:
            continue
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", e["path"])
        meta = snap_file(e["path"], out_dir + "/" + safe)
        meta.update({"class": e["class"], "append_only": e["append_only"], "copy": safe})
        rec["files"][e["path"]] = meta
    for s in (m["pc_socket"], m["native_socket"]):
        rec["sockets"][s] = socket_rec(s)
    if prev is not None:
        for path, pm in prev["files"].items():
            if not pm["append_only"]:
                continue
            cur = rec["files"].get(path)
            if cur is None:
                rec["violations"].append(("capture-missing", path))
                continue
            if (cur["dev"], cur["ino"]) != (pm["dev"], pm["ino"]):
                rec["violations"].append(("capture-replaced", path))
                continue
            if cur["len"] < pm["len"]:
                rec["violations"].append(("capture-shrank", path))
                continue
            ps = prefix_sha(path, pm["len"])
            if ps["sha256"] != pm["sha256"]:
                rec["violations"].append(("capture-prefix-changed", path))
        for path, cur in rec["files"].items():
            if cur["append_only"] and path not in prev["files"]:
                rec["violations"].append(("capture-new-in-window", path))
    rec["inventory"] = inv
    jdump(rec, out_dir + "/snapshot.json")
    return rec


# ---------------------------------------------------------------- counting (r2 11.2)
def grep_count(data, needle):
    """`grep -F -c -a` semantics on bytes (repair H5, review 29bdd2d6): the number of
    newline-delimited lines that contain `needle`. An unterminated final line is a line;
    empty input has no lines; several hits on one line count once; bytes are never decoded."""
    if not isinstance(data, bytes) or not isinstance(needle, bytes) or not needle:
        raise Hold("grep_count needs bytes and a non-empty needle")
    if not data:
        return 0
    lines = data.split(b"\n")
    if data.endswith(b"\n"):
        lines = lines[:-1]
    return sum(1 for line in lines if needle in line)


def count_markers(snap_dir, markers):
    """Count markers on the verified bytes of each snapshot copy (repair H5): each copy is
    read once and must match its recorded length and sha256 before any count; a mismatch
    or read failure is HOLD, never a zero."""
    snap = jload(snap_dir + "/snapshot.json")
    counts = []
    for path, meta in sorted(snap["files"].items()):
        copy = snap_dir + "/" + meta["copy"]
        if meta.get("copy_len") != meta.get("len") or meta.get("copy_sha256") != meta.get("sha256"):
            raise Hold("snapshot record for %s lacks a verified copy" % path)
        data = read_verified_bytes(copy, meta["copy_len"], meta["copy_sha256"])
        for label, marker in sorted(markers.items()):
            n = grep_count(data, marker.encode("utf-8"))
            counts.append({"path": path, "class": meta["class"], "marker": label, "count": n,
                           "len": meta["len"], "sha256": meta["sha256"],
                           "method": "in-memory-verified", "proof": "file-read"})
    return counts


# ---------------------------------------------------------------- watcher (supervise)
ROLE_SIGNALLABLE = ("launcher", "process-compose", "devenv-tasks")
TRIPWIRE_ROLES = ("launcher", "process-compose", "devenv-tasks", "postmaster-final", "pg-logger")
TRIPWIRE_PERIOD = 5.0


def sh_forms(m):
    """The four source-bound /bin/sh command forms allowed in the owned init phase
    (deviation D-1 as replaced by amendment R2). Sources: pinned PostgreSQL 18.6,
    pg_ctl.c:486-497 (execl("/bin/sh", "/bin/sh", "-c", cmd)), 2278-2290 (-D), 2306-2317 (-o);
    initdb.c:1231-1252 (system, --check), 1612-1617 (popen, --boot), 3112-3115 (popen,
    --single); port.h:162 (DEVNULL). Every literal path and manifest value is escaped.
    [A] popen()/system() pass argv0 "sh" (macOS libc), and the WAL segment is the 16 MiB
    default: a mismatch is a violation and HOLD for review, never a broader allowance."""
    P = PG_BIN + "/postgres"
    rt, pgd, port = m["runtime"], m["pgdata"], int(m["port"])
    opts = "-c unix_socket_directories=%s/postgres -c listen_addresses= -p %d" % (rt, port)

    def exact(s):
        return re.compile("^" + re.escape(s) + "$")

    initdb = {"parent_exe": PG_BIN + "/initdb", "parent_args": "initdb --locale=C --encoding=UTF8"}
    return {
        "pg_ctl-start": {
            "parent_exe": PG_BIN + "/pg_ctl",
            "parent_args": "pg_ctl -D %s -w start -o %s" % (pgd, opts),
            "child": exact('/bin/sh -c exec "%s" -D "%s" %s < "/dev/null" 2>&1' % (P, pgd, opts)),
            "exec_role": "postmaster-init"},
        "initdb-check": dict(initdb, exec_role="pg-bootstrap", child=re.compile(
            "^" + re.escape('sh -c "%s" --check -F -c log_checkpoints=false  -c max_connections='
                            % P) + r"[0-9]+" + re.escape(" -c autovacuum_worker_slots=") +
            r"[0-9]+" + re.escape(" -c shared_buffers=") + r"[0-9]+" +
            re.escape(" -c dynamic_shared_memory_type=") + r"(posix|sysv)" +
            re.escape(' < "/dev/null" > "/dev/null" 2>&1') + "$")),
        "initdb-boot": dict(initdb, exec_role="pg-bootstrap", child=exact(
            'sh -c "%s" --boot -F -c log_checkpoints=false  -X 16777216 -k' % P)),
        "initdb-single": dict(initdb, exec_role="pg-bootstrap", child=exact(
            'sh -c "%s" --single -F -O -j -c search_path=pg_catalog -c exit_on_error=true '
            '-c log_checkpoints=false  template1 >/dev/null' % P)),
    }


IMAGE_VIOLATIONS = ("exe-not-allowlisted", "sh-form-mismatch", "sh-child-mismatch",
                    "sh-exec-mismatch", "sh-outside-init-phase")
H_FIELDS = {"closure_verified": bool, "image_violations": int, "exec_unobserved": int,
            "admission_unreadable_live": int, "api_client_history": str, "verdict": bool}


def h_closure(m):
    """The verified command/source closure for H (repair H1; review 7d6a2047, 29bdd2d6):
    provenance.json is exactly {"problems": []}; artifacts.json is bound to this manifest
    (inst, head, launcher-path), its files re-hash to their records, its package references
    equal the pinned PKG set and the reviewed reference instance's. File existence alone
    is never H; any unreadable, malformed, stale or unbound record is false."""
    ev = m["evidence"]
    checks = {}
    try:
        prov = jload(ev + "/provenance.json")
        checks["provenance_exact_empty"] = isinstance(prov, dict) and set(prov) == {"problems"} \
            and prov["problems"] == []
        art = jload(ev + "/artifacts.json")
        lp = read_text(ev + "/launcher-path").strip()
        checks["artifacts_bound"] = isinstance(art, dict) and art.get("inst") == m["inst"] and \
            art.get("head") == m["head"] and art.get("launcher") == lp
        files = art.get("files") if isinstance(art, dict) else None
        want = {"launcher", "yaml", "tasks", "task_cmd", "start", "setup", "conf"}
        checks["artifact_files_rehash"] = isinstance(files, dict) and set(files) == want and all(
            isinstance(v, dict) and isinstance(v.get("path"), str) and
            sha256_file_nofollow(v["path"]) == v.get("sha256") for v in files.values())
        ref = jload(os.path.dirname(ev) + "/R/artifacts.json")
        refs = art.get("package_refs") if isinstance(art, dict) else None
        checks["reference_bound"] = isinstance(ref, dict) and ref.get("inst") == "R" and \
            ref.get("head") == m["head"]
        checks["packages_equal_pinned"] = isinstance(refs, list) and \
            sorted(refs) == sorted(PKG.values()) and isinstance(ref.get("package_refs"), list) \
            and sorted(ref["package_refs"]) == sorted(refs)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        return {"closure_verified": False, "checks": checks,
                "detail": "unreadable or malformed: %s" % type(e).__name__}
    ok = bool(checks) and all(checks.values())
    return {"closure_verified": ok, "checks": checks,
            "detail": "ok" if ok else "failed: %s" % sorted(k for k, v in checks.items() if not v)}


class Watch(object):
    """Owned-process tracking with kqueue handles and µs birth identity (r3 2, r4 3),
    repaired per H1 (no old-image reuse; fail-closed image reads; explicit H record),
    H2 (signals freeze after any uncertainty) and D-1 (exact /bin/sh forms)."""

    def __init__(self, m, state_path):
        self.m = m
        self.state_path = state_path
        self.kq = select.kqueue()
        self.entries = {}       # pid -> live entry (a pid key is reused only after exit)
        self.dead = []          # exited entries
        self.events = []
        self.violations = []
        self.gaps = []
        self.fork_notes = {}    # pid -> count (observation only)
        self.marks = {}
        self.harness_signals = []
        self.launcher = None
        self.launcher_identity = None
        self.launcher_reaped = None
        self.helpers = []
        self.signals_frozen = False
        self.closure = {"closure_verified": False, "detail": "not-loaded"}
        self.forms = sh_forms(m) if all(k in m for k in ("runtime", "pgdata", "port")) else {}
        self.dirty = True

    def violation(self, kind, **kw):
        self.violations.append(dict(kw, t=now(), kind=kind))
        self.dirty = True

    # -- registration
    def register(self, pid):
        ev = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                           flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE, fflags=PROC_FFLAGS)
        try:
            self.kq.control([ev], 0, 0)
            return True
        except OSError as e:
            if e.errno == errno.ESRCH:
                return False
            raise Hold("kqueue registration pid %d errno %d" % (pid, e.errno))

    def find(self, pid, birth=None):
        """The live or dead entry for pid (and birth when given)."""
        e = self.entries.get(pid)
        if e is not None and (birth is None or e["birth_us"] == birth):
            return e
        for d in reversed(self.dead):
            if d["pid"] == pid and (birth is None or d["birth_us"] == birth):
                return d
        return None

    def admit(self, pid, parent, path):
        """Admit `pid` as a lineage child of `parent` (an owned, live entry) - r3 2.2."""
        pe = self.entries.get(parent)
        if pe is None or pe.get("exit") is not None:
            self.gap("parent-not-live", pid, parent)
            return None
        pcur = bsdinfo(parent)
        if pcur is None or pcur["birth_us"] != pe["birth_us"]:
            self.gap("parent-identity-changed", pid, parent)
            return None
        if not self.register(pid):
            self.gap("child-gone-before-register", pid, parent)
            return None
        cur = bsdinfo(pid)
        if cur is None:
            self.gap("child-gone-after-register", pid, parent)
            return None
        if cur["ppid"] != parent or cur["uid"] != me() or cur["birth_us"] < pe["birth_us"]:
            self.gap("child-not-of-parent", pid, parent)
            return None
        pcur2 = bsdinfo(parent)
        if pcur2 is None or pcur2["birth_us"] != pe["birth_us"]:
            self.gap("parent-changed-during-admission", pid, parent)
            return None
        return self._add(pid, cur, path, parent, lineage=True, proof="kernel-event")

    def _add(self, pid, cur, path, parent, lineage, proof="poll-observation"):
        """Admission (repair H1): an image that cannot be read for a LIVE process is a
        violation and HOLD; a child already gone is an ordinary coverage gap only."""
        try:
            exe = pidpath(pid)
        except Hold as h:
            self.violation("admission-image-unreadable-live", pid=pid, detail=str(h))
            raise
        if exe is None:
            self.gap("exe-unreadable-gone", pid, parent)
            return None
        args = proc_args(pid)
        if args is None:
            again = bsdinfo(pid)
            if again is not None and again["birth_us"] == cur["birth_us"]:
                self.violation("admission-image-unreadable-live", pid=pid, detail="args")
                raise Hold("admission args unreadable for live pid %d" % pid)
            self.gap("args-unreadable-gone", pid, parent)
            return None
        pe = self.entries.get(parent) if parent is not None else None
        e = {"pid": pid, "birth_us": cur["birth_us"], "ppid_at_admission": cur["ppid"],
             "uid": cur["uid"], "comm": cur["comm"], "exe": exe, "args": args,
             "lineage": lineage, "parent": parent,
             "parent_birth_us": pe["birth_us"] if pe else None,
             "admitted": now(), "via": path, "proof": proof,
             "exit": None, "role": None, "execs": 0}
        e["role"] = self.classify(e)
        self.entries[pid] = e
        self.check_exe(e)
        self.events.append({"t": now(), "ev": "admit", "pid": pid, "birth_us": cur["birth_us"],
                            "role": e["role"], "via": path, "proof": proof})
        self.dirty = True
        return e

    def parent_entry(self, e):
        if e.get("parent") is None:
            return None
        return self.find(e["parent"], e.get("parent_birth_us"))

    def parent_role(self, e):
        pe = self.parent_entry(e)
        return pe["role"] if pe else None

    def sh_allowed(self, e):
        """D-1 (amendment R2): /bin/sh only in the four exact source-bound forms, under the
        exact pg_ctl/initdb parent image and argv, in the owned init phase."""
        if os.path.exists(self.m["pgdata"] + "/.devenv_initialized"):
            self.violation("sh-outside-init-phase", pid=e["pid"])
            return False
        pe = self.parent_entry(e)
        if pe is None or not pe.get("lineage") or not e.get("lineage") or pe.get("exe") is None:
            self.violation("sh-form-mismatch", pid=e["pid"], why="parent not lineage-owned")
            return False
        parent_exe = os.path.realpath(pe["exe"])
        for name, f in sorted(self.forms.items()):
            if parent_exe == f["parent_exe"] and pe.get("args") == f["parent_args"] and \
                    e.get("args") is not None and f["child"].match(e["args"]):
                e["allowance"] = name
                e["exec_role"] = f["exec_role"]
                e["allowed_children"] = 0
                self.events.append({"t": now(), "ev": "allowance", "pid": e["pid"], "form": name})
                return True
        self.violation("sh-form-mismatch", pid=e["pid"], args=e.get("args"),
                       parent_exe=pe.get("exe"), parent_args=pe.get("args"))
        return False

    def check_exe(self, e):
        """Image checks. The package-bin-directory test is SUPPLEMENTARY (deviation D-7):
        H rests on h_closure plus these observations, never on the directory test alone."""
        exe = os.path.realpath(e["exe"]) if e["exe"] else None
        pe = self.parent_entry(e)
        if exe is None:
            ok = False
        elif e["role"] == "launcher":
            ok = exe.startswith(PKG["bash"] + "/bin/")
        elif exe in SYSTEM_SH:
            return self.sh_allowed(e) or None
        elif pe is not None and "allowance" in pe:
            ok = exe == PG_BIN + "/postgres" and pe.get("allowed_children", 0) == 0
            if ok:
                pe["allowed_children"] = 1
            else:
                self.violation("sh-child-mismatch", pid=e["pid"], exe=e["exe"])
                return None
        else:
            ok = exe.startswith(EXEC_ALLOW_PREFIXES)
        if not ok:
            self.violation("exe-not-allowlisted", pid=e["pid"], exe=e["exe"])

    def classify(self, e):
        exe, args = e["exe"] or "", e["args"] or ""
        pe = self.parent_entry(e)
        prole = pe["role"] if pe else None
        if exe and os.path.realpath(exe) in SYSTEM_SH:
            return "pg-sh"
        if pe is not None and "allowance" in pe and exe == PG_BIN + "/postgres":
            return pe["exec_role"]
        if self.launcher is not None and e["pid"] == self.launcher.pid:
            return "launcher"
        if exe == PC_BIN:
            return "process-compose"
        if exe == DT_BIN:
            return "devenv-tasks"
        if exe == PG_BIN + "/postgres":
            if prole in ("postmaster-final", "postmaster-init", "postmaster-identified"):
                if "logger" in args:
                    return "pg-logger"
                if BACKEND_RE.match(args):
                    return "pg-backend"
                return "pg-aux"
            if prole in ("wrapper", "start-postgres") or e.get("prev_role") == "start-postgres":
                return "postmaster-final"
            return "postmaster-init"
        if exe.startswith(PKG["bash"] + "/bin/") or exe.startswith(PKG["bash-interactive"] + "/bin/"):
            if "-devenv-processes-postgres" in args:
                return "wrapper"
            if "/bin/start-postgres" in args:
                return "start-postgres"
            if "/bin/setup-postgres" in args:
                return "setup-postgres"
            return "shell"
        if exe.startswith(PG_BIN + "/"):
            return "pg-tool"
        return "other"

    def gap(self, why, pid, parent):
        self.gaps.append({"t": now(), "why": why, "pid": pid, "parent": parent,
                          "proof": "poll-observation"})
        self.dirty = True

    # -- event handling
    def handle(self, ev):
        pid = ev.ident
        e = self.entries.get(pid)
        if ev.fflags & NOTE_FORK:
            self.fork_notes[pid] = self.fork_notes.get(pid, 0) + 1
            self.events.append({"t": now(), "ev": "fork-note", "pid": pid,
                                "birth_us": e["birth_us"] if e else None, "proof": "kernel-event"})
            if not ev.fflags & NOTE_EXIT:
                self.scan_children(pid, "note-fork")
        if ev.fflags & NOTE_EXEC and e is not None and e["exit"] is None:
            self.on_exec(e, gone=bool(ev.fflags & NOTE_EXIT))
        if ev.fflags & NOTE_EXIT:
            if e is None:
                return
            if not ev.fflags & NOTE_EXITSTATUS:
                e["exit"] = {"t": now(), "kind": "no-exitstatus"}
                self.violation("exit-without-status", pid=pid)
            else:
                e["exit"] = dict(decode_status(ev.data), t=now(), proof="kernel-event")
            self.events.append({"t": now(), "ev": "exit", "pid": pid, "birth_us": e["birth_us"],
                                "role": e["role"], "status": e["exit"]})
            self.dead.append(self.entries.pop(pid))
            self.dirty = True

    def on_exec(self, e, gone):
        """NOTE_EXEC (repair H1): the new image is re-read with NO fallback to the old one.
        Unreadable while alive: violation + HOLD. Gone (coalesced EXEC+EXIT or exited):
        violation exec-image-unobserved-before-exit, role unknown-image."""
        pid = e["pid"]
        e["execs"] += 1
        prior = {"exe": e["exe"], "args": e["args"], "role": e["role"]}
        e.setdefault("prior_images", []).append(prior)
        exe = args = None
        if not gone:
            try:
                exe = pidpath(pid)
            except Hold as h:
                self.violation("exec-image-unreadable-live", pid=pid, detail=str(h))
                raise
            args = proc_args(pid) if exe is not None else None
            if exe is None or args is None:
                cur = bsdinfo(pid)
                if cur is not None and cur["birth_us"] == e["birth_us"]:
                    self.violation("exec-image-unreadable-live", pid=pid)
                    raise Hold("exec image unreadable for live pid %d" % pid)
                gone = True
        if gone:
            e["exe"], e["args"], e["role"] = None, None, "unknown-image"
            self.violation("exec-image-unobserved-before-exit", pid=pid, prior_role=prior["role"])
        else:
            e["exe"], e["args"], e["prev_role"] = exe, args, prior["role"]
            if "allowance" in e:
                real = os.path.realpath(exe)
                if real in SYSTEM_SH and args == prior["args"]:
                    pass  # the /bin/sh shim handing the same command to its select target
                elif real == PG_BIN + "/postgres":
                    e["role"] = e["exec_role"]
                else:
                    self.violation("sh-exec-mismatch", pid=pid, exe=exe)
            else:
                e["role"] = self.classify(e)
                self.check_exe(e)
        self.events.append({"t": now(), "ev": "exec", "pid": pid, "birth_us": e["birth_us"],
                            "from": prior["role"], "to": e["role"], "proof": "kernel-event"})
        self.dirty = True

    def scan_children(self, pid, path):
        e = self.entries.get(pid)
        if e is None or e["exit"] is not None:
            return
        try:
            kids = child_pids(pid)
        except Hold as h:
            self.violation("listchild-failed", detail=str(h))
            return
        new = [k for k in kids if k not in self.entries]
        if path == "note-fork" and not new:
            self.gap("fork-note-no-new-child", None, pid)
        for k in new:
            self.admit(k, pid, path)

    def identify_postmaster(self):
        """PGDATA identity for postmasters lineage cannot hold (reparented init server).
        Identified, not lineage-owned: never signalled directly (r3 2.3)."""
        pidfile = self.m["pgdata"] + "/postmaster.pid"
        try:
            with open(pidfile, "r") as f:
                lines = f.read().splitlines()
        except (FileNotFoundError, PermissionError):
            return
        if len(lines) < 2 or not lines[0].strip().isdigit():
            return
        pid = int(lines[0])
        if pid in self.entries or lines[1] != self.m["pgdata"]:
            return
        cur = bsdinfo(pid)
        if cur is None or cur["uid"] != me():
            return
        if proc_cwd(pid) != os.path.realpath(self.m["pgdata"]):
            return
        if not self.register(pid):
            return
        e = self._add(pid, cur, "pgdata-identity", None, lineage=False, proof="pgdata-identity")
        if e is not None:
            e["role"] = "postmaster-init" if not os.path.exists(
                self.m["pgdata"] + "/.devenv_initialized") else "postmaster-identified"

    def refresh(self):
        """Re-read titles of PG children (a title may be set after admission) and detect
        any exit that produced no kqueue event (uncertainty, never absence)."""
        for pid, e in list(self.entries.items()):
            cur = bsdinfo(pid)
            if cur is None or cur["birth_us"] != e["birth_us"]:
                e["exit"] = {"t": now(), "kind": "unobserved"}
                self.violation("exit-unobserved", pid=pid, role=e["role"])
                self.dead.append(self.entries.pop(pid))
                continue
            if e["role"] in ("pg-aux", "pg-backend", "pg-logger"):
                args = proc_args(pid)
                if args and args != e["args"]:
                    e["args"] = args
                    role = self.classify(e)
                    if role != e["role"]:
                        self.events.append({"t": now(), "ev": "reclassify", "pid": pid,
                                            "from": e["role"], "to": role})
                        e["role"] = role
                    self.dirty = True

    def tripwire(self):
        """Supplementary only (r3 4.2): a writable regular file outside the owned roots,
        held by a long-lived owned process, is a violation. A miss proves nothing."""
        allowed = (self.m["root"] + "/", self.m["runtime_canonical"] + "/",
                   self.m["runtime"] + "/", self.m["evidence"] + "/", "/dev/")
        for e in list(self.entries.values()):
            if e["role"] not in TRIPWIRE_ROLES:
                continue
            paths = writable_fds(e["pid"])
            if paths is None:
                continue
            for path in paths:
                if path and not path.startswith(allowed):
                    self.violation("writable-fd-outside-roots", pid=e["pid"], role=e["role"],
                                   path=path)

    def drain(self, timeout=0):
        for ev in self.kq.control(None, 64, timeout):
            self.handle(ev)

    # -- signalling (r3 2.3, r4 3.3; repair H2: frozen after any uncertainty)
    def signal_verified(self, pid, sig, reason):
        if self.signals_frozen:
            raise Hold("refuse signal: signals are frozen after an uncertainty")
        self.drain(0)
        e = self.entries.get(pid)
        if e is None:
            if any(d["pid"] == pid for d in self.dead):
                return "already-exited"
            raise Hold("refuse signal: pid %d is not an owned entry" % pid)
        if e["exit"] is not None:
            return "already-exited"
        if not e["lineage"] or e["role"] not in ROLE_SIGNALLABLE:
            raise Hold("refuse signal: pid %d role %s lineage %s" % (pid, e["role"], e["lineage"]))
        cur = bsdinfo(pid)
        if cur is None:
            return "gone"
        if cur["birth_us"] != e["birth_us"] or cur["uid"] != me():
            raise Hold("refuse signal: pid %d identity changed (possible PID reuse)" % pid)
        os.kill(pid, sig)
        self.harness_signals.append({"t": now(), "pid": pid, "birth_us": e["birth_us"],
                                     "role": e["role"], "signal": int(sig), "reason": reason})
        self.dirty = True
        return "sent"

    def alive(self, role):
        return [e for e in self.entries.values() if e["role"] == role and e["exit"] is None]

    def wait_roles_gone(self, roles, deadline):
        while now() < deadline:
            self.drain(0.2)
            if not any(self.alive(r) for r in roles):
                return True
        return not any(self.alive(r) for r in roles)

    def wait_all_gone(self, deadline):
        while now() < deadline:
            self.drain(0.2)
            if not self.entries:
                return True
        return not self.entries

    def h_record(self):
        """The explicit H record (repair H1): every field is required by classify_epoch,
        which recomputes the verdict; unknown is never true."""
        kinds = [v["kind"] for v in self.violations]
        rec = {"closure_verified": bool(self.closure.get("closure_verified")),
               "closure_detail": self.closure.get("detail"),
               "image_violations": sum(1 for k in kinds if k in IMAGE_VIOLATIONS),
               "exec_unobserved": sum(1 for k in kinds if k.startswith("exec-image-")),
               "admission_unreadable_live": sum(1 for k in kinds
                                                if k == "admission-image-unreadable-live"),
               "proof": "source-fact+kernel-event"}
        clean = rec["closure_verified"] and rec["image_violations"] == 0 and \
            rec["exec_unobserved"] == 0 and rec["admission_unreadable_live"] == 0
        rec["api_client_history"] = "none-in-envelope" if clean else "unknown"
        rec["verdict"] = bool(clean)
        return rec

    def state(self):
        return {
            "inst": self.m.get("inst"), "t": now(), "wall": wall(),
            "live": list(self.entries.values()), "dead": self.dead,
            "events": self.events, "violations": self.violations, "gaps": self.gaps,
            "fork_notes": self.fork_notes, "marks": self.marks,
            "harness_signals": self.harness_signals, "signals_frozen": self.signals_frozen,
            "h": self.h_record(),
            "launcher_pid": self.launcher.pid if self.launcher else None,
            "launcher_identity": self.launcher_identity,
            "launcher_returncode": self.launcher.returncode if self.launcher else None,
            "launcher_reaped": self.launcher_reaped,
        }

    def flush(self):
        if self.dirty:
            jdump(self.state(), self.state_path)
            self.dirty = False


def ident(e):
    return {"pid": e["pid"], "birth_us": e["birth_us"], "role": e["role"]}


def supervise(m, ctl, state_path, launcher_path, epoch, seam_exit_before_register=False,
              post_stop_s=None):
    """Spawn the reviewed launcher with the exact envelope and watch its tree (repair H2).

    Spawn, registration and first admission run inside try/finally, so a state receipt is
    always written. A launcher that exits before registration completes is
    `launcher-unregistered` with its identity recorded as unknown. After a stop request or
    any uncertainty, the loop runs at most to a monotonic post-stop deadline, then writes
    the live identities and exits HOLD without signalling. A bounded exit is never proof
    that descendants or connections are gone; the barrier decides.

    `seam_exit_before_register` is a test-only seam (A2, T19a): it blocks, without reaping,
    until the spawned fixture has exited, so the registration step deterministically meets
    an exited launcher. Production callers never pass it."""
    os.makedirs(ctl, 0o700, exist_ok=True)
    w = Watch(m, state_path)
    w.closure = h_closure(m) if "evidence" in m else {"closure_verified": False,
                                                       "detail": "no evidence dir"}
    post_s = TIMEOUTS["barrier"] + 30 if post_stop_s is None else float(post_stop_s)
    stop_requested = held = False
    post_deadline = None
    exit_code = EXIT_OK
    try:
        out_base = m["evidence"] + "/" + epoch
        os.makedirs(out_base, 0o700, exist_ok=True)
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        fo = os.open(out_base + "/launcher.out", flags, 0o600)
        fe = os.open(out_base + "/launcher.err", flags, 0o600)
        try:
            w.launcher = subprocess.Popen([launcher_path], env=dict(m["launch_env"]),
                                          cwd=m["root"], stdin=subprocess.DEVNULL, stdout=fo,
                                          stderr=fe, close_fds=True, start_new_session=True)
        finally:
            os.close(fo)
            os.close(fe)
        lp = w.launcher.pid
        w.launcher_identity = {"pid": lp, "birth_us": None, "identity": "unknown"}
        w.dirty = True
        if seam_exit_before_register:
            os.waitid(os.P_PID, lp, os.WEXITED | os.WNOWAIT)
        registered = w.register(lp)
        exited = os.waitid(os.P_PID, lp, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        cur = bsdinfo(lp) if registered and not exited else None
        if not registered or exited or cur is None:
            w.violation("launcher-unregistered", pid=lp)
            raise Hold("launcher exited before registration completed")
        w.launcher_identity = {"pid": lp, "birth_us": cur["birth_us"], "identity": "kernel"}
        if w._add(lp, cur, "spawned", None, lineage=True, proof="kernel-event") is None:
            w.violation("launcher-unregistered", pid=lp)
            raise Hold("launcher not admitted")
        last_scan = last_trip = 0.0
        served = set()
        while True:
            try:
                w.drain(0.2)
                t = now()
                if t - last_scan > 0.2:
                    for pid in list(w.entries):
                        w.scan_children(pid, "periodic")
                    w.identify_postmaster()
                    w.refresh()
                    last_scan = t
                if t - last_trip > TRIPWIRE_PERIOD:
                    w.tripwire()
                    last_trip = t
            except Hold as h:
                w.violation("HOLD", detail=str(h))
                w.signals_frozen = held = True
            end_watch = False
            for name in sorted(os.listdir(ctl)):
                if not name.startswith("req-") or name in served:
                    continue
                served.add(name)
                req = jload(ctl + "/" + name)
                resp = serve(w, m, req)
                jdump(resp, ctl + "/resp-" + name[4:])
                if req.get("cmd") == "stop":
                    stop_requested = True
                    if not resp.get("ok"):
                        held = True
                if req.get("cmd") == "exit-watch":
                    end_watch = True
            if (stop_requested or held) and post_deadline is None:
                post_deadline = now() + post_s
            if w.launcher.poll() is not None and not w.entries:
                break
            if end_watch:
                w.violation("watch-ended-by-request", live=[ident(e) for e in w.entries.values()])
                held = True
                break
            if post_deadline is not None and now() > post_deadline:
                w.violation("watcher-exited-bounded", live=[ident(e) for e in w.entries.values()])
                held = True
                break
            w.flush()
    except Hold as h:
        w.violation("HOLD", detail=str(h))
        w.signals_frozen = held = True
    finally:
        if w.launcher is not None:
            try:
                w.launcher_reaped = {"returncode": w.launcher.wait(timeout=5)}
            except subprocess.TimeoutExpired:
                w.launcher_reaped = {"returncode": None, "state": "not-reaped-live"}
        for hp in w.helpers:
            try:
                hp.wait(timeout=5)
            except subprocess.TimeoutExpired:
                w.violation("helper-not-reaped", pid=hp.pid)
        w.dirty = True
        w.flush()
    if held:
        return EXIT_HOLD
    if not stop_requested:
        return EXIT_FAIL  # the tree ended without a deliberate stop
    return exit_code


def serve(w, m, req):
    cmd = req.get("cmd")
    if cmd == "status":
        return {"ok": True, "state": w.state()}
    if cmd == "mark":
        w.marks[req["label"]] = now()
        w.dirty = True
        return {"ok": True}
    if cmd == "stop":
        return stop_tree(w, m)
    if cmd == "exit-watch":
        return {"ok": True, "live": list(w.entries.values())}
    return {"ok": False, "error": "unknown cmd"}


STOP_STAGES = {"launcher": 30.0, "pc": 20.0, "dt": 20.0, "kill": 10.0, "pgctl": 90.0,
               "pgctl_t": 60, "overall": 300.0}


def stop_tree(w, m, stages=None):
    """Deliberate stop with verified escalation (r3 2.4; repair H2). Every stage result is
    checked against its own deadline and an absolute monotonic overall deadline. pg_ctl's
    exit status and timeout propagate. Any failure freezes signals and returns ok:false with
    the remaining identities; nothing more is signalled. A postmaster is never SIGKILLed.
    `stages` overrides the deadlines for the T19 subjects only."""
    st = dict(STOP_STAGES, **(stages or {}))
    t0 = now()
    overall = t0 + float(st["overall"])
    w.marks["stop_begin"] = t0
    log = []

    def until(sec):
        return min(now() + float(sec), overall)

    try:
        if w.signals_frozen:
            raise Hold("signals frozen before the stop began")
        log.append(("launcher-term", w.signal_verified(w.launcher.pid, signal.SIGTERM,
                                                       "deliberate-stop")))
        if not w.wait_roles_gone(("process-compose",), until(st["launcher"])):
            for e in w.alive("process-compose"):
                log.append(("pc-term", w.signal_verified(e["pid"], signal.SIGTERM, "escalate-pc")))
        if not w.wait_roles_gone(("devenv-tasks",), until(st["pc"])):
            for e in w.alive("devenv-tasks"):
                log.append(("dt-term", w.signal_verified(e["pid"], signal.SIGTERM, "escalate-dt")))
        managers = ("process-compose", "devenv-tasks")
        if not w.wait_roles_gone(managers, until(st["dt"])):
            for r in managers:
                for e in w.alive(r):
                    log.append(("kill", w.signal_verified(e["pid"], signal.SIGKILL,
                                                          "escalate-kill")))
            if not w.wait_roles_gone(managers, until(st["kill"])):
                raise Hold("manager processes alive after KILL stage")
        pms = w.alive("postmaster-final") + w.alive("postmaster-init") + \
            w.alive("postmaster-identified")
        if pms:
            rc = pg_ctl_stop(w, m, pms, timeout=max(0.0, min(float(st["pgctl"]),
                                                              overall - now())),
                             t=int(st["pgctl_t"]))
            log.append(("pg_ctl", rc))
            if rc != 0:
                raise Hold("pg_ctl stop failed: %r" % (rc,))
        if not w.wait_all_gone(overall):
            raise Hold("owned processes live after all stop stages")
        return {"ok": True, "stages": log, "remaining": [],
                "harness_signals": w.harness_signals}
    except Hold as h:
        w.signals_frozen = True
        w.violation("HOLD", detail=str(h))
        return {"ok": False, "hold": str(h), "stages": log,
                "remaining": [ident(e) for e in w.entries.values()],
                "harness_signals": w.harness_signals}


def pg_ctl_stop(w, m, pms, timeout=90.0, t=60):
    """The only postmaster stop path: pg_ctl -D <pgdata>, after identity proof. Returns
    pg_ctl's exit status, or "timeout" (the helper is kept for a bounded reap, not killed)."""
    with open(m["pgdata"] + "/postmaster.pid") as f:
        lines = f.read().splitlines()
    pid = int(lines[0])
    match = [e for e in pms if e["pid"] == pid]
    if not match:
        raise Hold("postmaster.pid names %d, not a tracked postmaster" % pid)
    cur = bsdinfo(pid)
    if cur is None or cur["birth_us"] != match[0]["birth_us"]:
        raise Hold("postmaster identity changed")
    if proc_cwd(pid) != os.path.realpath(m["pgdata"]):
        raise Hold("postmaster cwd mismatch")
    env = {"PATH": PG_BIN, "PGDATA": m["pgdata"], "LC_ALL": "C"}
    p = subprocess.Popen([PG_BIN + "/pg_ctl", "-D", m["pgdata"], "-m", "fast", "-w", "-t", str(t),
                          "stop"], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, close_fds=True)
    try:
        rc = p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        w.helpers.append(p)
        rc = "timeout"
    w.harness_signals.append({"t": now(), "pid": pid, "birth_us": match[0]["birth_us"],
                              "role": "postmaster", "signal": "pg_ctl-fast", "rc": rc,
                              "reason": "pg_ctl-stop"})
    w.dirty = True
    return rc


def ctl_request(ctl, cmd, timeout, **kw):
    n = "%d-%s" % (int(now() * 1000), secrets.token_hex(4))
    req = dict(kw, cmd=cmd)
    jdump(req, ctl + "/req-" + n + ".json.part")
    os.replace(ctl + "/req-" + n + ".json.part", ctl + "/req-" + n + ".json")
    deadline = now() + timeout
    resp = ctl + "/resp-" + n + ".json"
    while now() < deadline:
        if os.path.exists(resp):
            return jload(resp)
        time.sleep(0.1)
    raise Hold("no watcher response to %s" % cmd)


# ---------------------------------------------------------------- readiness, listener, drain
def postmaster_pid_status(m):
    try:
        with open(m["pgdata"] + "/postmaster.pid") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return None, None, None
    pid = int(lines[0]) if lines and lines[0].isdigit() else None
    status = lines[7].strip() if len(lines) >= 8 else None
    listen = lines[5] if len(lines) >= 6 else None
    return pid, status, listen


def final_postmaster(state):
    pms = [e for e in state["live"] if e["role"] == "postmaster-final"]
    return pms[0] if len(pms) == 1 else None


def listener_proof(m, state):
    """r3 1.3 + r4 4.1: exactly one 127.0.0.1 listener owned by the verified final postmaster."""
    pm = final_postmaster(state)
    if pm is None:
        raise Hold("no unique final postmaster")
    cur = bsdinfo(pm["pid"])
    if cur is None or cur["birth_us"] != pm["birth_us"]:
        raise Hold("final postmaster identity changed")
    recs = tcp_listeners(m["port"])
    want = "127.0.0.1:%d" % m["port"]
    if len(recs) != 1 or recs[0]["addr"] != want or recs[0]["pid"] != pm["pid"]:
        raise Hold("FOREIGN-LISTENER or unexpected listeners: %r" % recs)
    ns = netstat_listen(m["port"])
    if ns != ["127.0.0.1.%d" % m["port"]]:
        raise Hold("netstat disagrees with lsof: %r" % ns)
    sock = m["pg_socket"]
    if socket_rec(sock).get("type") != "socket":
        raise Hold("pg UDS missing")
    with open(sock + ".lock") as f:
        lock_pid = f.readline().strip()
    if lock_pid != str(pm["pid"]):
        raise Hold("UDS lock names %s" % lock_pid)
    rc, out, err = run(["/usr/sbin/lsof", "-n", "-P", "-F", "p", "--", sock], env=TOOL_ENV)
    holders = sorted({int(l[1:]) for l in out.splitlines() if l.startswith("p")})
    if pm["pid"] not in holders:
        raise Hold("UDS not held by postmaster: %r" % holders)
    pid, status, _ = postmaster_pid_status(m)
    if pid != pm["pid"] or status != "ready":
        raise Hold("postmaster.pid not ready/consistent: %r %r" % (pid, status))
    return {"pid": pm["pid"], "birth_us": pm["birth_us"], "t": now()}


def ready_wait(m, state_path, deadline_s):
    deadline = now() + deadline_s
    last = None
    while now() < deadline:
        try:
            state = jload(state_path)
        except (FileNotFoundError, ValueError):
            time.sleep(0.5)
            continue
        if state["violations"]:
            raise Hold("watcher violations: %r" % state["violations"][:3])
        bad = [e for e in state["dead"] if e["role"] in ("postmaster-init", "postmaster-final")
               and not (e["exit"].get("kind") == "exited" and e["exit"].get("code") == 0)]
        if bad:
            # repair H3 (T6): a startup FATAL is an OBSERVED non-zero postmaster exit with no
            # ready postmaster; a timeout without an observed exit is FAIL-TIMEOUT, never this
            raise Fail("FAIL-START postmaster exit %r" % [(e["pid"], e["role"], e["exit"])
                                                          for e in bad])
        if os.path.exists(m["pgdata"] + "/.devenv_initialized"):
            try:
                return listener_proof(m, state)
            except Hold as h:
                last = str(h)
                if "FOREIGN" in last:
                    raise
        time.sleep(0.5)
    raise Fail("FAIL-TIMEOUT readiness (%s)" % last)


def drain_check(m, state_path, deadline_s):
    deadline = now() + deadline_s
    while now() < deadline:
        state = jload(state_path)
        pm = final_postmaster(state)
        if pm is None:
            raise Hold("no final postmaster for drain check")
        backends = [p for p in child_pids(pm["pid"]) if BACKEND_RE.match(proc_args(p) or "")]
        if not backends:
            return True
        time.sleep(0.5)
    raise Hold("backends still connected after drain deadline")


def barrier(m, state_path, deadline_s):
    """r2 8.2 step 3: owned identities gone, no listener, no sockets in use, no handles."""
    deadline = now() + deadline_s
    why = None
    while now() < deadline:
        state = jload(state_path)
        why = None
        for e in state["live"]:
            cur = bsdinfo(e["pid"])
            if cur is not None and cur["birth_us"] == e["birth_us"]:
                why = "owned pid %d (%s) alive" % (e["pid"], e["role"])
                break
        if why is None and tcp_listeners(m["port"]):
            why = "listener on port"
        if why is None and os.path.lexists(m["pg_socket"]):
            why = "pg socket present"
        if why is None:
            for top in (m["root"], m["runtime_canonical"]):
                if os.path.lexists(top):
                    pids = open_handles_under(top)
                    if pids:
                        why = "open handles under %s: %r" % (top, pids)
                        break
        if why is None:
            return {"ok": True, "t": now()}
        time.sleep(1)
    raise Hold("FAIL-UNCERTAIN barrier: %s" % why)


# ---------------------------------------------------------------- lockout (r5 3.5, r6 1.3)
def lockout(m):
    rec = {}
    for s in (m["pc_socket"], m["native_socket"]):
        r = socket_rec(s)
        if not r.get("present") or r["type"] != "socket" or r["uid"] != me():
            raise Hold("lockout: %s is not an owned socket: %r" % (s, r))
        os.chmod(s, 0)
        r2 = socket_rec(s)
        if (r2["dev"], r2["ino"]) != (r["dev"], r["ino"]) or r2["mode"] != 0:
            raise Hold("lockout: %s changed during chmod" % s)
        rec[s] = r2
    return {"t": now(), "sockets": rec}


def check_eacces(path):
    c = socket.socket(socket.AF_UNIX)
    try:
        c.connect(path)
        return "connected"
    except OSError as e:
        return "errno-%d" % e.errno
    finally:
        c.close()


# ---------------------------------------------------------------- epoch classification
ALLOWED_EXIT = {
    # r5 2.2 (with r6 Q2 amendment); role -> predicate on decoded status
    "process-compose": lambda s: s.get("kind") == "exited" and s.get("code") == 0,
    "postmaster-final": lambda s: s.get("kind") == "exited" and s.get("code") == 0,
    "pg-logger": lambda s: s.get("kind") == "exited" and s.get("code") == 0,
    "pg-aux": lambda s: s.get("kind") == "exited" and s.get("code") in (0, 1),
    "pg-backend": lambda s: s.get("kind") == "exited" and s.get("code") in (0, 1),
    "wrapper": lambda s: s.get("kind") == "exited" or (
        s.get("kind") == "signaled" and s.get("signal") == signal.SIGTERM),
    "start-postgres": lambda s: s.get("kind") == "exited" or (
        s.get("kind") == "signaled" and s.get("signal") == signal.SIGTERM),
    "launcher": lambda s: s.get("kind") == "exited",
}
SINGLETONS = ("process-compose", "devenv-tasks", "postmaster-final", "pg-logger")


def h_reasons(h, violations, closure_ok):
    """Validate the H record (repair H1): every field present with its exact type, the
    counts consistent with the recorded violations, closure_verified equal to the closure
    recomputed from the files now, and the stored verdict equal to the recomputed one.
    Missing, malformed or inconsistent is INCOMPLETE; unknown is never true."""
    if not isinstance(h, dict):
        return ["H: record missing"]
    out = []
    for k, t in sorted(H_FIELDS.items()):
        if k not in h:
            out.append("H: field %s missing" % k)
        elif type(h[k]) is not t:
            out.append("H: field %s has type %s" % (k, type(h[k]).__name__))
    if out:
        return out
    kinds = [v.get("kind", "") for v in violations]
    want = {"image_violations": sum(1 for k in kinds if k in IMAGE_VIOLATIONS),
            "exec_unobserved": sum(1 for k in kinds if k.startswith("exec-image-")),
            "admission_unreadable_live": sum(1 for k in kinds
                                             if k == "admission-image-unreadable-live")}
    for k, v in sorted(want.items()):
        if h[k] != v:
            out.append("H: %s=%d inconsistent with recorded violations (%d)" % (k, h[k], v))
    if h["closure_verified"] is not bool(closure_ok):
        out.append("H: closure_verified inconsistent with the recomputed closure")
    clean = bool(closure_ok) and all(v == 0 for v in want.values())
    if h["api_client_history"] != ("none-in-envelope" if clean else "unknown"):
        out.append("H: api_client_history inconsistent")
    if h["verdict"] is not clean:
        out.append("H: stored verdict inconsistent with its components")
    if not clean:
        out.append("H: not established")
    return out


def live_at(all_e, pid, t):
    """The entry for pid that was alive at monotonic time t (pid reuse safe)."""
    for e in all_e:
        if e["pid"] == pid and e["admitted"] <= t and (e["exit"] is None or e["exit"]["t"] >= t):
            return e
    return None


def classify_epoch(state, snaps, lock, barrier_ok, closure_ok):
    """Pure function over recorded facts (r5 2-3, r6, R6-1; repair H1, H4, D-9).
    Returns {"complete", "reasons", "init_facts", "window"}.

    Singleton checks bind to the WINDOW generation of each required role: the unique
    (pid, birth) entry admitted before SNAP-0 that did not exit before the deliberate stop.
    Generations that exited before SNAP-0 (the init server's postmaster and logger) are
    reported as init facts, not judged. A required-role generation admitted inside the
    window is a replacement: INCOMPLETE."""
    reasons, init_facts = [], []
    live, dead = state.get("live", []), state.get("dead", [])
    all_e = live + dead
    t0 = snaps["SNAP-0"]["t"]
    t_post = snaps["SNAP-post"]["t"]
    t_stop = state.get("marks", {}).get("stop_begin")
    if t_stop is None:
        reasons.append("no deliberate stop recorded")
        t_stop = float("inf")
    if state.get("violations"):
        reasons.append("watcher violations: %d" % len(state["violations"]))
    if live:
        reasons.append("owned processes still live at classification")
    if not barrier_ok:
        reasons.append("barrier not established")
    window = {}
    for r in SINGLETONS:
        gens = [e for e in all_e if e["role"] == r]
        spanning = [e for e in gens if e["admitted"] < t0 and
                    (e["exit"] is None or e["exit"]["t"] >= t_stop)]
        for e in gens:
            if e["admitted"] < t0 and e["exit"] is not None and e["exit"]["t"] < t0:
                init_facts.append({"role": r, "pid": e["pid"], "birth_us": e["birth_us"],
                                   "exit": e["exit"]})
            elif e["admitted"] < t0 and e["exit"] is not None and t0 <= e["exit"]["t"] < t_stop:
                reasons.append("singleton %s exited in the window before the stop" % r)
            elif t0 <= e["admitted"] <= t_post:
                reasons.append("singleton %s: replacement generation in window" % r)
        if len(spanning) != 1:
            reasons.append("singleton %s: %d window generations" % (r, len(spanning)))
        else:
            window[r] = spanning[0]
    pm, lg = window.get("postmaster-final"), window.get("pg-logger")
    if pm and lg:
        if (lg.get("parent"), lg.get("parent_birth_us")) != (pm["pid"], pm["birth_us"]):
            reasons.append("window logger is not a child of the window postmaster")
        elif pm["exit"] and lg["exit"] and lg["exit"]["t"] < pm["exit"]["t"]:
            reasons.append("window logger exited before the window postmaster")
    signalled = sorted({s["role"] for s in state.get("harness_signals", [])
                        if s.get("reason") != "deliberate-stop"})
    if signalled:
        reasons.append("harness escalation used: %r" % signalled)
    for e in all_e:
        st = e["exit"]
        if st is None or st["t"] < t0:
            continue
        r = e["role"]
        if r == "devenv-tasks":
            ok = devenv_tasks_eligible(e, window, signalled)
        elif r in ALLOWED_EXIT:
            ok = ALLOWED_EXIT[r](st)
        else:
            ok = st.get("kind") == "exited" or (st.get("kind") == "signaled" and
                                                st.get("signal") == signal.SIGTERM)
        if not ok:
            reasons.append("disallowed exit %s pid %d %r" % (r, e["pid"], st.get("kind")))
        if st.get("kind") == "signaled" and st.get("signal") in (
                signal.SIGSEGV, signal.SIGABRT, signal.SIGBUS, signal.SIGILL):
            reasons.append("crash signal %s (OS crash report residual)" % r)
    pc = window.get("process-compose")
    lp = state.get("launcher_pid")
    if pc:
        for ev in state.get("events", []):
            if ev["t"] <= pc["admitted"]:
                continue
            if ev["ev"] == "fork-note" and ev["pid"] == lp:
                reasons.append("launcher forked after process-compose admission")
                break
            if ev["ev"] == "admit":
                x = live_at(all_e, ev["pid"], ev["t"])
                if x is not None and x.get("parent") == lp:
                    reasons.append("launcher child admitted after process-compose admission")
                    break
    if any(p.endswith("/postmaster.pid") for p in snaps["SNAP-post"]["files"]):
        reasons.append("stale or new postmaster.pid at SNAP-post (conservative INCOMPLETE)")
    for n in ("SNAP-pre", "SNAP-post"):
        for v in snaps[n].get("violations", []):
            reasons.append("%s: %s %s" % (n, v[0], v[1]))
    reasons.extend(socket_lifecycle(lock, snaps, barrier_ok, reasons))
    for ev in state.get("events", []):
        if ev["ev"] == "fork-note" and t0 <= ev["t"] <= t_post:
            x = live_at(all_e, ev["pid"], ev["t"])
            r = x["role"] if x else None
            if r not in FORK_COVERED_ROLES:
                reasons.append("fork in window by role %s without source-gated attribution" % r)
    hr = h_reasons(state.get("h"), state.get("violations", []), closure_ok)
    reasons.extend(hr)
    reasons.extend(gate_b(not hr, lock))
    return {"complete": not reasons, "reasons": reasons, "init_facts": init_facts,
            "window": {r: ident(e) for r, e in window.items()}}


# Roles whose forks are covered by the r5 3.2 exit-gated singleton-writer argument.
FORK_COVERED_ROLES = ("process-compose", "devenv-tasks", "wrapper", "start-postgres",
                      "setup-postgres", "postmaster-final", "pg-aux", "pg-backend", "pg-logger",
                      "shell", "pg-tool")


def gate_b(h_ok, lock):
    """r6 1.4: gate (b) holds only if H (no API client history) and F (lockout) both hold.
    EACCES on a later connect never stands in for H."""
    out = []
    if not h_ok:
        out.append("gate-b: H not established")
    if lock is None:
        out.append("gate-b: no lockout (F)")
    return out


def producer_exit_eligible(binding, status):
    """r5 2.3 (T15d): exit status allows an absence verdict only for a role whose
    source-traced graceful path is bound to that status; never for an unbound role."""
    if binding == "source-traced-graceful-exit0":
        return status.get("kind") == "exited" and status.get("code") == 0
    return False


def devenv_tasks_eligible(e, window, signalled):
    """r5 2.2 row 2 (r6 Q2; repair H4): signaled(SIGINT) only under (i)-(iii) on the WINDOW
    generations; (iv) is a source precondition, not a measured signal count."""
    st = e["exit"]
    if not (st.get("kind") == "signaled" and st.get("signal") == signal.SIGINT):
        return False
    if "devenv-tasks" in signalled:
        return False
    if window.get("devenv-tasks") is None or \
            (window["devenv-tasks"]["pid"], window["devenv-tasks"]["birth_us"]) != \
            (e["pid"], e["birth_us"]):
        return False
    t = st["t"]
    for r in ("postmaster-final", "pg-logger"):
        x = window.get(r)
        if x is None or x["exit"] is None or x["exit"]["t"] > t:
            return False
    pc = window.get("process-compose")
    if pc is None or pc["exit"] is None or pc["exit"]["t"] < t or \
            not ALLOWED_EXIT["process-compose"](pc["exit"]):
        return False
    return True


def socket_outcomes(lock, snaps):
    """Per-socket SNAP-post outcome, recorded explicitly (R6-1)."""
    res = {}
    for s in (lock or {}).get("sockets", {}):
        post = snaps["SNAP-post"]["sockets"].get(s, {"present": False})
        res[s] = "present-retained" if post.get("present") else "unlinked"
    return res


def socket_lifecycle(lock, snaps, barrier_ok, prior_reasons):
    """R6-1: identity at SNAP-0/pre; per-role graceful unlink classification at SNAP-post."""
    out = []
    if lock is None:
        return []
    for s, lr in lock["sockets"].items():
        for n in ("SNAP-0", "SNAP-pre"):
            r = snaps[n]["sockets"].get(s, {"present": False})
            if not r.get("present"):
                out.append("%s missing at %s (pre-stop disappearance)" % (s, n))
            elif (r["dev"], r["ino"], r["type"], r["mode"]) != (lr["dev"], lr["ino"], "socket", 0):
                out.append("%s identity/mode drift at %s" % (s, n))
        post = snaps["SNAP-post"]["sockets"].get(s, {"present": False})
        if post.get("present"):
            if (post["dev"], post["ino"], post["type"], post["mode"]) != (lr["dev"], lr["ino"],
                                                                           "socket", 0):
                out.append("%s replaced or permission drift at SNAP-post" % s)
        else:
            # graceful unlink acceptable only with the orderly barrier and no other defect
            if not barrier_ok:
                out.append("%s unlinked without orderly barrier" % s)
    return out


# ---------------------------------------------------------------- markers
def markers_new(inst, epoch):
    m = {}
    for k in ("S_u", "S_c", "L", "E", "Q", "T", "D", "F"):
        m[k] = secrets.token_hex(16)
    m["M_u"] = hashlib.md5(m["S_u"].encode()).hexdigest()
    m["M_c"] = hashlib.md5(m["S_c"].encode()).hexdigest()
    return {"inst": inst, "epoch": epoch, "markers": m}


# ---------------------------------------------------------------- oracles (r2 7.3, r3 6)
P_EXPECT = ("M_u", "S_u", "M_c", "S_c", "L", "E", "Q", "T", "D", "F")


def judge(kind, counts, own, complete):
    """counts: this epoch's SNAP-post rows; own: this epoch's marker labels. Every kind
    requires a complete classification (repair H4): a P or A with the right counts but an
    INCOMPLETE epoch fails."""
    by = {}
    for c in counts:
        by.setdefault(c["marker"], []).append(c)
    result = {"kind": kind, "complete": complete, "failures": []}
    if not complete:
        result["failures"].append("%s: epoch INCOMPLETE" % kind)
    if kind == "P":
        for k in P_EXPECT:
            coll = sum(c["count"] for c in by.get(k, []) if c["class"] == "collector-sink")
            if coll <= 0:
                result["failures"].append("P: %s has no collector count" % k)
    elif kind == "B":
        for k in PRIMARY_KINDS:
            coll = sum(c["count"] for c in by.get(k, []) if c["class"] == "collector-sink")
            other = sum(c["count"] for c in by.get(k, []) if c["class"] != "collector-sink")
            if coll <= 0:
                result["failures"].append("B: primary %s has no collector count" % k)
            if other:
                result["failures"].append("B: primary %s outside collector: %d" % (k, other))
        if complete:
            for k in MARKER_KINDS:
                if k in PRIMARY_KINDS:
                    continue
                n = sum(c["count"] for c in by.get(k, []))
                if n:
                    result["failures"].append("B: %s present (%d)" % (k, n))
        else:
            result["failures"].append("B: no absence verdict on an INCOMPLETE epoch")
    result["pass"] = not result["failures"]
    return result


def q2_forwarding_check(counts):
    """r6 Q2 / R6-1 Q2: a marker only in a manager log (not in any original) invalidates."""
    mgr = ("manager-aggregate-sink", "manager-internal-log")
    orig = ("per-process-sink", "collector-sink")
    by = {}
    for c in counts:
        by.setdefault(c["marker"], {"mgr": 0, "orig": 0})
        if c["class"] in mgr:
            by[c["marker"]]["mgr"] += c["count"]
        if c["class"] in orig:
            by[c["marker"]]["orig"] += c["count"]
    bad = [k for k, v in by.items() if v["mgr"] > 0 and v["orig"] == 0]
    return {"invalid_premise": bool(bad), "markers": bad}


# ---------------------------------------------------------------- cleanup (r2 8.3)
def cleanup(m, claim_path):
    """Success cleanup of exact validated roots; any failure stops and reports."""
    claim = jload(claim_path) if os.path.exists(claim_path) else None
    targets = [(m["root"], m["root_lstat"])]
    if claim:
        targets.append((m["runtime"], claim["lstat"]))
    remaining = []
    for path, rec in targets:
        if not os.path.lexists(path):
            continue
        cur = lstat_rec(path)
        if cur["type"] != "dir" or (cur["dev"], cur["ino"], cur["uid"]) != (rec["dev"], rec["ino"],
                                                                            rec["uid"]):
            raise Hold("cleanup: %s identity changed" % path)
        canon = os.path.realpath(path)
        if path == m["runtime"] and canon != m["runtime_canonical"]:
            raise Hold("cleanup: runtime canonical mismatch")
        if path == m["root"] and canon != m["root"]:
            raise Hold("cleanup: root canonical mismatch")
        if open_handles_under(canon):
            raise Hold("cleanup: open handles under %s" % canon)
        rc, _, err = run(["/bin/rm", "-rf", "--", canon], env=TOOL_ENV, timeout=300)
        if rc != 0 or os.path.lexists(canon):
            remaining.append(canon)
    if remaining:
        raise Fail("FAIL-CLEANUP remaining %r" % remaining)
    return {"ok": True}


# ---------------------------------------------------------------- copy, eval, perturb
COPY_FILES = ("flake.nix", "flake.lock", "devenv.nix", "priv/postgres/log_settings.json")
NEW_KEYS_ALLOWED = {"S-T7": ("hot_standby",)}


def edit_copy(m):
    """Apply exactly the reviewed edits to the archived copy (r2 6.3); record the diff."""
    import difflib
    root, kind = m["root"], m["kind"]
    rec = {"edits": []}
    if kind == "R":
        jdump(rec, m["evidence"] + "/copy-edits.json")
        return rec
    dn = root + "/devenv.nix"
    text = read_text(dn)
    if text.count("port = 5520;") != 1:
        raise Refuse("devenv.nix: expected exactly one 'port = 5520;'")
    new = text.replace("port = 5520;", "port = %d;" % m["port"])
    rec["edits"].append({"file": "devenv.nix", "diff": list(difflib.unified_diff(
        text.splitlines(), new.splitlines(), lineterm="", n=0))})
    with open(dn, "w") as f:
        f.write(new)
    edits = m["edits"] or {}
    if edits:
        jp = root + "/priv/postgres/log_settings.json"
        old_text = read_text(jp)
        obj = json.loads(old_text)
        for k, v in edits.items():
            if k not in obj and k not in NEW_KEYS_ALLOWED.get(kind, ()):
                raise Refuse("edit key %s not in the contract JSON" % k)
            obj[k] = v
        new_text = json.dumps(obj, indent=2, sort_keys=True) + "\n"
        rec["edits"].append({"file": "log_settings.json", "diff": list(difflib.unified_diff(
            json.dumps(json.loads(old_text), indent=2, sort_keys=True).splitlines(),
            new_text.splitlines(), lineterm="", n=0))})
        with open(jp, "w") as f:
            f.write(new_text)
    jdump(rec, m["evidence"] + "/copy-edits.json")
    return rec


def eval_check(m, eval_json_path):
    """r2 4.2: the copy's evaluated config.env equals the manifest's derived values."""
    e = jload(eval_json_path)
    want = {"PGDATA": m["pgdata"], "PGHOST": "127.0.0.1", "PGPORT": str(m["port"]),
            "PC_SOCKET_PATH": m["pc_socket"], "DEVENV_ROOT": m["root"],
            "DEVENV_DOTFILE": m["dotfile"], "DEVENV_STATE": m["state"],
            "DEVENV_RUNTIME": m["runtime"]}
    bad = {k: (str(e.get(k)), v) for k, v in want.items() if str(e.get(k)) != v}
    if bad:
        raise Refuse("REFUSE-PROVENANCE eval mismatch %r" % bad)
    return {"ok": True}


def perturb(m, out, sets):
    """Self-test only (T5, T13): a manifest variant with one field changed."""
    m2 = json.loads(json.dumps(m))
    for item in sets:
        k, _, v = item.partition("=")
        if k.startswith("launch_env."):
            m2["launch_env"][k.split(".", 1)[1]] = v
        elif k == "port":
            m2["port"] = int(v)
        else:
            m2[k] = v
    jdump(m2, out)
    return {"ok": True, "out": out}


def field(m, key):
    v = m
    for part in key.split("."):
        v = v[part]
    sys.stdout.write(str(v) + "\n")


# ---------------------------------------------------------------- S5 (r2 10 as amended by r3 5.5, r4 3.2)
def move_collector(m, dest):
    """Move the counted collector dir out and create a fresh, empty, unwritable one."""
    src = m["pgdata"] + "/log"
    rec = lstat_rec(src)
    if rec["type"] != "dir" or rec["uid"] != me():
        raise Hold("collector dir not an owned dir")
    if os.path.lexists(dest):
        raise Hold("destination exists")
    try:
        os.rename(src, dest)
    except OSError as e:
        raise Hold("rename failed errno %d" % e.errno)
    os.mkdir(src, 0o700)
    os.chmod(src, 0o500)
    r2 = lstat_rec(src)
    if os.listdir(src) or r2["mode"] != 0o500:
        raise Hold("fresh collector dir not empty/0500")
    return {"moved_to": dest, "fresh": r2}


def restore_collector(m):
    src = m["pgdata"] + "/log"
    os.chmod(src, 0o700)
    return {"mode": oct(lstat_rec(src)["mode"]), "entries": len(os.listdir(src))}


def s5_observe(m, state_path, deadline_s):
    """Observe generations, listeners and UDS without any connect attempt."""
    deadline = now() + deadline_s
    seen_listeners, uds_seen, accepting = set(), False, None
    while now() < deadline:
        try:
            state = jload(state_path)
        except (FileNotFoundError, ValueError):
            time.sleep(0.2)
            continue
        for r in tcp_listeners(m["port"]):
            seen_listeners.add((r["pid"], r["addr"]))
        if os.path.lexists(m["pg_socket"]):
            uds_seen = True
        try:
            accepting = listener_proof(m, state)
            break
        except Hold:
            pass
        time.sleep(0.2)
    state = jload(state_path)
    gens = [{"pid": e["pid"], "role": e["role"], "birth_us": e["birth_us"], "exit": e["exit"]}
            for e in state["live"] + state["dead"] if e["role"].startswith("postmaster")]
    notes = [ev for ev in state["events"] if ev["ev"] == "fork-note"]
    return {"accepting": accepting, "observed_generations": gens,
            "listeners_seen": sorted(seen_listeners), "uds_seen": uds_seen,
            "fork_notifications": len(notes), "gaps": state["gaps"],
            "coverage": "possible-gap" if notes else "no-notifications",
            "collector_dir_entries": len(os.listdir(m["pgdata"] + "/log"))}


# ---------------------------------------------------------------- cross-instance (r2 7.1)
def cross_check(entries, marker_files):
    """entries: [(snapshot_dir, inst)]. Foreign-instance markers must be zero everywhere;
    a B epoch's non-primary markers must be zero in every B snapshot."""
    markers = {}
    for f in marker_files:
        d = jload(f)
        for k, v in d["markers"].items():
            markers["%s/%s/%s" % (d["inst"], d["epoch"], k)] = v
    failures, rows = [], []
    for snap_dir, inst in entries:
        for c in count_markers(snap_dir, markers):
            m_inst, _, kind = c["marker"].split("/")
            rows.append(dict(c, snapshot=snap_dir))
            if not c["count"]:
                continue
            if m_inst != inst:
                failures.append("foreign %s in %s (%s)" % (c["marker"], snap_dir, c["class"]))
            elif inst == "B" and kind not in PRIMARY_KINDS:
                failures.append("B absence marker %s in %s" % (c["marker"], snap_dir))
            elif inst == "B" and c["class"] != "collector-sink":
                failures.append("B primary %s outside collector in %s" % (c["marker"], snap_dir))
    return {"pass": not failures, "failures": failures, "rows": rows}


# ---------------------------------------------------------------- report (count-only)
def report(evid, head):
    """Aggregate the private evidence into a count-only report (r2 12, r3 6)."""
    rep_ = {"head": head, "evidence": evid, "instances": {}, "residuals": [
        "UNVERIFIED: init-only collector failure not exercised (keeps 5b open; r3 3.3)",
        "UNVERIFIED: forced-failure attempts whose output was truncated (keeps 5b open; r4 3.2)",
        "foreign same-uid API interference is outside the claim (r6 1.2)",
        "launch envelope limited: PGHOST=<runtime>/postgres, HOME/TMPDIR owned, API sockets "
        "locked during marker epochs (r3 3.1, r5 3.5, r6 1.4)",
        "non-atomic PID-based signalling window (r4 3.3)",
        "possible OS crash report outside roots on a crash signal (r4 2.3, W12)"]}
    for inst in sorted(os.listdir(evid)):
        idir = evid + "/" + inst
        if not os.path.isfile(idir + "/manifest.json"):
            continue
        ent = {"epochs": {}}
        for f in ("provenance.json", "copy-edits.json"):
            if os.path.exists(idir + "/" + f):
                ent[f.split(".")[0]] = jload(idir + "/" + f)
        if os.path.exists(idir + "/artifacts.json"):
            a = jload(idir + "/artifacts.json")
            ent["artifacts"] = a["files"]
            ent["package_refs"] = a["package_refs"]
        for ep in sorted(os.listdir(idir)):
            ed = idir + "/" + ep
            if not os.path.isdir(ed) or ep.startswith(("SNAP-", "collector")):
                continue
            e = {}
            for f in ("classification.json", "judge.json", "s5.json", "barrier.json"):
                if os.path.exists(ed + "/" + f):
                    e[f.split(".")[0]] = jload(ed + "/" + f)
            if os.path.exists(ed + "/counts.json"):
                e["nonzero_counts"] = [c for c in jload(ed + "/counts.json") if c["count"]]
            if e:
                ent["epochs"][ep] = e
        rep_["instances"][inst] = ent
    if os.path.exists(evid + "/cross-check.json"):
        cc = jload(evid + "/cross-check.json")
        rep_["cross_check"] = {"pass": cc["pass"], "failures": cc["failures"]}
    jdump(rep_, evid + "/report.json")
    lines = ["# 5b sink test report (count-only)", "", "head: %s" % head, ""]
    for inst, ent in sorted(rep_["instances"].items()):
        lines.append("## %s" % inst)
        for ep, e in sorted(ent["epochs"].items()):
            c = e.get("classification", {})
            j = e.get("judge", {})
            lines.append("- %s: complete=%s judge_pass=%s reasons=%d failures=%d" % (
                ep, c.get("complete"), j.get("pass"), len(c.get("reasons", [])),
                len(j.get("failures", []))))
        lines.append("")
    lines.append("## Residuals")
    lines.extend("- " + r for r in rep_["residuals"])
    fd = os.open(evid + "/report.md", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    return rep_


# ---------------------------------------------------------------- CLI
def parse_kv(argv):
    out, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if not a.startswith("--"):
            raise SystemExit(EXIT_USAGE)
        k = a[2:].replace("-", "_")
        if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
            out[k] = argv[i + 1]
            i += 2
        else:
            out[k] = True
            i += 1
    return out


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return EXIT_USAGE
    cmd, a = argv[0], parse_kv(argv[1:])
    try:
        if cmd == "plan":
            jdump({"packages": PKG, "env_keys": ENV_KEYS, "env_absent": ENV_MUST_BE_ABSENT,
                   "edits": EDITS, "db_allow": DB_ALLOW, "markers": MARKER_KINDS,
                   "timeouts": TIMEOUTS, "exec_allow": EXEC_ALLOW_PREFIXES,
                   "port_range": PORT_RANGE, "forbidden_ports": sorted(FORBIDDEN_PORTS),
                   "runtime_rule": "/tmp/devenv-<sha256(<root>/.devenv)[0:7]>",
                   "pghost_deviation": "<runtime>/postgres (r3 1.2)"})
            return EXIT_OK
        if cmd == "jget":
            v = json.load(sys.stdin) if a["file"] == "-" else jload(a["file"])
            for part in a["key"].split("."):
                v = v[int(part)] if isinstance(v, list) else v[part]
            sys.stdout.write(str(v) + "\n")
            return EXIT_OK
        if cmd == "report":
            report(a["evid"], a["head"])
            return EXIT_OK
        if cmd == "mono":
            # repair H2/A1: the shell's bounded waits use this monotonic clock
            plus = float(a.get("plus", 0))
            sys.stdout.write("%.6f\n" % (now() + plus))
            return EXIT_OK
        if cmd == "mono-before":
            return EXIT_OK if now() < float(a["deadline"]) else EXIT_HOLD
        if cmd == "runtime-for":
            jdump(dict(zip(("runtime", "canonical"), runtime_for_root(a["root"]))))
            return EXIT_OK
        if cmd == "manifest-new":
            if "port" in a:
                a["port"] = int(a["port"])
            return manifest_new(a)
        m = load_manifest(a["manifest"]) if "manifest" in a else None
        if cmd == "claim-runtime":
            jdump(claim_runtime(m))
        elif cmd == "recheck-runtime":
            jdump(recheck_runtime(m))
        elif cmd == "artifacts":
            art = artifacts(m, a["launcher"])
            jdump(art, m["evidence"] + "/artifacts.json")
            problems = []
            if "reference" in a:
                problems = provenance_check(m, art, jload(a["reference"]))
            if "expected_contract" in a:
                problems += contract_check(m, art, a["expected_contract"])
            jdump({"problems": problems}, m["evidence"] + "/provenance.json")
            if problems:
                jdump({"problems": problems})
                sys.stderr.write("REFUSE REFUSE-PROVENANCE %d problem(s), see provenance.json\n"
                                 % len(problems))
                return EXIT_REFUSE
        elif cmd == "preflight":
            jdump(preflight(m, bool(a.get("first_start"))))
        elif cmd == "supervise":
            return supervise(m, a["ctl"], a["state"], a["launcher"], a["epoch"])
        elif cmd == "ctl":
            extra = {k: v for k, v in a.items() if k not in ("ctl", "cmd", "timeout", "manifest")}
            resp = ctl_request(a["ctl"], a["cmd"], float(a.get("timeout", 300)), **extra)
            jdump(resp)
            if resp.get("ok") is not True:
                return EXIT_HOLD  # repair H2: an ok:false response is HOLD, never exit 0
        elif cmd == "ready-wait":
            jdump(ready_wait(m, a["state"], float(a["deadline"])), a["out"])
        elif cmd == "listener-proof":
            jdump(listener_proof(m, jload(a["state"])))
        elif cmd == "drain-check":
            drain_check(m, a["state"], float(a.get("deadline", TIMEOUTS["drain"])))
        elif cmd == "barrier":
            jdump(barrier(m, a["state"], float(a.get("deadline", TIMEOUTS["barrier"]))), a["out"])
        elif cmd == "lockout":
            jdump(lockout(m), a["out"])
        elif cmd == "inventory":
            jdump(inventory(m), a["out"])
        elif cmd == "snapshot":
            prev = jload(a["prev"] + "/snapshot.json") if "prev" in a else None
            rec = snapshot(m, a["name"], a["out"], prev)
            if rec["violations"]:
                jdump({"violations": rec["violations"]})
        elif cmd == "markers-new":
            jdump(markers_new(a["inst"], a["epoch"]), a["out"])
        elif cmd == "count":
            mk = jload(a["markers"])
            flat = {}
            for f in mk["files"]:
                d = jload(f)
                for k, v in d["markers"].items():
                    flat["%s/%s/%s" % (d["inst"], d["epoch"], k)] = v
            jdump(count_markers(a["snapshot"], flat), a["out"])
        elif cmd == "classify-epoch":
            ed = a["epoch_dir"]
            state = jload(a["state"])
            snaps = {n: jload(ed + "/" + n + "/snapshot.json") for n in ("SNAP-0", "SNAP-pre",
                                                                          "SNAP-post")}
            lock = jload(ed + "/lockout.json") if os.path.exists(ed + "/lockout.json") else None
            bok = os.path.exists(ed + "/barrier.json") and jload(ed + "/barrier.json").get("ok")
            clo = h_closure(m)
            out = classify_epoch(state, snaps, lock, bool(bok), clo["closure_verified"])
            out["socket_outcomes"] = socket_outcomes(lock, snaps)
            out["closure"] = clo
            jdump(out, ed + "/classification.json")
            jdump({"complete": out["complete"], "reasons": out["reasons"]})
            return EXIT_OK if out["complete"] else EXIT_FAIL
        elif cmd == "judge":
            counts = jload(a["counts"])
            own = jload(a["markers"])
            cls = jload(a["classification"])
            prefix = "%s/%s/" % (own["inst"], own["epoch"])
            mine = [dict(c, marker=c["marker"][len(prefix):]) for c in counts
                    if c["marker"].startswith(prefix)]
            foreign = [c for c in counts if not c["marker"].startswith(prefix) and c["count"]]
            r = judge(a["kind"], mine, own, cls["complete"])
            if a["kind"] != "P" and foreign:
                r["failures"].append("cross-instance marker present: %d" % len(foreign))
                r["pass"] = False
            if a["kind"] == "P" and "q2" in a:
                r["q2"] = q2_forwarding_check(mine)
                if r["q2"]["invalid_premise"]:
                    r["failures"].append("Q2 forwarding premise invalid")
                    r["pass"] = False
            jdump(r, a["out"])
            jdump(r)
            return EXIT_OK if r["pass"] else EXIT_FAIL
        elif cmd == "edit-copy":
            jdump(edit_copy(m))
        elif cmd == "eval-check":
            jdump(eval_check(m, a["eval_json"]))
        elif cmd == "perturb":
            jdump(perturb(m, a["out"], a["set"].split(",")))
        elif cmd == "field":
            field(m, a["key"])
        elif cmd == "move-collector":
            jdump(move_collector(m, a["dest"]), a["out"])
        elif cmd == "restore-collector":
            jdump(restore_collector(m), a["out"])
        elif cmd == "s5-observe":
            jdump(s5_observe(m, a["state"], float(a.get("deadline", TIMEOUTS["s5"]))), a["out"])
        elif cmd == "s5-verdict":
            ed = a["epoch_dir"]
            obs = jload(ed + "/s5.json")
            diag = jload(ed + "/s5-diag-counts.json")
            mgr = ("manager-aggregate-sink", "manager-internal-log", "per-process-sink",
                   "harness-sink")
            b = sum(c["count"] for c in diag if c["class"] in mgr)
            a_ok = obs["collector_dir_entries"] == 0
            v = {"target_dir_empty": a_ok, "collector_open_failure_lines": b,
                 "exercised": bool(a_ok and b > 0),
                 "observed_generations": len(obs["observed_generations"]),
                 "coverage": obs["coverage"], "accepting": obs["accepting"] is not None,
                 "unverified": "attempts whose per-process output was truncated by a later "
                               "attempt are lost; no absence claim (r3 5.5, r4 3.2)"}
            jdump(v, a["out"])
            jdump(v)
            return EXIT_OK if v["exercised"] else EXIT_FAIL
        elif cmd == "cross-check":
            ents = [tuple(x.split("=", 1)[::-1]) for x in a["entries"].split(",")]
            r = cross_check([(d, i) for d, i in ents], jload(a["markers"])["files"])
            jdump(r, a["out"])
            return EXIT_OK if r["pass"] else EXIT_FAIL
        elif cmd == "exit-watch":
            jdump(ctl_request(a["ctl"], "exit-watch", 30))
        elif cmd == "check-eacces":
            jdump({"result": check_eacces(a["path"])})
        elif cmd == "cleanup":
            jdump(cleanup(m, m["evidence"] + "/runtime-claim.json"))
        else:
            sys.stderr.write("unknown command %s\n" % cmd)
            return EXIT_USAGE
        return EXIT_OK
    except Refuse as r:
        sys.stderr.write("REFUSE %s\n" % r)
        return EXIT_REFUSE
    except Hold as h:
        sys.stderr.write("HOLD %s\n" % h)
        return EXIT_HOLD
    except Fail as f:
        sys.stderr.write("FAIL %s\n" % f)
        return EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
