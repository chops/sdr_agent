#!/usr/bin/env python3
"""5b sink test: self-test fixtures and synthetic self-tests.

Plan r2 9, r3 7, r4 2.6/3.5, r5 2.3/3.4, r6 2, R6-1 T18d; repaired per
claude-5b-harness-repair-plan.md (35a4926f), its amendment (25092856), A1/A2, the ba40b5b
dispositions (74d41237) and their binding Q1-Q4.

Run only by sink-test.sh in `selftest` mode, with the locked-nixpkgs python3 (-I), each
test under the shell's independent outer controller (`run_guarded`).

Registry (H3, Q3): every fixture gets an INTENT record before it is created (for a
directory, with its declared contents: a pre-creation contract, never adopted after a
scan) and an IDENTITY record after (path: dev/ino/type/mode; process: pid, birth_us, ppid
at start, uid). Each test id has a fixed proof contract (REQUIRED_PROOF) and a fixed
retention contract (RETENTION). A verdict is computed here, not by the caller: the observed
class must equal one of the test's fixed expected classes, every required proof field must
be present and "ok" (or an allowed "not-applicable:<reason>"), and an independent
reconciliation (full trees of registered fixture dirs, retained instance inventories, the
run root, fixture processes) must find nothing unauthorized. Disposal is validated before
anything is deleted. Anything else is REAL-UNCERTAINTY, and the suite stops.

Fixture processes are owned children with retained Popen handles (or shell jobs whose
identity is recorded); they are stopped only by identity (SIGTERM, bounded wait) and the
T19/T26 subjects end by themselves (amendment R1). Every handshake line is bounded as a
whole (Q2). Labels: `fixture-synthetic` marks classifier inputs built here;
`kernel-event` / `fixture-handshake` mark measured facts.
"""

import ctypes
import hashlib
import json
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # explicit: -I does not add the script directory on 3.11+
import sink_watch as W  # noqa: E402

PY = sys.executable
L_FIXTURE = 8.0      # autonomous fixture lifetime (amendment R1)
D_SUBJECT = 1.0      # injected per-stage subject deadline
D_REAP = 20.0        # outer reap deadline
D_LINE = 10.0        # whole-line handshake bound (Q2)
FORK_CLASS = "fork in window by role fixture-writer without source-gated attribution"
PASSING = ("PASS", "EXPECTED-REFUSAL")


class RealUncertainty(Exception):
    """An actual (not expected) identity, observation or teardown uncertainty."""


# ---------------------------------------------------------------- per-id contracts (Q3)
REQ, NA = "required", "may-be-na"
REQUIRED_PROOF = {}


def _proof(ids, **fields):
    for i in ids:
        REQUIRED_PROOF[i] = dict(fields)


_proof(["T9a", "T9b", "T10", "T11", "T12", "T15d", "T16", "T17a", "T17b", "T18a", "T18b",
        "T18c", "T18d", "T18d-vanish", "T18d-rebind", "T20a", "T20b", "T20c", "T20d", "T20e",
        "T20f", "T21a", "T21b", "T21c", "T21d", "T21e", "T22a", "T22b", "T22d", "T24", "T27"],
       fixtures=REQ)
_proof(["T17-baseline", "T22c", "T23a", "T23b", "T23c", "T23d", "T23e", "T26d"], fixtures=NA)
_proof(["T19a"], launcher_reap=REQ, fixtures=REQ)
_proof(["T19b", "T19c", "T19d", "T19f", "T19g", "T19i", "T26a", "T26c"], outer_reap=REQ,
       fixtures=REQ)
_proof(["T26b"], fixtures=REQ)
_proof(["T1", "T2", "T14"], fixtures=REQ, cleanup=REQ)
_proof(["T3"], fixtures=REQ)
_proof(["T13"], cleanup=REQ)
_proof(["T19e"], subject_receipt=REQ, outer_reap=REQ)
_proof(["T19h"], observer_receipt=REQ, outer_reap=REQ, descendants=REQ)
_proof(["T4a", "T4b"], stop_barrier=REQ, fixtures=REQ, cleanup=NA)
_proof(["T5"], db_exists_client=REQ, stop_barrier=REQ, cleanup=REQ)
_proof(["T6"], stop_barrier=REQ, cleanup=NA)
_proof(["T7"], stop_barrier=REQ, fixtures=REQ, cleanup=NA)
_proof(["T8"], fixtures=REQ, second_barrier=REQ, cleanup=REQ)
_proof(["T15a", "T15b"], stop=REQ, barrier=REQ, cleanup=NA)
_proof(["T15c"], stop=REQ, barrier=REQ, fixtures=REQ, cleanup=NA)
_proof(["T25"], stop_barrier=REQ, cleanup=REQ)

RETENTION = {t: ("root-" + t, "runtime-" + t) for t in ("T4a", "T4b", "T6", "T15a", "T15b",
                                                         "T15c")}
RETENTION["T7"] = ("root-T7", "runtime-T7", "standby-signal")
INSTANCE_KINDS = ("instance-root", "instance-runtime")


# ---------------------------------------------------------------- registry
def reg_path(d):
    return d + "/fixtures.json"


def registry(d):
    p = reg_path(d)
    return W.jload(p) if os.path.exists(p) else {"fixtures": [], "retain": {}}


def save(d, r):
    W.jdump(r, reg_path(d))


def intent(d, test, label, kind, contents=None):
    """INTENT before creation. A directory's `contents` (relative paths; "X/**" for a
    subtree created by a named tool) is a pre-creation contract."""
    r = registry(d)
    if any(f["test"] == test and f["label"] == label for f in r["fixtures"]):
        raise RealUncertainty("duplicate fixture label %s/%s" % (test, label))
    rec = {"test": test, "label": label, "kind": kind, "intent_t": W.now()}
    if kind == "dir":
        rec["contents"] = sorted(contents or [])
    r["fixtures"].append(rec)
    save(d, r)


def set_identity(d, test, label, ident):
    r = registry(d)
    for f in r["fixtures"]:
        if f["test"] == test and f["label"] == label:
            if "identity" in f:
                raise RealUncertainty("identity recorded twice: %s/%s" % (test, label))
            f["identity"] = ident
            save(d, r)
            return
    raise RealUncertainty("identity without intent: %s/%s" % (test, label))


def mark(d, test, label, **kw):
    r = registry(d)
    for f in r["fixtures"]:
        if f["test"] == test and f["label"] == label:
            f.update(kw)
            save(d, r)
            return
    raise RealUncertainty("unregistered fixture %s/%s" % (test, label))


def path_identity(path):
    rec = W.lstat_rec(path)
    return {"path": path, "dev": rec["dev"], "ino": rec["ino"], "type": rec["type"],
            "mode": rec["mode"]}


def proc_identity(pid, ppid_at_start):
    cur = W.bsdinfo(int(pid))
    if cur is None:
        raise RealUncertainty("fixture %s gone before its identity was recorded" % pid)
    return {"pid": int(pid), "birth_us": cur["birth_us"], "ppid_at_start": int(ppid_at_start),
            "uid": cur["uid"]}


def register_path(d, test, label, path, kind="dir", contents=None):
    intent(d, test, label, kind, contents)
    if kind == "dir":
        os.mkdir(path, 0o700)
    elif kind == "file":
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    set_identity(d, test, label, path_identity(path))
    return path


def retain(d, test, labels, manifests=(), contract=None):
    """Explicit per-test retention (H3, Q3): only labels in the test's fixed contract."""
    allowed = set(contract if contract is not None else RETENTION.get(test, ()))
    extra = sorted(set(labels) - allowed)
    if not allowed or extra:
        raise RealUncertainty("retention outside the contract of %s: %r" % (test, extra or labels))
    r = registry(d)
    cur = r["retain"].get(test, {"labels": [], "manifests": []})
    cur["labels"] = sorted(set(cur["labels"]) | set(labels))
    cur["manifests"] = sorted(set(cur["manifests"]) | set(x for x in manifests if x))
    cur["contract"] = sorted(allowed)
    r["retain"][test] = cur
    save(d, r)


def lookup(d, test, label):
    for f in registry(d)["fixtures"]:
        if f["test"] == test and f["label"] == label:
            return f
    raise RealUncertainty("unregistered fixture %s/%s" % (test, label))


# ---------------------------------------------------------------- owned fixture handles
def start_fixture(d, test, label, code, *args, **kw):
    intent(d, test, label, "proc")
    p = subprocess.Popen([PY, "-I", "-c", code] + [str(a) for a in args],
                         stdin=kw.get("stdin", subprocess.DEVNULL),
                         stdout=kw.get("stdout", subprocess.DEVNULL),
                         cwd=kw.get("cwd"), close_fds=True)
    set_identity(d, test, label, proc_identity(p.pid, os.getpid()))
    return p


def reap(p, deadline_s):
    """Bounded reap of an owned child through its handle; the real returncode."""
    try:
        return p.wait(timeout=deadline_s)
    except subprocess.TimeoutExpired:
        raise RealUncertainty("owned fixture %d still alive after %.0f s" % (p.pid, deadline_s))


def bounded_readline(pipe, deadline_s=D_LINE):
    """One whole handshake line under one monotonic bound (Q2): byte reads after select,
    never a blocking readline on partial data. Timeout or EOF is RealUncertainty."""
    fd = pipe.fileno()
    end = W.now() + deadline_s
    buf = b""
    while True:
        left = end - W.now()
        if left <= 0:
            raise RealUncertainty("handshake line incomplete after %.0f s" % deadline_s)
        ready, _, _ = select.select([fd], [], [], left)
        if not ready:
            continue
        ch = os.read(fd, 1)
        if not ch:
            raise RealUncertainty("handshake pipe closed before a full line")
        if ch == b"\n":
            return buf.decode("utf-8", "replace").strip()
        buf += ch


def identity_gone(ident):
    cur = W.bsdinfo(ident["pid"])
    return cur is None or cur["birth_us"] != ident["birth_us"]


def wait_gone(ident, deadline_s):
    end = W.now() + deadline_s
    while W.now() < end:
        if identity_gone(ident):
            return True
        time.sleep(0.1)
    return identity_gone(ident)


def kill_fixture(d, test, label):
    """Stop a registered fixture by its identity record only (repair H3): birth, ppid at
    start and uid must match; SIGTERM; bounded wait for the identity to go. A mismatch or a
    survivor is HOLD; no SIGKILL, no retry."""
    f = lookup(d, test, label)
    ident = f.get("identity")
    if not ident or "birth_us" not in ident:
        raise RealUncertainty("fixture %s/%s has no process identity" % (test, label))
    cur = W.bsdinfo(ident["pid"])
    if cur is None or cur["birth_us"] != ident["birth_us"]:
        return "gone"
    if cur["uid"] != ident["uid"] or cur["ppid"] != ident["ppid_at_start"]:
        raise RealUncertainty("fixture %s/%s identity mismatch (uid/ppid)" % (test, label))
    os.kill(ident["pid"], signal.SIGTERM)
    if not wait_gone(ident, 10.0):
        raise RealUncertainty("fixture %s/%s alive 10 s after SIGTERM" % (test, label))
    return "stopped"


# ---------------------------------------------------------------- contents and disposal (Q3)
def _covered(rel, allowed):
    for a in allowed:
        if a.endswith("/**"):
            base = a[:-3]
            if rel == base or rel.startswith(base + "/"):
                return True
        elif rel == a:
            return True
    return False


def tree_strays(d, f):
    """Objects under a registered fixture dir that are neither in its declared contents nor
    registered (by any test) as fixtures below it. Uses W.walk (no follow, one device)."""
    ident = f["identity"]
    root = ident["path"]
    allowed = list(f.get("contents", []))
    for g in registry(d)["fixtures"]:
        gi = g.get("identity") or {}
        p = gi.get("path")
        if p and p != root and p.startswith(root + "/"):
            allowed.append(p[len(root) + 1:])
            if g.get("kind") == "dir":
                rel = p[len(root) + 1:]
                allowed.extend(rel + "/" + c for c in g.get("contents", []))
    try:
        present = [rel for rel, _ in W.walk(root)]
    except W.Fail as e:
        return ["unwalkable %s: %s" % (root, str(e).split()[0])]
    return ["undeclared object %s/%s" % (root, rel) for rel in sorted(present)
            if not _covered(rel, allowed)]


def dispose(d, test, label):
    """Validated disposal (M3, Q3): identity, then contents, then no live users, and only
    then removal. Any mismatch is RealUncertainty and the object is RETAINED."""
    f = lookup(d, test, label)
    ident = f.get("identity")
    if not ident or "path" not in ident:
        raise RealUncertainty("dispose %s/%s: no path identity" % (test, label))
    path = ident["path"]
    if not os.path.lexists(path):
        raise RealUncertainty("dispose %s/%s: already gone" % (test, label))
    cur = W.lstat_rec(path)
    if (cur["dev"], cur["ino"], cur["type"]) != (ident["dev"], ident["ino"], ident["type"]):
        raise RealUncertainty("dispose %s/%s: identity changed" % (test, label))
    if cur["type"] == "dir":
        strays = tree_strays(d, f)
        if strays:
            raise RealUncertainty("dispose %s/%s retained: %s" % (test, label, strays[:3]))
        if W.open_handles_under(os.path.realpath(path)):
            raise RealUncertainty("dispose %s/%s retained: open handles" % (test, label))
        rc, _, _ = W.run(["/bin/rm", "-rf", "--", path], env=W.TOOL_ENV)
        if rc != 0 or os.path.lexists(path):
            raise RealUncertainty("dispose %s/%s: removal failed" % (test, label))
    else:
        os.unlink(path)
    mark(d, test, label, disposed=W.now())
    return "disposed"


# ---------------------------------------------------------------- verdicts and reconciliation
def _instance_audit(d, test_id, mp, auth, mine):
    problems = []
    try:
        m = W.load_manifest(mp)
    except (W.Refuse, OSError, ValueError, KeyError) as e:
        return ["retained manifest unreadable: %s" % type(e).__name__]
    by_path = {(f.get("identity") or {}).get("path"): f for f in mine}
    for key, kind in (("root", "instance-root"), ("runtime", "instance-runtime")):
        f = by_path.get(m[key])
        if f is None or f.get("kind") != kind or f["label"] not in auth:
            problems.append("retained %s not registered and authorized for %s" % (key, test_id))
    try:
        inv = W.inventory(m)
    except (W.Fail, W.Hold, OSError) as e:
        return problems + ["retained instance inventory failed: %s" % str(e).split()[0]]
    fixture_paths = {(f.get("identity") or {}).get("path"): f for f in mine
                     if f.get("kind") not in INSTANCE_KINDS}
    for e in inv["entries"]:
        p = e.get("path")
        if p in fixture_paths and fixture_paths[p]["label"] not in auth:
            problems.append("fixture object under retained root not authorized: %s" % p)
    for top in (m["root"], m["runtime_canonical"]):
        if os.path.lexists(top) and W.open_handles_under(top):
            problems.append("open handles under retained %s" % top)
    return problems


def reconcile(d, test_id, runroot, retained_manifests=()):
    """Independent leftover scan (H3, M3, Q3). Returns a list of problems."""
    r = registry(d)
    problems = []
    ret = r["retain"].get(test_id, {"labels": [], "manifests": []})
    auth = set(ret.get("labels", []))
    manifests = sorted(set(retained_manifests) | set(ret.get("manifests", [])))
    registered_paths = {}
    for f in r["fixtures"]:
        ident = f.get("identity")
        if ident and "path" in ident:
            registered_paths[ident["path"]] = ident
    mine = [f for f in r["fixtures"] if f["test"] == test_id]
    covered_instances = set()
    for f in mine:
        ident = f.get("identity")
        if ident is None:
            problems.append("intent without identity: %s" % f["label"])
            continue
        if "path" in ident:
            if not os.path.lexists(ident["path"]):
                continue
            cur = W.lstat_rec(ident["path"])
            if f["label"] not in auth:
                problems.append("leftover not authorized: %s" % ident["path"])
            elif (cur["dev"], cur["ino"]) != (ident["dev"], ident["ino"]):
                problems.append("retained identity changed: %s" % ident["path"])
            elif f.get("kind") in INSTANCE_KINDS:
                covered_instances.add(f["label"])
            elif f.get("kind") == "dir":
                problems.extend(tree_strays(d, f))
        elif "birth_us" in ident:
            if not identity_gone(ident):
                problems.append("fixture process alive: %s" % f["label"])
    for mp in manifests:
        problems.extend(_instance_audit(d, test_id, mp, auth, mine))
    if covered_instances and not manifests:
        problems.append("retained instance objects without a manifest audit: %s"
                        % sorted(covered_instances))
    if runroot and os.path.isdir(runroot):
        for name in sorted(os.listdir(runroot)):
            full = runroot + "/" + name
            ident = registered_paths.get(full)
            if ident is None:
                problems.append("unregistered object in run root: %s" % full)
                continue
            cur = W.lstat_rec(full)
            if (cur["dev"], cur["ino"]) != (ident["dev"], ident["ino"]):
                problems.append("run-root object identity changed: %s" % full)
    return problems


def proof_problems(test_id, teardown, contract=None):
    """Exact per-id proof contract (Q3): every field present, nothing extra; a required
    field must be "ok"; a may-be-na field may be "not-applicable:<reason>"."""
    c = contract if contract is not None else REQUIRED_PROOF.get(test_id)
    if c is None:
        return ["no proof contract for %s" % test_id]
    td = teardown if isinstance(teardown, dict) else {}
    out = ["unknown proof field %s" % k for k in sorted(set(td) - set(c))]
    for k, mode in sorted(c.items()):
        v = td.get(k)
        if v is None:
            out.append("missing proof field %s" % k)
        elif v == "ok":
            continue
        elif mode == NA and isinstance(v, str) and v.startswith("not-applicable:") and \
                len(v) > len("not-applicable:"):
            continue
        else:
            out.append("proof field %s=%s" % (k, v))
    return out


def verdict(d, test_id, expected, observed, teardown, runroot, retained_manifests=(),
            notes=None, contract=None):
    """`expected`: the test's fixed class list; `observed`: the parsed actual class;
    `teardown`: the test's exact proof record (see REQUIRED_PROOF)."""
    problems = reconcile(d, test_id, runroot, retained_manifests)
    bad_teardown = proof_problems(test_id, teardown, contract)
    if problems or bad_teardown:
        v = "REAL-UNCERTAINTY"
    elif observed in expected:
        v = "PASS" if observed == "PASS" else "EXPECTED-REFUSAL"
    else:
        v = "FAIL"
    rec = {"id": test_id, "expected": list(expected), "observed": observed, "verdict": v,
           "teardown": teardown, "problems": problems, "bad_teardown": bad_teardown,
           "notes": notes or {}}
    W.jdump(rec, "%s/%s.json" % (d, test_id))
    return rec


def receipt_ok(d, test_id):
    p = "%s/%s.json" % (d, test_id)
    if not os.path.exists(p):
        return False
    r = W.jload(p)
    return r["verdict"] in PASSING and not r.get("problems") and not r.get("bad_teardown")


def summary(d, head, ids, runroot=None):
    """Every listed receipt must pass, and a FINAL audit (Q3) re-reconciles every test
    holding a retention at summary time."""
    missing, bad, recs = [], [], {}
    for tid in ids:
        p = "%s/%s.json" % (d, tid)
        if not os.path.exists(p):
            missing.append(tid)
            continue
        r = W.jload(p)
        recs[tid] = r["verdict"]
        if not receipt_ok(d, tid):
            bad.append(tid)
    audit = {}
    for tid in sorted(registry(d)["retain"]):
        pr = reconcile(d, tid, runroot)
        audit[tid] = pr
        if pr and tid not in bad:
            bad.append(tid)
    out = {"head": head, "pass": not missing and not bad, "missing": missing, "bad": bad,
           "verdicts": recs, "final_audit": audit}
    W.jdump(out, d + "/selftest-summary.json")
    return out


def observed_class(stderr_text):
    """The exact class of the FIRST classed line of a sink_watch or sink-test stderr:
    'REFUSE REFUSE-X ...' -> REFUSE-X; 'HOLD FOREIGN-LISTENER ...' -> HOLD-FOREIGN-LISTENER;
    'FAIL FAIL-TIMEOUT ...' -> FAIL-TIMEOUT; 'SINK-TEST FAIL: FAIL-START ...' -> FAIL-START;
    a classed line without a class token -> its bare kind (REFUSE, HOLD or FAIL)."""
    kinds = ("REFUSE", "HOLD", "FAIL")
    for line in stderr_text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "SINK-TEST" and parts[1].rstrip(":") in kinds:
            parts = parts[1:]
            parts[0] = parts[0].rstrip(":")
        if len(parts) >= 1 and parts[0] in kinds:
            tok = parts[1] if len(parts) > 1 else ""
            if tok.startswith(kinds) and "-" in tok and tok.replace("-", "").isupper():
                return tok
            if tok and tok.replace("-", "").isalpha() and tok.replace("-", "").isupper() \
                    and "-" in tok:
                return parts[0] + "-" + tok
            return parts[0]
    return "NONE"


T5_PGDATA_HALT = "identity mismatch: data_directory,config_file"
T5_PORT_HALT = "target socket mismatch"


def t5_class(f_pgdata, f_port, f_exists):
    """Choice 5 / Q4 exact mapping from the three client receipts."""
    rec = {}
    for name, p in (("bad-pgdata", f_pgdata), ("bad-port", f_port), ("db-exists", f_exists)):
        if not os.path.exists(p):
            return "CLIENT-NO-RECEIPT"
        rec[name] = W.jload(p)
    for name in ("bad-pgdata", "bad-port", "db-exists"):
        if rec[name].get("status") == 3:
            return "HOLD-CLIENT-" + name
    want = {"bad-pgdata": (2, T5_PGDATA_HALT), "bad-port": (2, T5_PORT_HALT)}
    for name, (st, halt) in sorted(want.items()):
        if rec[name].get("status") != st or rec[name].get("halt") != halt:
            return "CLIENT-%s-%s" % (name, rec[name].get("status"))
    if rec["db-exists"].get("status") != 0 or rec["db-exists"].get("exists") is not False:
        return "CLIENT-db-exists-%s" % rec["db-exists"].get("status")
    return "REFUSE-CLIENT-TARGET"


def exit_stop_allowed(status_path):
    """Choice 3 as replaced (M2): the exit path may stop only for a current, clean, unfrozen
    watcher whose launcher identity is kernel-proven."""
    if not os.path.exists(status_path):
        return False
    try:
        resp = W.jload(status_path)
        st = resp["state"]
        return resp.get("ok") is True and st.get("signals_frozen") is False and \
            st.get("violations") == [] and \
            (st.get("launcher_identity") or {}).get("identity") == "kernel"
    except (ValueError, KeyError, TypeError, AttributeError, OSError):
        return False


# ---------------------------------------------------------------- fixture programs (shell-started)
def fixture_tcp_decoy(addr, port, count_file):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((addr, int(port)))
    s.listen(16)
    n = 0
    W.jdump({"accepts": n}, count_file)
    while True:
        c, _ = s.accept()
        n += 1
        c.close()
        W.jdump({"accepts": n}, count_file)


def fixture_unix_listener(path):
    s = socket.socket(socket.AF_UNIX)
    s.bind(path)
    s.listen(4)
    while True:
        c, _ = s.accept()
        c.close()


def fixture_cwd_holder(cwd):
    os.chdir(cwd)
    while True:
        time.sleep(1)


def fixture_sleeper(seconds):
    time.sleep(float(seconds))


# ---------------------------------------------------------------- shared helpers
def kq_register(kq, pid):
    ev = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD,
                       fflags=W.PROC_FFLAGS)
    kq.control([ev], 0, 0)


def kq_exit(kq, pid, timeout=10):
    deadline = W.now() + timeout
    while W.now() < deadline:
        for ev in kq.control(None, 16, 0.5):
            if ev.ident == pid and ev.fflags & W.NOTE_EXIT:
                if not ev.fflags & W.NOTE_EXITSTATUS:
                    return {"kind": "no-exitstatus"}
                return W.decode_status(ev.data)
    raise RealUncertainty("no exit event for %d" % pid)


def fake_manifest(root, port=25000):
    rt = "/tmp/devenv-st" + hashlib.sha256(root.encode()).hexdigest()[:5]
    return {"schema": "5b-sink-manifest/1", "inst": "selftest", "kind": "S", "head": "selftest",
            "root": root, "root_lstat": W.lstat_rec(root), "runtime": rt,
            "runtime_canonical": "/private" + rt, "pgdata": root + "/.devenv/state/postgres",
            "pg_socket": rt + "/postgres/.s.PGSQL.%d" % port, "pc_socket": rt + "/pc.sock",
            "native_socket": rt + "/processes/native.sock", "port": port,
            "launch_env": {"USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin"},
            "evidence": root + "/evidence"}


def mkroot(d, scratch, test, label, contents=()):
    return register_path(d, test, label, scratch + "/" + test.lower() + "-" + label, "dir",
                         list(contents))


def bare_watch(root, port=25000, closure=False):
    w = W.Watch(fake_manifest(root, port), root + "/watch-state.json")
    if closure:
        # fixture-synthetic established closure (M5): never a production fact
        w.closure = {"closure_verified": True, "detail": "fixture-synthetic"}
    return w


class FakeEv(object):
    def __init__(self, ident, fflags, data=0):
        self.ident, self.fflags, self.data = ident, fflags, data


PG_DIRS = [".devenv", ".devenv/state", ".devenv/state/postgres"]


# ---------------------------------------------------------------- healthy synthetic facts
def healthy(t0, t_pre, t_stop, t_post, sockets=None):
    """A graceful epoch as classifier inputs (fixture-synthetic): window singletons and the
    job chain with (pid, birth) parent links, graceful exits in source order, R6-1-consistent
    sockets, a lockout record and a consistent H record. classify_epoch must call it complete."""
    adm = t0 - 5.0

    def ent(pid, role, parent, pbirth, st):
        return {"pid": pid, "birth_us": pid * 1000, "role": role, "parent": parent,
                "parent_birth_us": pbirth, "admitted": adm, "lineage": True, "exit": st,
                "proof": "fixture-synthetic"}

    def ex(code, dt):
        return {"kind": "exited", "code": code, "t": t_stop + dt}

    def sg(sig, dt):
        return {"kind": "signaled", "signal": int(sig), "t": t_stop + dt}

    dead = [ent(1001, "launcher", None, None, ex(0, 3.0)),
            ent(1002, "process-compose", 1001, 1001000, ex(0, 2.0)),
            ent(1004, "devenv-tasks", 1002, 1002000, sg(signal.SIGINT, 1.0)),
            ent(1003, "wrapper", 1004, 1004000, sg(signal.SIGTERM, 0.1)),
            ent(1005, "postmaster-final", 1003, 1003000, ex(0, 0.2)),
            ent(1006, "pg-logger", 1005, 1005000, ex(0, 0.3))]
    socks = sockets or {"/tmp/st-pc.sock": {"present": True, "dev": 1, "ino": 11,
                                            "type": "socket", "mode": 0},
                        "/tmp/st-native.sock": {"present": True, "dev": 1, "ino": 12,
                                                "type": "socket", "mode": 0}}
    post = {k: {"present": False} for k in socks}
    snaps = {"SNAP-0": {"t": t0, "files": {}, "sockets": dict(socks), "violations": []},
             "SNAP-pre": {"t": t_pre, "files": {}, "sockets": dict(socks), "violations": []},
             "SNAP-post": {"t": t_post, "files": {}, "sockets": post, "violations": []}}
    lock = {"t": t0 - 0.1, "sockets": {k: dict(v) for k, v in socks.items()}}
    h = {"closure_verified": True, "image_violations": 0, "exec_unobserved": 0,
         "admission_unreadable_live": 0, "api_client_history": "none-in-envelope",
         "verdict": True}
    state = {"live": [], "dead": dead, "events": [], "violations": [], "gaps": [],
             "marks": {"stop_begin": t_stop}, "harness_signals": [], "launcher_pid": 1001,
             "h": h}
    return state, snaps, lock


def healthy_now():
    t = W.now()
    return healthy(t, t + 1.0, t + 1.5, t + 20.0)


def classify(state, snaps, lock, barrier_ok=True, closure_ok=True):
    return W.classify_epoch(state, snaps, lock, barrier_ok, closure_ok)


def no_malformed_h(reasons):
    return not [r for r in reasons if r.startswith("H:") and
                ("missing" in r or "type" in r or "inconsistent" in r)]


# ---------------------------------------------------------------- T16 capability
def poll_waitid_nowait(pid, deadline_s):
    end = W.now() + deadline_s
    while W.now() < end:
        if os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
            return True
        time.sleep(0.05)
    return False


def t16(d, scratch, runroot):
    notes, ok = {}, True
    T = "T16"
    notes["struct_size"] = ctypes.sizeof(W.ProcBsdInfo)
    mine = W.bsdinfo(os.getpid())
    ok &= notes["struct_size"] == 136 and mine["pid"] == os.getpid() and \
        mine["ppid"] == os.getppid() and mine["uid"] == os.getuid()
    kq = select.kqueue()
    c = start_fixture(d, T, "exit3", "import sys,time; time.sleep(0.5); sys.exit(3)")
    ok &= c.pid in W.child_pids(os.getpid())
    notes["pidpath_child"] = W.pidpath(c.pid)
    ok &= os.path.realpath(notes["pidpath_child"] or "") == os.path.realpath(PY)
    kq_register(kq, c.pid)
    st = kq_exit(kq, c.pid)
    rc = reap(c, D_REAP)
    notes["child_exit3"] = st
    ok &= st.get("kind") == "exited" and st.get("code") == 3 and rc == 3
    for sig in (signal.SIGTERM, signal.SIGKILL):
        c = start_fixture(d, T, "sig%d" % sig, "import time; time.sleep(%d)" % L_FIXTURE)
        kq_register(kq, c.pid)
        time.sleep(0.2)
        os.kill(c.pid, sig)
        st = kq_exit(kq, c.pid)
        rc = reap(c, D_REAP)
        notes["child_sig_%d" % sig] = st
        ok &= st.get("kind") == "signaled" and st.get("signal") == sig and rc == -sig
    mid = start_fixture(d, T, "mid", "import subprocess,sys;"
                        "g=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(%d)']);"
                        "print(g.pid,flush=True); g.wait()" % L_FIXTURE, stdout=subprocess.PIPE)
    gpid = int(bounded_readline(mid.stdout))
    intent(d, T, "grandchild", "proc")
    set_identity(d, T, "grandchild", proc_identity(gpid, mid.pid))
    ok &= gpid not in W.child_pids(os.getpid())
    kq_register(kq, gpid)
    gi = lookup(d, T, "grandchild")["identity"]
    if W.bsdinfo(gpid)["birth_us"] != gi["birth_us"]:
        raise RealUncertainty("grandchild identity changed")
    os.kill(gpid, signal.SIGTERM)
    st = kq_exit(kq, gpid)
    reap(mid, D_REAP)
    notes["grandchild_sigterm"] = st
    ok &= st.get("kind") == "signaled" and st.get("signal") == signal.SIGTERM
    c = start_fixture(d, T, "reaped", "pass")
    reap(c, D_REAP)
    try:
        kq_register(kq, c.pid)
        notes["esrch"] = "registered (unexpected)"
        ok = False
    except OSError as e:
        notes["esrch"] = "errno-%d" % e.errno
    q = start_fixture(d, T, "quiet", "import time; time.sleep(2)")
    kq_register(kq, q.pid)
    forks, end = 0, W.now() + 1.0
    while W.now() < end:
        for ev in kq.control(None, 16, 0.2):
            if ev.ident == q.pid and ev.fflags & W.NOTE_FORK:
                forks += 1
    reap(q, D_REAP)
    notes["quiet_parent_fork_notes"] = forks
    ok &= forks == 0
    b = start_fixture(d, T, "burst", "import os,time; time.sleep(0.5)\n"
                      "for i in range(20):\n"
                      "    p=os.fork()\n"
                      "    if p==0: os._exit(0)\n"
                      "    os.waitpid(p,0)\n"
                      "time.sleep(0.5)")
    kq_register(kq, b.pid)
    nfork, identified, end = 0, set(), W.now() + D_REAP
    while b.poll() is None and W.now() < end:
        for ev in kq.control(None, 64, 0.1):
            if ev.ident == b.pid and ev.fflags & W.NOTE_FORK:
                nfork += 1
                identified.update(W.child_pids(b.pid))
    reap(b, D_REAP)
    notes["burst"] = {"notifications": nfork, "identified": len(identified),
                      "coverage": "possible-gap" if nfork else "no-notifications"}
    ok &= 1 <= nfork <= 20 and len(identified) <= 20
    e = start_fixture(d, T, "exec", "import os,time; time.sleep(0.5); "
                      "os.execv('/bin/sh',['/bin/sh','-c','exit 0'])")
    kq_register(kq, e.pid)
    saw_exec, end = False, W.now() + D_REAP
    while e.poll() is None and W.now() < end:
        for ev in kq.control(None, 16, 0.1):
            if ev.ident == e.pid and ev.fflags & W.NOTE_EXEC:
                saw_exec = True
    reap(e, D_REAP)
    notes["note_exec"] = saw_exec
    ok &= saw_exec
    si = start_fixture(d, T, "waitid", "import time; time.sleep(0.3)")
    try:
        notes["waitid_wnowait"] = "ok" if poll_waitid_nowait(si.pid, 5.0) else "no-exit-in-5s"
        ok &= notes["waitid_wnowait"] == "ok"
    except (AttributeError, OSError) as err:
        notes["waitid_wnowait"] = "unavailable: %s" % type(err).__name__
        ok = False
    reap(si, D_REAP)
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=notes)


# ---------------------------------------------------------------- T9a / T9b
def t9a(d, scratch, runroot):
    """Emulated PID-reuse record on two real same-second processes (r4 3.4)."""
    T = "T9a"
    root = mkroot(d, scratch, T, "root")
    found = None
    for attempt in range(8):
        d1 = start_fixture(d, T, "d1-%d" % attempt, "import time; time.sleep(%d)" % L_FIXTURE)
        i1 = W.bsdinfo(d1.pid)
        l1 = W.run(["/bin/ps", "-o", "lstart=", "-p", str(d1.pid)], env=W.TOOL_ENV)[1].strip()
        d1.terminate()
        reap(d1, D_REAP)
        d2 = start_fixture(d, T, "d2-%d" % attempt, "import time; time.sleep(%d)" % L_FIXTURE)
        i2 = W.bsdinfo(d2.pid)
        l2 = W.run(["/bin/ps", "-o", "lstart=", "-p", str(d2.pid)], env=W.TOOL_ENV)[1].strip()
        if l1 == l2:
            found = (d2, i1, i2, l1, l2)
            break
        d2.terminate()
        reap(d2, D_REAP)
    if found is None:
        dispose(d, T, "root")
        return verdict(d, T, ["REFUSE-SIGNAL"], "INCONCLUSIVE-NO-SAME-SECOND-PAIR",
                       {"fixtures": "ok"}, runroot)
    d2, i1, i2, l1, l2 = found
    notes = {"lstart_equal": True, "us_distinct": i1["birth_us"] != i2["birth_us"]}
    if not notes["us_distinct"]:
        d2.terminate()
        reap(d2, D_REAP)
        dispose(d, T, "root")
        return verdict(d, T, ["REFUSE-SIGNAL"], "INCONCLUSIVE-EQUAL-US", {"fixtures": "ok"},
                       runroot, notes=notes)
    old_match = (i1["uid"], i1["comm"], l1) == (i2["uid"], i2["comm"], l2)
    w = bare_watch(root)
    w.entries[d2.pid] = {"pid": d2.pid, "birth_us": i1["birth_us"], "lineage": True,
                         "role": "process-compose", "exit": None}
    refused = False
    try:
        w.signal_verified(d2.pid, signal.SIGTERM, "T9a")
    except W.Hold:
        refused = True
    alive = W.bsdinfo(d2.pid) is not None and W.bsdinfo(d2.pid)["birth_us"] == i2["birth_us"]
    d2.terminate()
    reap(d2, D_REAP)
    dispose(d, T, "root")
    notes.update({"old_predicate_matches": old_match, "new_rule_refused": refused,
                  "d2_not_signalled": alive, "label": "emulated PID-reuse record"})
    obs = "REFUSE-SIGNAL" if old_match and refused and alive else "FAIL"
    return verdict(d, T, ["REFUSE-SIGNAL"], obs, {"fixtures": "ok"}, runroot, notes=notes)


def t9b(d, scratch, runroot):
    """Changed parent (repair H3): X starts a SELF-TERMINATING Y and exits; admission
    through X and signalling Y both refuse; Y is never signalled and is awaited, bounded."""
    T = "T9b"
    root = mkroot(d, scratch, T, "root")
    x = start_fixture(d, T, "x", "import subprocess,sys;"
                      "y=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(6)']);"
                      "print(y.pid,flush=True)", stdout=subprocess.PIPE)
    w = bare_watch(root)
    cur = W.bsdinfo(x.pid)
    w.register(x.pid)
    w.entries[x.pid] = {"pid": x.pid, "birth_us": cur["birth_us"], "lineage": True,
                        "role": "process-compose", "exit": None, "parent": None}
    ypid = int(bounded_readline(x.stdout))
    intent(d, T, "y", "proc")
    set_identity(d, T, "y", proc_identity(ypid, x.pid))
    reap(x, D_REAP)
    end = W.now() + 5
    while x.pid in w.entries and W.now() < end:
        w.drain(0.2)
    admitted = w.admit(ypid, x.pid, "T9b") is not None
    refused = False
    try:
        w.signal_verified(ypid, signal.SIGTERM, "T9b")
    except W.Hold:
        refused = True
    yi = lookup(d, T, "y")["identity"]
    alive = not identity_gone(yi)
    w.entries[x.pid] = {"pid": x.pid, "birth_us": cur["birth_us"], "lineage": True,
                        "role": "process-compose", "exit": None, "parent": None}
    stale_admit = w.admit(ypid, x.pid, "T9b-stale") is not None
    w.entries.pop(x.pid)
    gone = wait_gone(yi, 15.0)
    if not gone:
        raise RealUncertainty("T9b: Y still alive 15 s later (never signalled)")
    dispose(d, T, "root")
    notes = {"admitted_via_exited_parent": admitted, "signal_refused": refused, "y_alive": alive,
             "stale_admitted": stale_admit, "y_ended_by_itself": gone}
    obs = "REFUSE-ADMISSION" if (not admitted and refused and alive and not stale_admit) else "FAIL"
    return verdict(d, T, ["REFUSE-ADMISSION"], obs, {"fixtures": "ok"}, runroot, notes=notes)


# ---------------------------------------------------------------- T10 / T11 / T12
def t10(d, scratch, runroot):
    T = "T10"
    root = mkroot(d, scratch, T, "root", ["locked/f"])
    sub = register_path(d, T, "locked", root + "/locked", "dir", ["f"])
    with open(sub + "/f", "w") as f:
        f.write("x")
    os.chmod(sub, 0o500)
    m = fake_manifest(root)
    try:
        W.cleanup(m, root + "/no-claim.json")
        obs = "CLEANED"
    except W.Fail as e:
        obs = str(e).split()[0]
    os.chmod(sub, 0o700)
    dispose(d, T, "root")
    return verdict(d, T, ["FAIL-CLEANUP"], obs, {"fixtures": "ok"}, runroot)


def t11(d, scratch, runroot):
    T = "T11"
    root = mkroot(d, scratch, T, "root")
    sentinel = mkroot(d, scratch, T, "sentinel", ["keep"])
    with open(sentinel + "/keep", "w") as f:
        f.write("keep")
    intent(d, T, "escape", "symlink")
    os.symlink(sentinel, root + "/escape")
    set_identity(d, T, "escape", path_identity(root + "/escape"))
    before = (W.lstat_rec(sentinel)["ino"], sorted(os.listdir(sentinel)))
    m = fake_manifest(root)
    try:
        W.inventory(m)
        inv = "NO-FAILURE"
    except W.Fail as e:
        inv = str(e).split()[0]
    W.cleanup(m, root + "/no-claim.json")  # the subject removes the root (symlink unfollowed)
    after = (W.lstat_rec(sentinel)["ino"], sorted(os.listdir(sentinel)))
    obs = inv if before == after and not os.path.lexists(root) else "FAIL"
    dispose(d, T, "sentinel")
    return verdict(d, T, ["FAIL-SYMLINK"], obs, {"fixtures": "ok"}, runroot,
                   notes={"sentinel_intact": before == after})


def t12(d, scratch, runroot):
    T = "T12"
    root = mkroot(d, scratch, T, "root", [".devenv", ".devenv/state",
                                          ".devenv/state/process-compose"])
    os.makedirs(root + "/.devenv/state/process-compose", 0o700)
    sink = register_path(d, T, "sink", root + "/.devenv/state/process-compose/process-compose.log",
                         "file")
    os.chmod(sink, 0)
    m = fake_manifest(root)
    try:
        W.inventory(m)
        obs = "NO-FAILURE"
    except W.Fail as e:
        obs = str(e).split()[0]
    os.chmod(sink, 0o600)
    dispose(d, T, "root")
    return verdict(d, T, ["FAIL-UNREADABLE"], obs, {"fixtures": "ok"}, runroot)


# ---------------------------------------------------------------- T15d buffered producer
PRODUCER = """
import os, signal, sys, time
out = open(sys.argv[1], "w", buffering=1 << 16)
out.write("A\\n"); out.flush(); out.write("B\\n")
mode = sys.argv[2]
if mode == "d2":
    def h(*_):
        out.flush(); sys.exit(0)
    signal.signal(signal.SIGTERM, h)
elif mode == "d4":
    def h(*_):
        os._exit(0)
    signal.signal(signal.SIGTERM, h)
print("ready", flush=True)
time.sleep(%d)
""" % int(L_FIXTURE)


def t15d(d, scratch, runroot):
    T = "T15d"
    root = mkroot(d, scratch, T, "root", ["d1.out", "d2.out", "d3.out", "d4.out"])
    kq = select.kqueue()
    cases = {"d1": ("no-source-traced-drain", signal.SIGTERM, False, False),
             "d2": ("source-traced-graceful-exit0", signal.SIGTERM, True, True),
             "d3": ("no-source-traced-drain", signal.SIGKILL, False, False),
             "d4": ("no-source-traced-drain", signal.SIGTERM, False, False)}
    notes, ok = {}, True
    for name, (binding, sig, want_eligible, want_b) in sorted(cases.items()):
        path = root + "/" + name + ".out"
        p = start_fixture(d, T, name, PRODUCER, path, name, stdout=subprocess.PIPE)
        if bounded_readline(p.stdout) != "ready":
            raise RealUncertainty("T15d producer %s not ready" % name)
        kq_register(kq, p.pid)
        os.kill(p.pid, sig)
        st = kq_exit(kq, p.pid)
        reap(p, D_REAP)
        content = open(path).read()
        eligible = W.producer_exit_eligible(binding, st)
        notes[name] = {"status": st, "eligible": eligible, "has_A": "A" in content,
                       "has_B": "B" in content, "proof": "fixture-synthetic"}
        ok &= eligible == want_eligible and ("A" in content) and (("B" in content) == want_b)
    dispose(d, T, "root")
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
                   runroot, notes=notes)


# ---------------------------------------------------------------- snapshot helpers
def capture_meta(path):
    st = os.stat(path)
    with open(path, "rb") as f:
        b = f.read()
    return {"dev": st.st_dev, "ino": st.st_ino, "len": len(b), "sha256": W.sha256_bytes(b),
            "class": "per-process-sink", "append_only": True, "copy": "x"}


def prefix_violations(prev, path):
    cur = capture_meta(path)
    pm = prev["files"][path]
    v = []
    if (cur["dev"], cur["ino"]) != (pm["dev"], pm["ino"]):
        v.append(("capture-replaced", path))
    elif cur["len"] < pm["len"] or W.prefix_sha(path, pm["len"])["sha256"] != pm["sha256"]:
        v.append(("capture-prefix-changed", path))
    return v, cur


def reason_classes(reasons):
    return sorted(set(reasons))


# ---------------------------------------------------------------- T17a / T17b / baseline (R3)
FORKER = """
import os, sys
cap, n, variant = sys.argv[1], int(sys.argv[2]), sys.argv[3]
inp = sys.stdin.buffer
def report(s):
    sys.stdout.write(s + "\\n"); sys.stdout.flush()
inp.readline()
fd = os.open(cap, os.O_RDWR)
old = os.fstat(fd).st_size
if variant == "b":
    os.pwrite(fd, b"A" * n, old)
report("appended %d" % old)
c2 = os.fork()
if c2 == 0:
    if variant == "b":
        os.ftruncate(fd, old); os.pwrite(fd, b"Y" * n, old)
    else:
        os.ftruncate(fd, 0); os.pwrite(fd, b"Z" * (old + n), 0)
    os._exit(0)
os.waitpid(c2, 0)
report("c2-reaped %d" % c2)
r, wp = os.pipe()
c1 = os.fork()
if c1 == 0:
    os.close(wp); os.read(r, 1); os._exit(0)
os.close(r)
report("c1-ready %d" % c1)
inp.readline()
os.write(wp, b"x"); os.waitpid(c1, 0)
report("done")
"""


def t17(d, scratch, runroot, variant):
    """R3: real truncate-and-regrow after the LAST preservation snapshot (b), or a visible
    rewrite of snapshotted bytes (a); the watcher is driven in-process and paused until c2
    is reaped, then resumed to admit the blocked c1."""
    T = "T17" + variant
    root = mkroot(d, scratch, T, "root")
    cap = register_path(d, T, "capture", root + "/capture.log", "file")
    with open(cap, "wb") as f:
        f.write(b"original-bytes\n" * 8)
    N = 64
    w = bare_watch(root)
    snap0 = {"name": "SNAP-0", "t": W.now(), "files": {cap: capture_meta(cap)}, "violations": []}
    snappre = {"name": "SNAP-pre", "t": W.now(), "files": {cap: capture_meta(cap)},
               "violations": []}
    old_len = snappre["files"][cap]["len"]
    old_sha = snappre["files"][cap]["sha256"]
    f = start_fixture(d, T, "F", FORKER, cap, N, variant, stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE)
    cur = W.bsdinfo(f.pid)
    w.register(f.pid)
    w.entries[f.pid] = {"pid": f.pid, "birth_us": cur["birth_us"], "lineage": True,
                        "role": "fixture-writer", "exit": None, "parent": None,
                        "parent_birth_us": None, "admitted": W.now(), "exe": PY, "args": "F"}
    # paused: no drain/scan until F reports c2 reaped and c1 ready
    f.stdin.write(b"go\n")
    f.stdin.flush()
    lines = [bounded_readline(f.stdout) for _ in range(3)]
    c2pid = int(lines[1].split()[1])
    c1pid = int(lines[2].split()[1])
    # resume
    for _ in range(5):
        w.drain(0.1)
    w.scan_children(f.pid, "periodic")
    c1_admitted = c1pid in w.entries or any(x["pid"] == c1pid for x in w.dead)
    c2_admitted = c2pid in w.entries or any(x["pid"] == c2pid for x in w.dead)
    f.stdin.write(b"release\n")
    f.stdin.flush()
    bounded_readline(f.stdout)
    reap(f, D_REAP)
    w.drain(0.3)
    with open(cap, "rb") as fh:
        final = fh.read()
    want_len = old_len + N
    tail_ok = final[old_len:] == b"Y" * N if variant == "b" else True
    prefix_unchanged = W.sha256_bytes(final[:old_len]) == old_sha
    v, post_meta = prefix_violations(snappre, cap)
    t_stop = W.now() + 0.5
    state, snaps, lock = healthy(snap0["t"], snappre["t"], t_stop, t_stop + 10.0)
    snaps["SNAP-post"]["violations"] = v
    events = [dict(ev) for ev in w.events if ev["ev"] == "fork-note" and ev["pid"] == f.pid]
    fw = dict(w.entries.get(f.pid) or next(x for x in w.dead if x["pid"] == f.pid))
    if fw["exit"] is None:
        fw["exit"] = {"kind": "exited", "code": 0, "t": W.now()}
    fw["admitted"] = snap0["t"] - 1.0
    state["dead"].append(fw)
    state["events"] = events
    res = classify(state, snaps, lock)
    classes = reason_classes(res["reasons"])
    dispose(d, T, "root")
    notes = {"c1_admitted": c1_admitted, "c2_admitted": c2_admitted, "final_len": len(final),
             "want_len": want_len, "prefix_unchanged": prefix_unchanged, "tail_ok": tail_ok,
             "prefix_violation": bool(v), "fork_notes": len(events), "reason_classes": classes,
             "proof": {"admission": "kernel-event/fixture-handshake",
                       "classifier": "fixture-synthetic"}}
    if variant == "b":
        ok = c1_admitted and not c2_admitted and len(final) == want_len and prefix_unchanged \
            and tail_ok and not v and classes == [FORK_CLASS]
    else:
        ok = c1_admitted and bool(v) and not res["complete"] and FORK_CLASS in classes
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
                   runroot, notes=notes)


def t17_baseline(d, scratch, runroot):
    state, snaps, lock = healthy_now()
    res = classify(state, snaps, lock)
    return verdict(d, "T17-baseline", ["PASS"], "PASS" if res["complete"] else "FAIL",
                   {"fixtures": "not-applicable:no fixtures"}, runroot,
                   notes={"reasons": res["reasons"], "proof": "fixture-synthetic"})


# ---------------------------------------------------------------- T18 accept-and-spawn server
SERVER = """
import os, signal, socket, sys, threading, time
path, cap, accept_delay, handler_delay = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
mode = sys.argv[5]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8)
def bye(*_):
    try: os.unlink(path)
    except FileNotFoundError: pass
    os._exit(0)
signal.signal(signal.SIGTERM, bye)
print("ready", flush=True)
if mode == "rebind":
    time.sleep(accept_delay); s.close(); os.unlink(path)
    s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8)
if mode == "vanish":
    time.sleep(accept_delay); os.unlink(path)
time.sleep(accept_delay)
def handle(c):
    req = c.recv(64)
    if req.startswith(b"restart"):
        time.sleep(handler_delay)
        with open(cap, "r+") as f:
            f.truncate(0); f.write("R" * 4096)
    c.close()
end = time.time() + 15
s.settimeout(1)
while time.time() < end:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    threading.Thread(target=handle, args=(c,), daemon=True).start()
"""


def t18(d, scratch, runroot, variant):
    T = "T18" + variant
    root = mkroot(d, scratch, T, "root", ["capture.log"])
    intent(d, T, "sockdir", "dir", ["native.sock"])
    sdir = tempfile.mkdtemp(prefix="sk18", dir="/tmp")
    set_identity(d, T, "sockdir", path_identity(sdir))
    sock = sdir + "/native.sock"
    cap = root + "/capture.log"
    with open(cap, "w") as f:
        f.write("original-bytes\n" * 8)
    params = {"a": ("1.5", "0", "plain"), "b": ("0", "0", "plain"), "c": ("0", "1.5", "plain"),
              "d": ("0", "0", "plain"), "d-vanish": ("0.8", "0", "vanish"),
              "d-rebind": ("0.8", "0", "rebind")}[variant]
    srv = start_fixture(d, T, "server", SERVER, sock, cap, *params, stdout=subprocess.PIPE)
    if bounded_readline(srv.stdout) != "ready":
        raise RealUncertainty("T18 server not ready")
    client_history = False
    cl = None
    if variant == "a":
        cl = socket.socket(socket.AF_UNIX)
        cl.connect(sock)
        cl.sendall(b"restart")
        client_history = True
    elif variant == "b":
        cl = socket.socket(socket.AF_UNIX)
        cl.connect(sock)
        client_history = True
        time.sleep(0.3)
    elif variant == "c":
        cl = socket.socket(socket.AF_UNIX)
        cl.connect(sock)
        cl.sendall(b"restart")
        time.sleep(0.3)
        cl.close()
        cl = None
        client_history = True
    os.chmod(sock, 0)
    lr = W.socket_rec(sock)
    eacces = W.check_eacces(sock)
    snap0 = {"t": W.now(), "files": {cap: capture_meta(cap)}, "sockets": {sock: W.socket_rec(sock)},
             "violations": []}
    if variant == "b":
        cl.sendall(b"restart")
    time.sleep(2.5)
    if cl is not None:
        cl.close()
    snappre = {"t": W.now(), "files": {cap: capture_meta(cap)},
               "sockets": {sock: W.socket_rec(sock)}, "violations": []}
    v0, _ = prefix_violations(snap0, cap)
    snappre["violations"] = v0
    srv.send_signal(signal.SIGTERM)
    reap(srv, D_REAP)
    v1, post_meta = prefix_violations(snappre, cap) if not v0 else ([], capture_meta(cap))
    t_stop = snappre["t"] + 0.5
    state, snaps, lock = healthy(snap0["t"], snappre["t"], t_stop, t_stop + 10.0,
                                 sockets={sock: lr})
    snaps["SNAP-0"]["sockets"] = snap0["sockets"]
    snaps["SNAP-pre"]["sockets"] = snappre["sockets"]
    snaps["SNAP-pre"]["violations"] = v0
    snaps["SNAP-post"]["sockets"] = {sock: W.socket_rec(sock)}
    snaps["SNAP-post"]["violations"] = v1
    lock = {"t": snap0["t"] - 0.1, "sockets": {sock: lr}}
    if client_history:
        # an API client in the envelope is an image outside the verified closure: H false
        state["violations"] = [{"kind": "exe-not-allowlisted", "pid": os.getpid(), "t": W.now(),
                                "detail": "fixture API client"}]
        state["h"] = dict(state["h"], image_violations=1, api_client_history="unknown",
                          verdict=False)
    res = classify(state, snaps, lock)
    socket_post = "present" if W.socket_rec(sock)["present"] else "unlinked"
    dispose(d, T, "root")
    dispose(d, T, "sockdir")
    notes = {"eacces_after_lock": eacces, "complete": res["complete"], "reasons": res["reasons"],
             "socket_post": socket_post, "proof": "fixture-synthetic"}
    if variant == "d":
        ok = res["complete"] and eacces == "errno-13" and socket_post == "unlinked"
        return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                       notes=notes)
    ok = (not res["complete"]) and (eacces == "errno-13" or variant.startswith("d-"))
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
                   runroot, notes=notes)


# ---------------------------------------------------------------- T19 (R1, A1, A2, M1, Q2)
TERM_RESISTANT = """
import signal, time, sys
for s in sys.argv[1].split(","):
    if s: signal.signal(getattr(signal, s), signal.SIG_IGN)
print("ready", flush=True)
time.sleep(float(sys.argv[2]))
"""
STAGES = {"launcher": D_SUBJECT, "pc": D_SUBJECT, "dt": D_SUBJECT, "kill": D_SUBJECT,
          "pgctl": 5.0, "pgctl_t": 2, "overall": 5 * D_SUBJECT}  # < L_FIXTURE


def watch_with(d, T, root, fixtures, closure=False):
    """A Watch whose entries are registered owned fixtures: [(label, role, ignore, cwd)]."""
    w = bare_watch(root, closure=closure)
    procs = {}
    for label, role, ignore, cwd in fixtures:
        p = start_fixture(d, T, label, TERM_RESISTANT, ignore, L_FIXTURE, cwd=cwd,
                          stdout=subprocess.PIPE)
        if bounded_readline(p.stdout) != "ready":  # handlers installed before any stop
            raise RealUncertainty("fixture %s/%s not ready" % (T, label))
        cur = W.bsdinfo(p.pid)
        w.register(p.pid)
        w.entries[p.pid] = {"pid": p.pid, "birth_us": cur["birth_us"], "lineage": True,
                            "role": role, "exit": None, "parent": None, "admitted": W.now(),
                            "exe": PY, "args": label, "execs": 0}
        if role == "launcher":
            w.launcher = p
        procs[label] = p
    return w, procs


def outer_reap(procs):
    """Separate outer teardown: no signals; reap every owned fixture by its handle."""
    return {label: reap(p, D_REAP) for label, p in procs.items()}


def rcs_word(rcs, want):
    return "ok" if rcs == want else "rcs-%r" % (rcs,)


def write_fixture_closure(root, m, launcher):
    """A fixture-synthetic established closure for supervise (M2 refuse-before-spawn)."""
    ev = m["evidence"]
    os.mkdir(ev, 0o700)
    os.mkdir(root + "/art", 0o700)
    os.mkdir(root + "/R", 0o700)
    files = {}
    for name in ("launcher", "yaml", "tasks", "task_cmd", "start", "setup", "conf"):
        p = root + "/art/" + name
        with open(p, "w") as f:
            f.write("fixture-synthetic %s\n" % name)
        files[name] = {"path": p, "sha256": W.sha256_file_nofollow(p)}
    refs = sorted(W.PKG.values())
    W.jdump({"problems": []}, ev + "/provenance.json")
    with open(ev + "/launcher-path", "w") as f:
        f.write(launcher + "\n")
    W.jdump({"inst": m["inst"], "head": m["head"], "launcher": launcher, "files": files,
             "package_refs": refs}, ev + "/artifacts.json")
    W.jdump({"inst": "R", "head": m["head"], "package_refs": refs}, root + "/R/artifacts.json")


ART = ["art/" + n for n in ("launcher", "yaml", "tasks", "task_cmd", "start", "setup", "conf")]


def t19a(d, scratch, runroot):
    T = "T19a"
    root = mkroot(d, scratch, T, "root", ["evidence", "evidence/provenance.json",
                                          "evidence/artifacts.json", "evidence/launcher-path",
                                          "evidence/E1", "evidence/E1/launcher.out",
                                          "evidence/E1/launcher.err", "R", "R/artifacts.json",
                                          "art", "launcher.sh", "ctl", "state.json"] + ART)
    script = root + "/launcher.sh"
    with open(script, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(script, 0o700)
    m = fake_manifest(root)
    m["launch_env"] = {"PATH": "/usr/bin:/bin"}
    write_fixture_closure(root, m, script)
    if W.h_closure(m)["closure_verified"] is not True:
        raise RealUncertainty("T19a: the fixture closure was not established")
    state_path = root + "/state.json"
    rc = W.supervise(m, root + "/ctl", state_path, script, "E1", seam_exit_before_register=True,
                     post_stop_s=5)
    st = W.jload(state_path)
    kinds = [v["kind"] for v in st["violations"]]
    li = st.get("launcher_identity") or {}
    reaped = (st.get("launcher_reaped") or {}).get("returncode")
    ok = rc == W.EXIT_HOLD and "launcher-unregistered" in kinds and li.get("identity") == "unknown" \
        and li.get("birth_us") is None and reaped == 0
    dispose(d, T, "root")
    return verdict(d, T, ["HOLD-LAUNCHER-UNREGISTERED"], "HOLD-LAUNCHER-UNREGISTERED" if ok else
                   "FAIL", {"launcher_reap": "ok" if reaped == 0 else "not-reaped",
                            "fixtures": "ok"}, runroot,
                   notes={"rc": rc, "violations": kinds, "launcher_identity": li})


def t19b(d, scratch, runroot):
    T = "T19b"
    root = mkroot(d, scratch, T, "root")
    w, procs = watch_with(d, T, root, [("launcher", "launcher", "SIGTERM", None)])
    res = W.stop_tree(w, fake_manifest(root), stages=STAGES)
    frozen = False
    try:
        w.signal_verified(procs["launcher"].pid, signal.SIGTERM, "after-hold")
    except W.Hold:
        frozen = True
    kills = [s for s in w.harness_signals if s["signal"] == int(signal.SIGKILL)]
    rcs = outer_reap(procs)
    dispose(d, T, "root")
    ok = res["ok"] is False and [r["role"] for r in res["remaining"]] == ["launcher"] and frozen \
        and not kills
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"launcher": 0}), "fixtures": "ok"}, runroot,
                   notes={"result": res, "outer_rcs": rcs})


def pm_root(d, scratch, T):
    root = mkroot(d, scratch, T, "root", PG_DIRS + [".devenv/state/postgres/postmaster.pid"])
    pgd = root + "/.devenv/state/postgres"
    os.makedirs(pgd, 0o700)
    return root, pgd


def t19c(d, scratch, runroot):
    T = "T19c"
    root, pgd = pm_root(d, scratch, T)
    w, procs = watch_with(d, T, root, [("launcher", "launcher", "", None),
                                      ("pm", "postmaster-final", "SIGTERM,SIGINT", pgd)])
    with open(pgd + "/postmaster.pid", "w") as f:
        f.write("%d\n%s\n" % (procs["pm"].pid, pgd))
    res = W.stop_tree(w, fake_manifest(root), stages=STAGES)
    rcs = outer_reap(procs)
    dispose(d, T, "root")
    pgctl = [s for s in res["stages"] if s[0] == "pg_ctl"]
    ok = res["ok"] is False and bool(pgctl) and pgctl[0][1] != 0 and \
        any(r["role"] == "postmaster-final" for r in res["remaining"]) and \
        not [s for s in w.harness_signals if s["signal"] == int(signal.SIGKILL)]
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"launcher": -15, "pm": 0}), "fixtures": "ok"},
                   runroot, notes={"result": res, "outer_rcs": rcs})


def t19d(d, scratch, runroot):
    T = "T19d"
    root = mkroot(d, scratch, T, "root")
    w, procs = watch_with(d, T, root, [("launcher", "launcher", "", None),
                                      ("pc", "process-compose", "SIGTERM", None),
                                      ("dt", "devenv-tasks", "SIGTERM", None),
                                      ("aux", "pg-aux", "SIGTERM", None)])
    res = W.stop_tree(w, fake_manifest(root), stages=STAGES)
    rcs = outer_reap(procs)
    dispose(d, T, "root")
    killed = sorted(s["role"] for s in w.harness_signals if s["signal"] == int(signal.SIGKILL))
    ok = res["ok"] is False and [r["role"] for r in res["remaining"]] == ["pg-aux"] and \
        killed == ["devenv-tasks", "process-compose"]
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"launcher": -15, "pc": -9, "dt": -9, "aux": 0}),
                    "fixtures": "ok"}, runroot,
                   notes={"result": res, "outer_rcs": rcs, "killed": killed})


def t19f(d, scratch, runroot):
    """M1: the overall deadline expires before the next stage; nothing more is sent."""
    T = "T19f"
    root = mkroot(d, scratch, T, "root")
    w, procs = watch_with(d, T, root, [("launcher", "launcher", "", None),
                                      ("pc", "process-compose", "SIGTERM", None)])
    res = W.stop_tree(w, fake_manifest(root), stages=dict(STAGES, overall=0.5, launcher=1.0))
    sent = [(s["role"], s["signal"]) for s in w.harness_signals]
    rcs = outer_reap(procs)
    dispose(d, T, "root")
    ok = res["ok"] is False and "overall deadline passed before pc-term" in res.get("hold", "") \
        and sent == [("launcher", int(signal.SIGTERM))]
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"launcher": -15, "pc": 0}), "fixtures": "ok"},
                   runroot, notes={"result": res, "sent": sent, "outer_rcs": rcs})


def t19g(d, scratch, runroot):
    """M1/Q2: a handshake that never completes is a bounded subject HOLD; no signal."""
    T = "T19g"
    root = mkroot(d, scratch, T, "root")
    p = start_fixture(d, T, "silent", "import time; time.sleep(%d)" % L_FIXTURE,
                      stdout=subprocess.PIPE)
    t0 = W.now()
    subject = "NO-HOLD"
    try:
        bounded_readline(p.stdout, 1.0)
    except RealUncertainty:
        subject = "HOLD-HANDSHAKE"
    took = W.now() - t0
    rcs = outer_reap({"silent": p})
    dispose(d, T, "root")
    obs = subject if took <= 2.0 else "SUBJECT-OVERRAN"
    return verdict(d, T, ["HOLD-HANDSHAKE"], obs,
                   {"outer_reap": rcs_word(rcs, {"silent": 0}), "fixtures": "ok"}, runroot,
                   notes={"took_s": took})


def t19i(d, scratch, runroot):
    """Q2: the absolute deadline expires DURING the drain and identity proof; the signal is
    refused immediately before os.kill, and pg_ctl is refused before any spawn."""
    T = "T19i"
    root, pgd = pm_root(d, scratch, T)
    w, procs = watch_with(d, T, root, [("pc", "process-compose", "", None),
                                      ("pm", "postmaster-final", "", pgd)])
    with open(pgd + "/postmaster.pid", "w") as f:
        f.write("%d\n%s\n" % (procs["pm"].pid, pgd))
    births = {k: W.bsdinfo(p.pid)["birth_us"] for k, p in procs.items()}
    w.drain = lambda timeout=0: time.sleep(0.6)  # fixture-synthetic slow drain
    refused_sig = False
    try:
        w.signal_verified(procs["pc"].pid, signal.SIGTERM, "T19i", deadline=W.now() + 0.3)
    except W.Hold as h:
        refused_sig = "deadline" in str(h)
    del w.drain
    refused_pgctl = False
    try:
        W.pg_ctl_stop(w, fake_manifest(root), w.alive("postmaster-final"), timeout=5, t=2,
                      deadline=W.now() - 0.01)
    except W.Hold as h:
        refused_pgctl = "deadline" in str(h)
    alive = {k: (W.bsdinfo(p.pid) or {}).get("birth_us") == births[k] for k, p in procs.items()}
    rcs = outer_reap(procs)
    dispose(d, T, "root")
    ok = refused_sig and refused_pgctl and alive == {"pc": True, "pm": True} and \
        w.harness_signals == [] and w.helpers == []
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"pc": 0, "pm": 0}), "fixtures": "ok"}, runroot,
                   notes={"refused_sig": refused_sig, "refused_pgctl": refused_pgctl,
                          "alive_after": alive})


# ---------------------------------------------------------------- T20 (fabricated verdict inputs)
T20_CONTENTS = {
    "a": ["selftest", "selftest/X.json", "run"],
    "b": ["selftest", "selftest/fixtures.json", "selftest/X.json", "run", "run/fx",
          "run/fx/stray"],
    "c": ["selftest", "selftest/fixtures.json", "run"],
    "d": ["selftest", "selftest/X1.json", "selftest/X2.json", "selftest/selftest-summary.json",
          "run"],
    "e": ["selftest", "selftest/X.json", "run"],
    "f": ["selftest", "selftest/fixtures.json", "run", "run/fy", "run/fy/stray"],
}


def t20(d, scratch, runroot, variant):
    """Meta-controls on FABRICATED records in a private directory (amendment R1, M3, Q3).
    Each has a paired passing case, so the failure has no other premise."""
    T = "T20" + variant
    priv = mkroot(d, scratch, T, "private", T20_CONTENTS[variant])
    pd = priv + "/selftest"
    os.mkdir(pd, 0o700)
    run = priv + "/run"
    os.mkdir(run, 0o700)
    notes = {}
    if variant == "a":
        c = {"cleanup": REQ}
        good = verdict(pd, "X", ["FAIL-CLEANUP"], "FAIL-CLEANUP", {"cleanup": "ok"}, run,
                       contract=c)["verdict"]
        bad = verdict(pd, "X", ["FAIL-CLEANUP"], "FAIL-CLEANUP", {"cleanup": "status-1"}, run,
                      contract=c)["verdict"]
        ok = good == "EXPECTED-REFUSAL" and bad == "REAL-UNCERTAINTY"
    elif variant == "b":
        c = {"cleanup": NA}
        td = {"cleanup": "not-applicable:retained by design"}
        register_path(pd, "X", "fx", run + "/fx", "dir", [])
        retain(pd, "X", ["fx"], contract=["fx"])
        good = verdict(pd, "X", ["REFUSE-X"], "REFUSE-X", td, run, contract=c)
        with open(run + "/fx/stray", "w") as f:
            f.write("x")
        bad = verdict(pd, "X", ["REFUSE-X"], "REFUSE-X", td, run, contract=c)
        notes = {"good": good["problems"], "bad": bad["problems"]}
        ok = good["verdict"] == "EXPECTED-REFUSAL" and bad["verdict"] == "REAL-UNCERTAINTY" and \
            bad["problems"] == ["undeclared object %s/stray" % (run + "/fx")]
    elif variant == "c":
        p_ok = start_fixture(pd, "X", "intact", "import time; time.sleep(3)")
        p = start_fixture(pd, "X", "proc", "import time; time.sleep(3)")
        r = registry(pd)
        for f in r["fixtures"]:
            if f["label"] == "proc":
                f["identity"]["uid"] += 1  # same birth, mismatching owner: HOLD, not "gone"
        save(pd, r)
        held = False
        try:
            kill_fixture(pd, "X", "proc")
        except RealUncertainty:
            held = True
        intact = kill_fixture(pd, "X", "intact")
        rc_ok, rc = reap(p_ok, D_REAP), reap(p, D_REAP)
        notes = {"intact_rc": rc_ok, "mismatch_rc": rc}
        ok = held and intact == "stopped" and rc_ok == -15 and rc == 0
    elif variant == "d":
        verdict(pd, "X1", ["PASS"], "PASS", {"cleanup": "ok"}, run, contract={"cleanup": REQ})
        verdict(pd, "X2", ["PASS"], "PASS", {"cleanup": "failed"}, run, contract={"cleanup": REQ})
        alone = summary(pd, "head", ["X1"], run)
        both = summary(pd, "head", ["X1", "X2"], run)
        ok = alone["pass"] is True and both["pass"] is False and both["bad"] == ["X2"]
    elif variant == "e":
        c = {"cleanup": REQ, "barrier": REQ}
        good = verdict(pd, "X", ["PASS"], "PASS", {"cleanup": "ok", "barrier": "ok"}, run,
                       contract=c)["verdict"]
        bad = verdict(pd, "X", ["PASS"], "PASS", {"cleanup": "ok"}, run, contract=c)
        ok = good == "PASS" and bad["verdict"] == "REAL-UNCERTAINTY" and \
            bad["bad_teardown"] == ["missing proof field barrier"]
    else:
        register_path(pd, "X", "fz", run + "/fz", "dir", ["keep"])
        with open(run + "/fz/keep", "w") as f:
            f.write("k")
        clean = dispose(pd, "X", "fz") == "disposed" and not os.path.lexists(run + "/fz")
        register_path(pd, "X", "fy", run + "/fy", "dir", [])
        with open(run + "/fy/stray", "w") as f:
            f.write("x")
        held = False
        try:
            dispose(pd, "X", "fy")
        except RealUncertainty:
            held = True
        kept = os.path.exists(run + "/fy/stray")
        ok = clean and held and kept
        notes = {"clean_disposed": clean, "stray_held": held, "stray_kept": kept}
    dispose(d, T, "private")
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=notes)


# ---------------------------------------------------------------- T21 (snapshot integrity, H5)
def t21(d, scratch, runroot, variant):
    T = "T21" + variant
    root = mkroot(d, scratch, T, "root", ["src.log", "snap", "snap/copy", "snap/snapshot.json"])
    src = root + "/src.log"
    with open(src, "wb") as f:
        f.write(b"line-one\n" * 100 + b"needle-in-the-tail\n")
    sd = root + "/snap"
    os.mkdir(sd, 0o700)
    obs = "FAIL"
    if variant == "a":
        def half(fd, data):
            return os.write(fd, data[:max(1, len(data) // 2)])
        meta = W.snap_file(src, sd + "/copy", writer=half)
        ok = meta["copy_sha256"] == W.sha256_file_nofollow(src) and meta["copy_len"] == meta["len"]
        obs = "PASS" if ok else "FAIL"
    elif variant == "b":
        try:
            W.snap_file(src, sd + "/copy", writer=lambda fd, data: 0)
            obs = "NO-HOLD"
        except W.Hold:
            obs = "HOLD" if os.path.exists(sd + "/copy") else "HOLD-NO-PARTIAL"
    else:
        meta = W.snap_file(src, sd + "/copy")
        meta.update({"class": "per-process-sink", "append_only": True, "copy": "copy"})
        W.jdump({"files": {src: meta}}, sd + "/snapshot.json")
        with open(sd + "/copy", "r+b") as f:
            if variant == "c":
                f.seek(0)
                f.write(b"X")
            else:
                f.truncate(meta["len"] - 10)
        try:
            W.count_markers(sd, {"n": "needle-in-the-tail"})
            obs = "COUNTED"
        except W.Hold:
            obs = "HOLD"
    dispose(d, T, "root")
    want = "PASS" if variant == "a" else "HOLD"
    return verdict(d, T, [want], obs, {"fixtures": "ok"}, runroot)


T21E_CASES = {"multi": b"mk mk mk\nmk\nnone\n", "unterminated": b"none\nmk-last",
              "empty": b"", "binary": b"\xff\x00mk\x01\n\x00\x00\nmk\xfe", "zero": b"a\nb\n"}


def t21e(d, scratch, runroot):
    """grep -F -c -a line-semantics equivalence on verified bytes (review 29bdd2d6)."""
    T = "T21e"
    root = mkroot(d, scratch, T, "root", sorted(T21E_CASES))
    res, ok = {}, True
    for name, data in sorted(T21E_CASES.items()):
        p = root + "/" + name
        with open(p, "wb") as f:
            f.write(data)
        rc, out, _ = W.run(["/usr/bin/grep", "-F", "-c", "-a", "--", "mk", p], env=W.TOOL_ENV)
        g = int(out.strip()) if rc in (0, 1) else None
        mine = W.grep_count(data, b"mk")
        res[name] = {"grep": g, "in_memory": mine, "grep_rc": rc}
        ok &= g is not None and g == mine
    dispose(d, T, "root")
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=res)


# ---------------------------------------------------------------- T22 (H1, D-1, M5)
PC_FAKE = "/nix/store/old-image"


def h_check(w, extra_violations=None):
    state, snaps, lock = healthy_now()
    state["violations"] = list(w.violations) + list(extra_violations or [])
    state["h"] = w.h_record()  # derived, never overridden (M5)
    return classify(state, snaps, lock), state["h"]


def t22a(d, scratch, runroot):
    T = "T22a"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root, closure=True)
    base, _ = h_check(w)
    c = start_fixture(d, T, "child", "pass")
    reap(c, D_REAP)
    w.entries[c.pid] = {"pid": c.pid, "birth_us": 1, "lineage": True, "role": "process-compose",
                        "exit": None, "parent": None, "exe": PC_FAKE, "args": "old", "execs": 0,
                        "admitted": W.now()}
    w.handle(FakeEv(c.pid, W.NOTE_EXEC | W.NOTE_EXIT | W.NOTE_EXITSTATUS, 0))
    dead = next(x for x in w.dead if x["pid"] == c.pid)
    kinds = [v["kind"] for v in w.violations]
    res, h = h_check(w)
    dispose(d, T, "root")
    ok = base["complete"] is True and kinds == ["exec-image-unobserved-before-exit"] and \
        dead["exe"] is None and dead["role"] == "unknown-image" and \
        dead["prior_images"][0]["exe"] == PC_FAKE and h["closure_verified"] is True and \
        h["exec_unobserved"] == 1 and h["verdict"] is False and \
        h["api_client_history"] == "unknown" and not res["complete"] and \
        "H: not established" in res["reasons"] and "watcher violations: 1" in res["reasons"] and \
        no_malformed_h(res["reasons"]) and w.signals_frozen
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
                   runroot, notes={"baseline": base["reasons"], "violations": kinds,
                                   "reasons": res["reasons"]})


def t22b(d, scratch, runroot):
    T = "T22b"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root, closure=True)
    base, _ = h_check(w)
    me = W.bsdinfo(os.getpid())
    w.entries[os.getpid()] = {"pid": os.getpid(), "birth_us": me["birth_us"], "lineage": True,
                              "role": "shell", "exit": None, "parent": None}
    c = start_fixture(d, T, "child", "import time; time.sleep(3)")
    real = W.pidpath

    def failing(pid):
        if pid == c.pid:
            raise W.Hold("injected image read failure (fixture-synthetic)")
        return real(pid)
    W.pidpath = failing
    held = False
    try:
        w.admit(c.pid, os.getpid(), "T22b")
    except W.Hold:
        held = True
    finally:
        W.pidpath = real
    kinds = [v["kind"] for v in w.violations]
    res, h = h_check(w)
    reap(c, D_REAP)
    dispose(d, T, "root")
    ok = base["complete"] is True and held and kinds == ["admission-image-unreadable-live"] and \
        h["closure_verified"] is True and h["admission_unreadable_live"] == 1 and \
        h["verdict"] is False and not res["complete"] and \
        "H: not established" in res["reasons"] and no_malformed_h(res["reasons"])
    return verdict(d, T, ["HOLD"], "HOLD" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes={"baseline": base["reasons"], "violations": kinds, "h": h,
                          "reasons": res["reasons"]})


def t22c(d, scratch, runroot):
    T = "T22c"
    cases = {}
    st, sn, lk = healthy_now()
    cases["baseline"] = classify(st, sn, lk)["complete"]
    st, sn, lk = healthy_now()
    del st["h"]
    cases["h_removed"] = classify(st, sn, lk)["complete"]
    st, sn, lk = healthy_now()
    cases["closure_false"] = classify(st, sn, lk, closure_ok=False)["complete"]
    st, sn, lk = healthy_now()
    del st["h"]["exec_unobserved"]
    cases["field_missing"] = classify(st, sn, lk)["complete"]
    st, sn, lk = healthy_now()
    st["h"]["image_violations"] = "0"
    cases["wrong_type"] = classify(st, sn, lk)["complete"]
    st, sn, lk = healthy_now()
    st["h"]["image_violations"] = 1
    cases["true_with_failing_component"] = classify(st, sn, lk)["complete"]
    ok = cases["baseline"] is True and all(v is False for k, v in cases.items() if k != "baseline")
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL",
                   {"fixtures": "not-applicable:synthetic records only"}, runroot,
                   notes={"complete": cases, "proof": "fixture-synthetic"})


def t22d(d, scratch, runroot):
    """D-1 exact forms: four positives and the extra-command/wrong-parent/nesting negatives."""
    T = "T22d"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root, port=25432)
    m = w.m
    P = W.PG_BIN + "/postgres"
    pgd, rt = m["pgdata"], m["runtime"]
    opts = "-c unix_socket_directories=%s/postgres -c listen_addresses= -p 25432" % rt
    pgctl_child = '/bin/sh -c exec "%s" -D "%s" %s < "/dev/null" 2>&1' % (P, pgd, opts)
    check = ('sh -c "%s" --check -F -c log_checkpoints=false  -c max_connections=100 '
             '-c autovacuum_worker_slots=16 -c shared_buffers=16384 '
             '-c dynamic_shared_memory_type=posix < "/dev/null" > "/dev/null" 2>&1' % P)
    boot = 'sh -c "%s" --boot -F -c log_checkpoints=false  -X 16777216 -k' % P
    single = ('sh -c "%s" --single -F -O -j -c search_path=pg_catalog -c exit_on_error=true '
              '-c log_checkpoints=false  template1 >/dev/null' % P)
    parents = {"pgctl": (W.PG_BIN + "/pg_ctl", "pg_ctl -D %s -w start -o %s" % (pgd, opts)),
               "pgctl_stop": (W.PG_BIN + "/pg_ctl", "pg_ctl -D %s -m fast -w stop" % pgd),
               "initdb": (W.PG_BIN + "/initdb", "initdb --locale=C --encoding=UTF8"),
               "psql": (W.PG_BIN + "/psql", "psql --dbname postgres")}
    pid = [5000]

    def mk(exe, args, parent=None):
        pid[0] += 1
        e = {"pid": pid[0], "birth_us": pid[0], "exe": exe, "args": args, "lineage": True,
             "parent": parent["pid"] if parent else None,
             "parent_birth_us": parent["birth_us"] if parent else None, "exit": None,
             "execs": 0, "admitted": W.now()}
        e["role"] = w.classify(e)
        w.entries[e["pid"]] = e
        return e

    def allowed(pkey, child_args, nested=False):
        before = len(w.violations)
        pe = mk(*parents[pkey])
        if nested:
            pe = mk("/bin/sh", pgctl_child, pe)
        ce = mk("/bin/sh", child_args, pe)
        w.check_exe(ce)
        return len(w.violations) == before and "allowance" in ce

    cases = {
        "pgctl_ok": allowed("pgctl", pgctl_child),
        "check_ok": allowed("initdb", check),
        "boot_ok": allowed("initdb", boot),
        "single_ok": allowed("initdb", single),
        "extra_semicolon": allowed("pgctl", pgctl_child + "; /usr/bin/true"),
        "extra_andand": allowed("initdb", boot + " && x"),
        "extra_option": allowed("initdb", boot + " -c foo=bar"),
        "other_pgdata": allowed("pgctl", pgctl_child.replace(pgd, pgd + "-other")),
        "wrong_parent_psql": allowed("psql", boot),
        "wrong_parent_argv": allowed("pgctl_stop", pgctl_child),
        "nested_shell": allowed("pgctl", pgctl_child, nested=True),
        "unreadable_args": allowed("initdb", None),
    }
    pe = mk(*parents["pgctl"])
    ce = mk("/bin/sh", pgctl_child, pe)
    w.check_exe(ce)
    real = (W.pidpath, W.proc_args, W.bsdinfo)
    W.pidpath = lambda p: "/usr/bin/true"
    W.proc_args = lambda p: "/usr/bin/true"
    W.bsdinfo = lambda p: {"birth_us": ce["birth_us"], "pid": p, "ppid": 0, "uid": 0, "comm": "x"}
    before = len(w.violations)
    try:
        w.on_exec(ce, gone=False)
    finally:
        W.pidpath, W.proc_args, W.bsdinfo = real
    cases["exec_other_image"] = len(w.violations) == before
    dispose(d, T, "root")
    positives = ("pgctl_ok", "check_ok", "boot_ok", "single_ok")
    ok = all(cases[k] for k in positives) and not any(v for k, v in cases.items()
                                                      if k not in positives)
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes={"allowed": cases, "proof": "fixture-synthetic"})


# ---------------------------------------------------------------- T23 (H4, M4)
def t23(d, scratch, runroot, variant):
    T = "T23" + variant
    st, sn, lk = healthy_now()
    t0 = sn["SNAP-0"]["t"]
    if variant == "a":
        st["dead"] += [
            {"pid": 900, "birth_us": 900, "role": "postmaster-init", "parent": None,
             "parent_birth_us": None, "admitted": t0 - 30, "lineage": False,
             "exit": {"kind": "exited", "code": 0, "t": t0 - 20}},
            {"pid": 901, "birth_us": 901, "role": "pg-logger", "parent": 900, "parent_birth_us": 900,
             "admitted": t0 - 29, "lineage": True,
             "exit": {"kind": "exited", "code": 0, "t": t0 - 19}}]
        res = classify(st, sn, lk)
        ok = res["complete"] and len(res["init_facts"]) == 1
        want = "PASS"
    elif variant == "b":
        st["dead"].append({"pid": 950, "birth_us": 950, "role": "postmaster-final", "parent": 1003,
                           "parent_birth_us": 1003000, "admitted": t0 + 0.5, "lineage": True,
                           "exit": {"kind": "exited", "code": 0, "t": t0 + 0.6}})
        res = classify(st, sn, lk)
        ok = not res["complete"]
        want = "INCOMPLETE"
    elif variant == "c":
        for e in st["dead"]:
            if e["role"] == "postmaster-final":
                e["exit"]["code"] = 1
        res = classify(st, sn, lk)
        counts = [{"marker": k, "class": "collector-sink", "count": 1} for k in W.P_EXPECT]
        j = W.judge("P", counts, {}, res["complete"])
        ok = not res["complete"] and j["pass"] is False
        want = "INCOMPLETE"
    elif variant == "d":
        sn["SNAP-post"]["violations"] = [("capture-replaced", "/x")]
        res = classify(st, sn, lk)
        j = W.judge("A", [], {}, res["complete"])
        ok = not res["complete"] and j["pass"] is False
        want = "INCOMPLETE"
    else:
        # M4: the wrapper's allowed exit moves after devenv-tasks (+1.0), before pc (+2.0)
        base = classify(*healthy_now())
        for e in st["dead"]:
            if e["role"] == "wrapper":
                e["exit"]["t"] = st["marks"]["stop_begin"] + 1.1
        res = classify(st, sn, lk)
        ok = base["complete"] is True and not res["complete"] and \
            [r for r in res["reasons"] if r.startswith("disallowed exit devenv-tasks")] and \
            res["window"]["job_chain"] == [{"pid": 1003, "birth_us": 1003000, "role": "wrapper"}]
        want = "INCOMPLETE"
    return verdict(d, T, [want], want if ok else "FAIL",
                   {"fixtures": "not-applicable:synthetic records only"}, runroot,
                   notes={"reasons": res["reasons"], "proof": "fixture-synthetic"})


# ---------------------------------------------------------------- T24 (cross-snapshot, H7/D-8)
def t24(d, scratch, runroot):
    T = "T24"
    root = mkroot(d, scratch, T, "root", ["tasks.db", "SNAP-pre", "SNAP-pre/copy",
                                          "SNAP-pre/snapshot.json", "SNAP-post", "SNAP-post/copy",
                                          "SNAP-post/snapshot.json", "markers.json"])
    src = root + "/tasks.db"
    marker = "0123456789abcdef0123456789abcdef"
    with open(src, "w") as f:
        f.write("row %s\n" % marker)
    pre = root + "/SNAP-pre"
    os.mkdir(pre, 0o700)
    meta = W.snap_file(src, pre + "/copy")
    meta.update({"class": "manager-cache", "append_only": False, "copy": "copy"})
    W.jdump({"files": {src: meta}}, pre + "/snapshot.json")
    with open(src, "w") as f:
        f.write("row rewritten\n")
    post = root + "/SNAP-post"
    os.mkdir(post, 0o700)
    meta2 = W.snap_file(src, post + "/copy")
    meta2.update({"class": "manager-cache", "append_only": False, "copy": "copy"})
    W.jdump({"files": {src: meta2}}, post + "/snapshot.json")
    mk = root + "/markers.json"
    W.jdump({"inst": "B", "epoch": "E1", "markers": {"S_u": marker}}, mk)
    only_post = W.cross_check([(post, "B")], [mk])
    all_snaps = W.cross_check([(pre, "B"), (post, "B")], [mk])
    dispose(d, T, "root")
    ok = only_post["pass"] is True and all_snaps["pass"] is False
    return verdict(d, T, ["FAIL-CROSS-CHECK"], "FAIL-CROSS-CHECK" if ok else "FAIL",
                   {"fixtures": "ok"}, runroot,
                   notes={"post_only_pass": only_post["pass"], "all_pass": all_snaps["pass"]})


# ---------------------------------------------------------------- T26 (M2)
class StubKq(object):
    """fixture-synthetic kqueue: delivers the given events once, then nothing."""

    def __init__(self, events):
        self.events = list(events)

    def control(self, changes, n, timeout=None):
        out, self.events = self.events, []
        return out


def t26a(d, scratch, runroot):
    """An image violation delivered DURING signal_verified's drain refuses the signal."""
    T = "T26a"
    root = mkroot(d, scratch, T, "root")
    w, procs = watch_with(d, T, root, [("pc", "process-compose", "", None)], closure=True)
    p = procs["pc"]
    birth = W.bsdinfo(p.pid)["birth_us"]
    w.kq = StubKq([FakeEv(p.pid, W.NOTE_EXEC)])
    real = (W.pidpath, W.proc_args)
    W.pidpath = lambda pid: "/usr/bin/true"
    W.proc_args = lambda pid: "/usr/bin/true"
    refused = False
    try:
        w.signal_verified(p.pid, signal.SIGTERM, "T26a")
    except W.Hold as h:
        refused = "during the drain" in str(h)
    finally:
        W.pidpath, W.proc_args = real
    kinds = [v["kind"] for v in w.violations]
    alive = (W.bsdinfo(p.pid) or {}).get("birth_us") == birth
    rcs = outer_reap(procs)
    dispose(d, T, "root")
    ok = refused and kinds == ["exe-not-allowlisted"] and w.signals_frozen and alive and \
        w.harness_signals == []
    return verdict(d, T, ["HOLD"], "HOLD" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"pc": 0}), "fixtures": "ok"}, runroot,
                   notes={"violations": kinds, "alive_after": alive})


def t26b(d, scratch, runroot):
    """S5: a foreign-listener Hold propagates; only NotReady is retried."""
    T = "T26b"
    root = mkroot(d, scratch, T, "root", PG_DIRS + [".devenv/state/postgres/log", "state.json"])
    os.makedirs(root + "/.devenv/state/postgres/log", 0o700)
    state_path = root + "/state.json"
    W.jdump({"live": [], "dead": [], "events": [], "gaps": [], "violations": []}, state_path)
    m = fake_manifest(root)
    real = (W.listener_proof, W.tcp_listeners)
    out = {}
    try:
        W.tcp_listeners = lambda port: []

        def foreign(m_, st):
            raise W.Hold("FOREIGN-LISTENER fixture-synthetic")
        W.listener_proof = foreign
        try:
            W.s5_observe(m, state_path, 1.0)
            out["foreign"] = "returned"
        except W.NotReady:
            out["foreign"] = "not-ready"
        except W.Hold:
            out["foreign"] = "hold"

        def pending(m_, st):
            raise W.NotReady("no final postmaster yet")
        W.listener_proof = pending
        r = W.s5_observe(m, state_path, 1.0)
        out["pending"] = "accepting-none" if r["accepting"] is None else "accepting"
    finally:
        W.listener_proof, W.tcp_listeners = real
    dispose(d, T, "root")
    ok = out == {"foreign": "hold", "pending": "accepting-none"}
    return verdict(d, T, ["HOLD"], "HOLD" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=out)


def t26c(d, scratch, runroot):
    """A live helper at finalization is HOLD with a receipt; nothing is signalled."""
    T = "T26c"
    root = mkroot(d, scratch, T, "root", ["watch-state.json"])
    w = bare_watch(root)
    hp = start_fixture(d, T, "helper", "import time; time.sleep(%d)" % L_FIXTURE)
    w.helpers = [hp]
    held = W.finalize(w, reap_s=1.0)
    kinds = [v["kind"] for v in w.violations]
    rcs = outer_reap({"helper": hp})
    dispose(d, T, "root")
    ok = held is True and kinds == ["helper-not-reaped"] and w.signals_frozen and \
        w.harness_signals == []
    return verdict(d, T, ["HOLD"], "HOLD" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"helper": 0}), "fixtures": "ok"}, runroot,
                   notes={"violations": kinds})


# ---------------------------------------------------------------- T27 (choice 5, Q4)
def t27(d, scratch, runroot):
    """The supplementary pre-connect predicate: one valid target and the no-connect
    negatives (absent, wrong type, symlink, foreign lock, symlinked lock, non-canonical)."""
    T = "T27"
    names = []
    for port in range(25432, 25438):
        names += [".s.PGSQL.%d" % port, ".s.PGSQL.%d.lock" % port]
    intent(d, T, "sockdir", "dir", names + ["lock-target"])
    sdir = tempfile.mkdtemp(prefix="sk27", dir="/private/tmp")
    set_identity(d, T, "sockdir", path_identity(sdir))
    canon = os.path.realpath(sdir)
    me = str(os.getpid())
    socks = []

    def bound(port, lock_text=None, lock_link=False):
        s = socket.socket(socket.AF_UNIX)
        s.bind("%s/.s.PGSQL.%d" % (sdir, port))
        socks.append(s)
        lp = "%s/.s.PGSQL.%d.lock" % (sdir, port)
        if lock_link:
            with open(sdir + "/lock-target", "w") as f:
                f.write(me + "\n")
            os.symlink(sdir + "/lock-target", lp)
        elif lock_text is not None:
            with open(lp, "w") as f:
                f.write(lock_text)

    bound(25432, me + "\n/x\n")
    with open("%s/.s.PGSQL.25434" % sdir, "w") as f:
        f.write("not a socket")
    os.symlink("%s/.s.PGSQL.25432" % sdir, "%s/.s.PGSQL.25435" % sdir)
    bound(25436, str(int(me) + 1) + "\n")
    bound(25437, lock_link=True)

    def check(port, sd=sdir, cd=canon):
        try:
            W.target_socket_check(sd, cd, port, me)
            return "ok"
        except W.Refuse as r:
            return str(r).split(" ", 1)[1] if " " in str(r) else str(r)

    got = {"valid": check(25432), "absent": check(25433), "not_socket": check(25434),
           "symlink": check(25435), "foreign_lock": check(25436), "lock_symlink": check(25437),
           "non_canonical": check(25432, cd=canon + "-other")}
    for s in socks:
        s.close()
    dispose(d, T, "sockdir")
    want = {"valid": "ok", "absent": "socket absent", "not_socket": "not an owned socket",
            "symlink": "not an owned socket", "foreign_lock": "lock names another process",
            "lock_symlink": "lock is a symlink",
            "non_canonical": "socket dir not the canonical runtime dir"}
    ok = got == want
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=got)


# ---------------------------------------------------------------- injections (T15a-c)
def inject(kind, path, pid=None):
    if kind == "truncate":
        size = os.path.getsize(path)
        with open(path, "r+") as f:
            f.truncate(0)
            f.write("T" * (size + 4096))
    elif kind == "rename-over":
        tmp = path + ".fixture"
        with open(tmp, "w") as f:
            f.write("replacement\n")
        os.replace(tmp, path)
    elif kind == "new-collector":
        name = time.strftime("postgresql-%Y-%m-%d_%H%M%S.log", time.gmtime(time.time() + 3600))
        fd = os.open(os.path.join(path, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    elif kind == "postmaster-pid":
        with open(path, "w") as f:
            f.write("%s\n" % pid)
    else:
        raise RealUncertainty("unknown injection")
    return {"injected": kind, "path": path}


# ---------------------------------------------------------------- CLI
SYNTHETIC = {
    "T9a": t9a, "T9b": t9b, "T10": t10, "T11": t11, "T12": t12, "T15d": t15d, "T16": t16,
    "T17a": lambda d, s, r: t17(d, s, r, "a"), "T17b": lambda d, s, r: t17(d, s, r, "b"),
    "T17-baseline": t17_baseline,
    "T18a": lambda d, s, r: t18(d, s, r, "a"), "T18b": lambda d, s, r: t18(d, s, r, "b"),
    "T18c": lambda d, s, r: t18(d, s, r, "c"), "T18d": lambda d, s, r: t18(d, s, r, "d"),
    "T18d-vanish": lambda d, s, r: t18(d, s, r, "d-vanish"),
    "T18d-rebind": lambda d, s, r: t18(d, s, r, "d-rebind"),
    "T19a": t19a, "T19b": t19b, "T19c": t19c, "T19d": t19d, "T19f": t19f, "T19g": t19g,
    "T19i": t19i,
    "T20a": lambda d, s, r: t20(d, s, r, "a"), "T20b": lambda d, s, r: t20(d, s, r, "b"),
    "T20c": lambda d, s, r: t20(d, s, r, "c"), "T20d": lambda d, s, r: t20(d, s, r, "d"),
    "T20e": lambda d, s, r: t20(d, s, r, "e"), "T20f": lambda d, s, r: t20(d, s, r, "f"),
    "T21a": lambda d, s, r: t21(d, s, r, "a"), "T21b": lambda d, s, r: t21(d, s, r, "b"),
    "T21c": lambda d, s, r: t21(d, s, r, "c"), "T21d": lambda d, s, r: t21(d, s, r, "d"),
    "T21e": t21e,
    "T22a": t22a, "T22b": t22b, "T22c": t22c, "T22d": t22d,
    "T23a": lambda d, s, r: t23(d, s, r, "a"), "T23b": lambda d, s, r: t23(d, s, r, "b"),
    "T23c": lambda d, s, r: t23(d, s, r, "c"), "T23d": lambda d, s, r: t23(d, s, r, "d"),
    "T23e": lambda d, s, r: t23(d, s, r, "e"),
    "T24": t24, "T26a": t26a, "T26b": t26b, "T26c": t26c, "T27": t27,
}


def main(argv):
    cmd, a = argv[0], W.parse_kv(argv[1:])
    try:
        if "gate" in a:
            W.wait_gate(a.pop("gate"))
        if cmd == "intent":
            contents = [x for x in a.get("contents", "").split(",") if x]
            intent(a["dir"], a["test"], a["label"], a["kind"], contents)
        elif cmd == "identity-path":
            set_identity(a["dir"], a["test"], a["label"], path_identity(a["path"]))
        elif cmd == "identity-proc":
            set_identity(a["dir"], a["test"], a["label"], proc_identity(a["pid"], a["ppid"]))
        elif cmd == "retain":
            retain(a["dir"], a["test"], a["labels"].split(","),
                   [x for x in a.get("manifests", "").split(",") if x])
        elif cmd == "dispose":
            W.jdump({"result": dispose(a["dir"], a["test"], a["label"])})
        elif cmd == "kill-fixture":
            W.jdump({"result": kill_fixture(a["dir"], a["test"], a["label"])})
        elif cmd == "wait-gone":
            ident = lookup(a["dir"], a["test"], a["label"])["identity"]
            ok = wait_gone(ident, float(a.get("deadline", D_REAP)))
            W.jdump({"gone": ok})
            return 0 if ok else 3
        elif cmd == "observed-class":
            W.jdump({"class": observed_class(open(a["file"]).read())})
        elif cmd == "t5-class":
            W.jdump({"class": t5_class(a["pgdata"], a["port"], a["exists"])})
        elif cmd == "exit-stop-allowed":
            return 0 if exit_stop_allowed(a["status"]) else 3
        elif cmd == "check-receipt":
            return 0 if receipt_ok(a["dir"], a["test"]) else 3
        elif cmd == "verdict":
            rec = verdict(a["dir"], a["test"], a["expected"].split(","), a["observed"],
                          json.loads(a["teardown"]), a["runroot"],
                          [x for x in a.get("retained_manifests", "").split(",") if x],
                          json.loads(a.get("notes", "{}")))
            W.jdump(rec)
            return 0 if rec["verdict"] in PASSING else (
                3 if rec["verdict"] == "REAL-UNCERTAINTY" else 4)
        elif cmd == "summary":
            out = summary(a["dir"], a["head"], a["ids"].split(","), a.get("runroot"))
            W.jdump(out)
            return 0 if out["pass"] else 4
        elif cmd == "inject":
            W.jdump(inject(a["kind"], a["path"], a.get("pid")))
        elif cmd == "state-has-pid":
            st = W.jload(a["state"])
            pid = int(a["pid"])
            W.jdump({"admitted": any(e["pid"] == pid for e in st["live"] + st["dead"])})
        elif cmd == "state-live-role":
            st = W.jload(a["state"])
            W.jdump({"live": any(e["role"] == a["role"] and e["exit"] is None
                                 for e in st["live"])})
        elif cmd == "incomplete-class":
            cls = W.jload(a["file"])
            if cls.get("complete") is not False:
                obs = "COMPLETE"
            else:
                hits = [x for x in a["subs"].split(",") if any(x in r for r in cls["reasons"])]
                obs = "INCOMPLETE:" + hits[0] if hits else "INCOMPLETE-OTHER"
            W.jdump({"class": obs})
        elif cmd == "fixture-tcp-decoy":
            fixture_tcp_decoy(a["addr"], a["port"], a["count_file"])
        elif cmd == "fixture-unix-listener":
            fixture_unix_listener(a["path"])
        elif cmd == "fixture-cwd-holder":
            fixture_cwd_holder(a["cwd"])
        elif cmd == "fixture-sleeper":
            fixture_sleeper(a.get("seconds", "600"))
        elif cmd == "synthetic":
            fn = SYNTHETIC.get(a["id"])
            if fn is None:
                return 64
            rec = fn(a["dir"], a["scratch"], a["runroot"])
            W.jdump(rec)
            return 0 if rec["verdict"] in PASSING else (
                3 if rec["verdict"] == "REAL-UNCERTAINTY" else 4)
        else:
            return 64
        return 0
    except (RealUncertainty, W.Hold) as h:
        sys.stderr.write("HOLD REAL-UNCERTAINTY %s\n" % h)
        return 3
    except (W.Fail, W.Refuse) as f:
        # unexpected inside a self-test: uncertainty, never a pass or a plain failure
        sys.stderr.write("HOLD REAL-UNCERTAINTY unexpected %s\n" % type(f).__name__)
        return 3
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        sys.stderr.write("HOLD IO %s\n" % type(e).__name__)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
