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
import errno
import hashlib
import io
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
sys.dont_write_bytecode = True  # F7: before the local import (-I ignores the env variable)
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
        "T20f", "T20g", "T21a", "T21b", "T21c", "T21d", "T21e", "T22a", "T22b", "T22d", "T24", "T27"],
       fixtures=REQ)
_proof(["T17-baseline", "T22c", "T23a", "T23b", "T23c", "T23d", "T23e", "T26d", "T28a", "T28b",
        "T28c", "T29a", "T29b", "T33"], fixtures=NA)
_proof(["T19a"], launcher_reap=REQ, fixtures=REQ)
_proof(["T19b", "T19c", "T19d", "T19f", "T19g", "T19i", "T26a", "T26c"], outer_reap=REQ,
       fixtures=REQ)
_proof(["T26b"], fixtures=REQ)
# T4a repair controls (r2, r3, B1-B4): T35 and T30m are the capability/layout gates
_proof(["T30c", "T30d", "T30e", "T30f", "T30g", "T30i", "T30j", "T30k", "T30l", "T30m",
        "T31a", "T31b", "T31c", "T31d", "T31e", "T31f", "T31g", "T34", "T35", "T36a", "T36b",
        "T36c", "T36d"], fixtures=REQ)
_proof(["T30a", "T30b", "T30n", "T30o", "T30p", "T32", "T37"], fixtures=NA)
# 930cad6 review: R1 (T30q), R2 (T30r, T30s, T30t), R4 (T38)
_proof(["T30q", "T30r", "T30s", "T30t", "T38"], fixtures=REQ)
# a40f005 review: T30w (KERN_PROCARGS2 interface bounds), T30x (T30m exception-path joins)
_proof(["T30w"], fixtures=NA)
_proof(["T30x"], fixtures=REQ)
# e3d897b review: R2 (T31h, T30u), R3 (T30v)
_proof(["T31h", "T30u"], fixtures=REQ)
_proof(["T30v"], fixtures=NA)
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
    p = subprocess.Popen([PY, "-I", "-B", "-c", code] + [str(a) for a in args],
                         stdin=kw.get("stdin", subprocess.DEVNULL),
                         stdout=kw.get("stdout", subprocess.DEVNULL),
                         cwd=kw.get("cwd"), close_fds=True, pass_fds=kw.get("pass_fds", ()))
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


def finish(labels, d, test_id, expected, observed, teardown, runroot, retained_manifests=(),
           notes=None, contract=None):
    """R2: the functional outcome and every proof available now are decided BEFORE any
    disposal. Only an expected outcome with a complete proof authorizes disposing `labels`
    (validated by dispose); otherwise every registered object is RETAINED for disposition and
    the non-passing receipt (FAIL or REAL-UNCERTAINTY) stops the suite."""
    pre = proof_problems(test_id, teardown, contract)
    if observed not in expected or pre:
        rec = {"id": test_id, "expected": list(expected), "observed": observed,
               "verdict": "REAL-UNCERTAINTY" if pre else "FAIL", "teardown": teardown,
               "problems": ["retained for disposition, not disposed: %r" % list(labels)],
               "bad_teardown": pre, "retained": list(labels), "notes": notes or {}}
        W.jdump(rec, "%s/%s.json" % (d, test_id))
        return rec
    for label in labels:
        dispose(d, test_id, label)
    return verdict(d, test_id, expected, observed, teardown, runroot, retained_manifests,
                   notes, contract)


def precheck(d, test_id, expected, observed, partial):
    """R2 for shell tests: before any disposal or cleanup, the observed class must be
    expected and every proof field known so far must be acceptable. Otherwise a retaining
    non-passing receipt is written and the caller stops (no disposal, no cleanup)."""
    c = REQUIRED_PROOF.get(test_id)
    bad = [] if c is not None else ["no proof contract for %s" % test_id]
    if c is not None:
        sub = {k: v for k, v in c.items() if k in partial}
        bad = ["unknown proof field %s" % k for k in sorted(set(partial) - set(c))] + \
            proof_problems(test_id, partial, sub)
    if observed in expected and not bad:
        return True
    W.jdump({"id": test_id, "expected": list(expected), "observed": observed,
             "verdict": "REAL-UNCERTAINTY" if bad else "FAIL", "teardown": partial,
             "problems": ["retained for disposition before disposal/cleanup"],
             "bad_teardown": bad, "notes": {}}, "%s/%s.json" % (d, test_id))
    return False


T5_CASES = {"bad-pgdata": {"status": 2, "halt": "identity mismatch: data_directory,config_file"},
            "bad-port": {"status": 2, "halt": "target socket mismatch"},
            "db-exists": {"status": 0, "exists": False}}


def client_gate(path, actual, case):
    """R1: one T5 client's ACTUAL exit status and its exact receipt, checked before the next
    client or effect. Only the specified status-2/halt pairs and the db-exists positive pass;
    a missing, malformed or inconsistent receipt, or any other status, fails the gate."""
    want = T5_CASES.get(case)
    if want is None:
        return "unknown case"
    if not os.path.exists(path):
        return "no receipt"
    try:
        rec = W.jload(path)
    except (ValueError, OSError):
        return "malformed receipt"
    if not isinstance(rec, dict) or rec.get("status") != int(actual):
        return "receipt status disagrees with the actual exit status %s" % actual
    if rec.get("status") != want["status"]:
        return "status %s, not %s" % (rec.get("status"), want["status"])
    if "halt" in want and rec.get("halt") != want["halt"]:
        return "unexpected halt reason"
    if "exists" in want and (rec.get("exists") is not want["exists"] or "halt" in rec):
        return "unexpected db-exists result"
    return "ok"


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
    want = {k: (v["status"], v["halt"]) for k, v in T5_CASES.items() if "halt" in v}
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
    """fixture-synthetic kevent (ident, fflags, data, udata = registration token, flags)."""

    def __init__(self, ident, fflags, data=0, udata=0, flags=0):
        self.ident, self.fflags, self.data, self.udata, self.flags = \
            ident, fflags, data, udata, flags


class StubKq(object):
    """fixture-synthetic kqueue driving the REAL fence/process/snapshot code into a
    deterministic order: each control() returns the next batch (at most n events of it);
    an exhausted script returns []; `forever` repeats its batch. Registrations are refused."""

    def __init__(self, batches, forever=None):
        self.batches = [list(b) for b in batches]
        self.forever = forever
        self.calls = 0

    def control(self, changes, n, timeout=None):
        self.calls += 1
        if changes:
            raise OSError(1, "stub kqueue takes no registrations")
        if self.forever is not None and not self.batches:
            return list(self.forever)[:n]
        if not self.batches:
            return []
        b = self.batches[0]
        out, self.batches[0] = b[:n], b[n:]
        if not self.batches[0]:
            self.batches.pop(0)
        return out


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
                        "g=subprocess.Popen([sys.executable,'-I','-B','-c','import time; time.sleep(%d)']);"
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
        labels = ['root']  # disposed by finish() only after a validated outcome (R2)
        return finish(labels, d, T, ["REFUSE-SIGNAL"], "INCONCLUSIVE-NO-SAME-SECOND-PAIR",
                       {"fixtures": "ok"}, runroot)
    d2, i1, i2, l1, l2 = found
    notes = {"lstart_equal": True, "us_distinct": i1["birth_us"] != i2["birth_us"]}
    if not notes["us_distinct"]:
        d2.terminate()
        reap(d2, D_REAP)
        labels = ['root']  # disposed by finish() only after a validated outcome (R2)
        return finish(labels, d, T, ["REFUSE-SIGNAL"], "INCONCLUSIVE-EQUAL-US", {"fixtures": "ok"},
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    notes.update({"old_predicate_matches": old_match, "new_rule_refused": refused,
                  "d2_not_signalled": alive, "label": "emulated PID-reuse record"})
    obs = "REFUSE-SIGNAL" if old_match and refused and alive else "FAIL"
    return finish(labels, d, T, ["REFUSE-SIGNAL"], obs, {"fixtures": "ok"}, runroot, notes=notes)


def t9b(d, scratch, runroot):
    """Changed parent (repair H3): X starts a SELF-TERMINATING Y and exits; admission
    through X and signalling Y both refuse; Y is never signalled and is awaited, bounded."""
    T = "T9b"
    root = mkroot(d, scratch, T, "root")
    x = start_fixture(d, T, "x", "import subprocess,sys;"
                      "y=subprocess.Popen([sys.executable,'-I','-B','-c','import time; time.sleep(6)']);"
                      "print(y.pid,flush=True)", stdout=subprocess.PIPE)
    w = bare_watch(root)
    cur = W.bsdinfo(x.pid)
    if w.adopt(x.pid, "process-compose", image=PY) is None:
        raise RealUncertainty("T9b: X gone before adoption")
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    notes = {"admitted_via_exited_parent": admitted, "signal_refused": refused, "y_alive": alive,
             "stale_admitted": stale_admit, "y_ended_by_itself": gone}
    obs = "REFUSE-ADMISSION" if (not admitted and refused and alive and not stale_admit) else "FAIL"
    return finish(labels, d, T, ["REFUSE-ADMISSION"], obs, {"fixtures": "ok"}, runroot, notes=notes)


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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["FAIL-CLEANUP"], obs, {"fixtures": "ok"}, runroot)


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
    labels = ['sentinel']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["FAIL-SYMLINK"], obs, {"fixtures": "ok"}, runroot,
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["FAIL-UNREADABLE"], obs, {"fixtures": "ok"}, runroot)


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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
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
    if w.adopt(f.pid, "fixture-writer", image=PY, argv=["F"]) is None:
        raise RealUncertainty("T17: F gone before adoption")
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
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
    return finish(labels, d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
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
    labels = ['root', 'sockdir']  # disposed by finish() only after a validated outcome (R2)
    notes = {"eacces_after_lock": eacces, "complete": res["complete"], "reasons": res["reasons"],
             "socket_post": socket_post, "proof": "fixture-synthetic"}
    if variant == "d":
        ok = res["complete"] and eacces == "errno-13" and socket_post == "unlinked"
        return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                       notes=notes)
    ok = (not res["complete"]) and (eacces == "errno-13" or variant.startswith("d-"))
    return finish(labels, d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
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
        if w.adopt(p.pid, role, image=PY, argv=[label]) is None:
            raise RealUncertainty("fixture %s/%s gone before adoption" % (T, label))
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["HOLD-LAUNCHER-UNREGISTERED"], "HOLD-LAUNCHER-UNREGISTERED" if ok else
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = res["ok"] is False and [r["role"] for r in res["remaining"]] == ["launcher"] and frozen \
        and not kills
    return finish(labels, d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    pgctl = [s for s in res["stages"] if s[0] == "pg_ctl"]
    ok = res["ok"] is False and bool(pgctl) and pgctl[0][1] != 0 and \
        any(r["role"] == "postmaster-final" for r in res["remaining"]) and \
        not [s for s in w.harness_signals if s["signal"] == int(signal.SIGKILL)]
    return finish(labels, d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    killed = sorted(s["role"] for s in w.harness_signals if s["signal"] == int(signal.SIGKILL))
    ok = res["ok"] is False and [r["role"] for r in res["remaining"]] == ["pg-aux"] and \
        killed == ["devenv-tasks", "process-compose"]
    return finish(labels, d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = res["ok"] is False and "overall deadline passed before pc-term" in res.get("hold", "") \
        and sent == [("launcher", int(signal.SIGTERM))]
    return finish(labels, d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    obs = subject if took <= 2.0 else "SUBJECT-OVERRAN"
    return finish(labels, d, T, ["HOLD-HANDSHAKE"], obs,
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
    w.quiesce = lambda deadline: time.sleep(0.6)  # fixture-synthetic slow fence/drain
    refused_sig = False
    try:
        w.signal_verified(procs["pc"].pid, signal.SIGTERM, "T19i", deadline=W.now() + 0.3)
    except W.Hold as h:
        refused_sig = "deadline" in str(h)
    del w.quiesce
    refused_pgctl = False
    try:
        W.pg_ctl_stop(w, fake_manifest(root), w.alive("postmaster-final"), timeout=5, t=2,
                      deadline=W.now() - 0.01)
    except W.Hold as h:
        refused_pgctl = "deadline" in str(h)
    alive = {k: (W.bsdinfo(p.pid) or {}).get("birth_us") == births[k] for k, p in procs.items()}
    rcs = outer_reap(procs)
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = refused_sig and refused_pgctl and alive == {"pc": True, "pm": True} and \
        w.harness_signals == [] and w.helpers == []
    return finish(labels, d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
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
    "g": ["selftest", "selftest/fixtures.json", "selftest/X.json", "selftest/X2.json", "run",
          "run/ev", "run/ev/evidence"],
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
    elif variant == "g":
        # R2: an unexpected functional result retains its declared, registered evidence;
        # the paired expected result disposes of it. No stray or identity fault involved.
        c = {"fixtures": REQ}
        register_path(pd, "X", "ev", run + "/ev", "dir", ["evidence"])
        with open(run + "/ev/evidence", "w") as f:
            f.write("e")
        bad = finish(["ev"], pd, "X", ["PASS"], "FAIL", {"fixtures": "ok"}, run, contract=c)
        register_path(pd, "X2", "ev2", run + "/ev2", "dir", ["evidence"])
        with open(run + "/ev2/evidence", "w") as f:
            f.write("e")
        good = finish(["ev2"], pd, "X2", ["PASS"], "PASS", {"fixtures": "ok"}, run, contract=c)
        kept = os.path.exists(run + "/ev/evidence")
        notes = {"bad": bad["verdict"], "good": good["verdict"], "kept": kept,
                 "good_gone": not os.path.lexists(run + "/ev2")}
        ok = bad["verdict"] == "FAIL" and kept and good["verdict"] == "PASS" and \
            notes["good_gone"]
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
    labels = ['private']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    want = "PASS" if variant == "a" else "HOLD"
    return finish(labels, d, T, [want], obs, {"fixtures": "ok"}, runroot)


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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
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
    c = start_fixture(d, T, "child", "import time; time.sleep(3)")
    ce = w.adopt(c.pid, "process-compose", image=PC_FAKE)
    if ce is None:
        raise RealUncertainty("T22a: fixture gone before adoption")
    w.handle(FakeEv(c.pid, W.NOTE_EXEC | W.NOTE_EXIT | W.NOTE_EXITSTATUS, 0, udata=ce["gen"]))
    dead = next(x for x in w.dead if x["pid"] == c.pid)
    reap(c, D_REAP)
    kinds = [v["kind"] for v in w.violations]
    res, h = h_check(w)
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = base["complete"] is True and kinds == ["exec-image-unobserved-before-exit"] and \
        dead["image"] is None and dead["role"] == "unknown-image" and \
        dead["prior_images"][0]["image"] == PC_FAKE and h["closure_verified"] is True and \
        h["exec_unobserved"] == 1 and h["verdict"] is False and \
        h["api_client_history"] == "unknown" and not res["complete"] and \
        "H: not established" in res["reasons"] and "watcher violations: 1" in res["reasons"] and \
        no_malformed_h(res["reasons"]) and w.signals_frozen
    return finish(labels, d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
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
    if w.admit(c.pid, os.getpid(), "T22b") is None:
        raise RealUncertainty("T22b: child not admitted")
    W.pidpath = failing
    held = False
    try:
        w.process_requests(W.now() + 2.0)
    except W.Hold:
        held = True
    finally:
        W.pidpath = real
    kinds = [v["kind"] for v in w.violations]
    res, h = h_check(w)
    reap(c, D_REAP)
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = base["complete"] is True and held and kinds == ["admission-image-unreadable-live"] and \
        h["closure_verified"] is True and h["admission_unreadable_live"] == 1 and \
        h["verdict"] is False and not res["complete"] and \
        "H: not established" in res["reasons"] and no_malformed_h(res["reasons"])
    return finish(labels, d, T, ["HOLD"], "HOLD" if ok else "FAIL", {"fixtures": "ok"}, runroot,
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
    """D-1/F2 exact VECTOR forms (r2 1.4, r3 B3/B4): seven positives (pg_ctl start, the two
    version probes, check, boot, single, single-user locale), shim and exec hand-offs, and
    negatives (extra command/option, other pgdata, wrong parent image/argv/role, nested
    shell, absent argv, -V extra option, locale extra argument, other locale image, fork
    from a non-forking role, skipped shell step). fixture-synthetic records except the
    fork case, which uses an adopted live fixture."""
    T = "T22d"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root, port=25432)
    m = w.m
    P = W.PG_BIN + "/postgres"
    pgd, rt = m["pgdata"], m["runtime"]
    opts = "-c unix_socket_directories=%s/postgres -c listen_addresses= -p 25432" % rt
    pgctl_cmd = 'exec "%s" -D "%s" %s < "/dev/null" 2>&1' % (P, pgd, opts)
    check = ('"%s" --check -F -c log_checkpoints=false  -c max_connections=100 '
             '-c autovacuum_worker_slots=16 -c shared_buffers=16384 '
             '-c dynamic_shared_memory_type=posix < "/dev/null" > "/dev/null" 2>&1' % P)
    boot = '"%s" --boot -F -c log_checkpoints=false  -X 16777216 -k' % P
    single = ('"%s" --single -F -O -j -c search_path=pg_catalog -c exit_on_error=true '
              '-c log_checkpoints=false  template1 >/dev/null' % P)
    vprobe = '"%s" -V' % P
    locale = "%s -a" % W.LOCALE_BIN
    single_argv = [P, "--single", "-F", "-O", "-j", "-c", "search_path=pg_catalog", "-c",
                   "exit_on_error=true", "-c", "log_checkpoints=false", "template1"]
    parents = {"pgctl": (W.PG_BIN + "/pg_ctl", ["pg_ctl", "-D", pgd, "-w", "start", "-o", opts],
                         None),
               "pgctl_stop": (W.PG_BIN + "/pg_ctl", ["pg_ctl", "-D", pgd, "-m", "fast", "-w",
                                                     "stop"], None),
               "initdb": (W.PG_BIN + "/initdb", ["initdb", "--locale=C", "--encoding=UTF8"], None),
               "psql": (W.PG_BIN + "/psql", ["psql", "--dbname", "postgres"], None),
               "single": (P, single_argv, "pg-bootstrap"),
               "single_other": (P, single_argv[:-1], "pg-bootstrap"),
               "single_wrong_role": (P, single_argv, "postmaster-init")}
    pid = [5000]

    def mk(image, argv, parent=None, role=None):
        pid[0] += 1
        e = {"pid": pid[0], "birth_us": pid[0], "image": image, "exe": image, "argv": argv,
             "argv_meta": None, "argv_known": False, "lineage": True,
             "parent": parent["pid"] if parent else None,
             "parent_birth_us": parent["birth_us"] if parent else None, "exit": None,
             "execs": 0, "admitted": W.now(), "gen": None}
        e["role"] = role or w.classify(e)
        w.entries[e["pid"]] = e
        return e

    def quiet(fn):
        before = len(w.violations)
        r = fn()
        return r, len(w.violations) == before

    def allowed(pkey, child_argv, nested=False):
        def run():
            img, argv, role = parents[pkey]
            pe = mk(img, argv, role=role)
            if nested:
                pe = mk("/bin/sh", ["/bin/sh", "-c", pgctl_cmd], pe)
                w.check_exe(pe)
            ce = mk("/bin/sh", child_argv, pe)
            w.check_exe(ce)
            return ce
        ce, clean = quiet(run)
        return clean and "allowance" in ce

    def snap(image, argv):
        return {"image": image, "exec_path": image, "argv": argv,
                "meta": W.argv_meta([a.encode() for a in argv]) if argv else None,
                "argv_status": "OK" if argv is not None else None, "cutoff": W.now()}

    def exec_case(pkey, child_argv, image, argv):
        def run():
            img, pargv, role = parents[pkey]
            pe = mk(img, pargv, role=role)
            ce = mk("/bin/sh", child_argv, pe)
            w.check_exe(ce)
            if "allowance" not in ce:
                return None
            w.apply_snapshot(ce, snap(image, argv), "exec")
            return ce["role"]
        role, clean = quiet(run)
        return role if clean else "violation"

    sh_real = os.path.realpath("/private/var/select/sh")
    cases = {
        "pgctl_ok": allowed("pgctl", ["/bin/sh", "-c", pgctl_cmd]),
        "pgctl_probe_ok": allowed("pgctl", ["sh", "-c", vprobe]),
        "initdb_probe_ok": allowed("initdb", ["sh", "-c", vprobe]),
        "check_ok": allowed("initdb", ["sh", "-c", check]),
        "boot_ok": allowed("initdb", ["sh", "-c", boot]),
        "single_ok": allowed("initdb", ["sh", "-c", single]),
        "locale_ok": allowed("single", ["sh", "-c", locale]),
        "extra_semicolon": allowed("pgctl", ["/bin/sh", "-c", pgctl_cmd + "; /usr/bin/true"]),
        "extra_andand": allowed("initdb", ["sh", "-c", boot + " && x"]),
        "extra_option": allowed("initdb", ["sh", "-c", boot + " -c foo=bar"]),
        "split_command": allowed("initdb", ["sh", "-c"] + boot.split(" ")),
        "other_pgdata": allowed("pgctl", ["/bin/sh", "-c", pgctl_cmd.replace(pgd, pgd + "-other")]),
        "wrong_argv0": allowed("pgctl", ["sh", "-c", pgctl_cmd]),
        "wrong_parent_psql": allowed("psql", ["sh", "-c", boot]),
        "wrong_parent_argv": allowed("pgctl_stop", ["/bin/sh", "-c", pgctl_cmd]),
        "nested_shell": allowed("pgctl", ["/bin/sh", "-c", pgctl_cmd], nested=True),
        "absent_argv": allowed("initdb", None),
        "probe_extra_option": allowed("initdb", ["sh", "-c", vprobe + " -x"]),
        "probe_under_psql": allowed("psql", ["sh", "-c", vprobe]),
        "locale_extra_arg": allowed("single", ["sh", "-c", locale + " -x"]),
        "locale_other_single_argv": allowed("single_other", ["sh", "-c", locale]),
        "locale_wrong_parent_role": allowed("single_wrong_role", ["sh", "-c", locale]),
        "locale_under_initdb": allowed("initdb", ["sh", "-c", locale]),
    }
    execs = {
        "probe_exec": exec_case("initdb", ["sh", "-c", vprobe], P, [P, "-V"]) == "pg-version-probe",
        "locale_exec": exec_case("single", ["sh", "-c", locale], W.LOCALE_BIN,
                                 [W.LOCALE_BIN, "-a"]) == "pg-locale",
        "shim_handoff": exec_case("initdb", ["sh", "-c", vprobe], sh_real,
                                  ["sh", "-c", vprobe]) == "pg-sh",
        "shim_changed_argv": exec_case("initdb", ["sh", "-c", vprobe], sh_real,
                                       ["/bin/sh", "-c", vprobe]) == "violation",
        "probe_exec_extra": exec_case("initdb", ["sh", "-c", vprobe], P,
                                      [P, "-V", "-x"]) == "violation",
        "locale_exec_extra": exec_case("single", ["sh", "-c", locale], W.LOCALE_BIN,
                                       [W.LOCALE_BIN, "-a", "-x"]) == "violation",
        "locale_other_image": exec_case("single", ["sh", "-c", locale], "/usr/bin/locale",
                                        ["/usr/bin/locale", "-a"]) == "violation",
        "exec_other_image": exec_case("pgctl", ["/bin/sh", "-c", pgctl_cmd], "/usr/bin/true",
                                      ["/usr/bin/true"]) == "violation",
    }
    # a popen child seen first as a non-shell image: the shell step was skipped
    img, pargv, _ = parents["initdb"]
    pe = mk(img, pargv)
    ce = mk(W.PG_BIN + "/initdb", pargv, pe)      # fork image (pre-exec): allowed
    ce_r, ce_clean = quiet(lambda: w.apply_snapshot(ce, snap(P, [P, "-V"]), "exec"))
    execs["skipped_shell"] = not ce_clean and any(v["kind"] == "exec-chain-unobserved"
                                                  for v in w.violations)
    # fork from a non-forking role, on an adopted live fixture (real generation)
    fx = start_fixture(d, T, "nonforking", "import time; time.sleep(3)")
    fe = w.adopt(fx.pid, "pg-locale", image=W.LOCALE_BIN)
    if fe is None:
        raise RealUncertainty("T22d: fixture gone before adoption")
    before = len(w.violations)
    w.handle(FakeEv(fx.pid, W.NOTE_FORK, udata=fe["gen"]))
    execs["fork_from_pg_locale"] = any(v["kind"] == "fork-from-nonforking-role"
                                       for v in w.violations[before:])
    rc = reap(fx, D_REAP)
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    positives = ("pgctl_ok", "pgctl_probe_ok", "initdb_probe_ok", "check_ok", "boot_ok",
                 "single_ok", "locale_ok")
    ok = all(cases[k] for k in positives) and not any(v for k, v in cases.items()
                                                      if k not in positives) and \
        all(execs.values()) and rc == 0
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                  notes={"allowed": cases, "execs": execs, "proof": "fixture-synthetic"})


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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = only_post["pass"] is True and all_snaps["pass"] is False
    return finish(labels, d, T, ["FAIL-CROSS-CHECK"], "FAIL-CROSS-CHECK" if ok else "FAIL",
                   {"fixtures": "ok"}, runroot,
                   notes={"post_only_pass": only_post["pass"], "all_pass": all_snaps["pass"]})


# ---------------------------------------------------------------- T26 (M2)
def t26a(d, scratch, runroot):
    """An image violation observed DURING signal_verified's quiescing refuses the signal:
    a generation-attributed NOTE_EXEC is fetched by the fence, its snapshot obligation is
    resolved (patched image and argv: /usr/bin/true) and the image check freezes signals."""
    T = "T26a"
    root = mkroot(d, scratch, T, "root")
    w, procs = watch_with(d, T, root, [("pc", "process-compose", "", None)], closure=True)
    p = procs["pc"]
    g = w.entries[p.pid]["gen"]
    birth = W.bsdinfo(p.pid)["birth_us"]
    w.kq = StubKq([[FakeEv(p.pid, W.NOTE_EXEC, udata=g)]])
    real = (W.pidpath, W.procargs)
    W.pidpath = lambda pid: "/usr/bin/true"
    W.procargs = lambda pid, birth_us, reader=None: {
        "status": "OK", "exec_path": "/usr/bin/true", "argv": ["/usr/bin/true"],
        "meta": W.argv_meta([b"/usr/bin/true"])}
    refused = False
    try:
        w.signal_verified(p.pid, signal.SIGTERM, "T26a")
    except W.Hold as h:
        refused = "during the drain" in str(h)
    finally:
        W.pidpath, W.procargs = real
    kinds = [v["kind"] for v in w.violations]
    alive = (W.bsdinfo(p.pid) or {}).get("birth_us") == birth
    rcs = outer_reap(procs)
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = refused and kinds == ["exe-not-allowlisted"] and w.signals_frozen and alive and \
        w.harness_signals == []
    return finish(labels, d, T, ["HOLD"], "HOLD" if ok else "FAIL",
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = out == {"foreign": "hold", "pending": "accepting-none"}
    return finish(labels, d, T, ["HOLD"], "HOLD" if ok else "FAIL", {"fixtures": "ok"}, runroot,
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
    labels = ['root']  # disposed by finish() only after a validated outcome (R2)
    ok = held is True and kinds == ["helper-not-reaped"] and w.signals_frozen and \
        w.harness_signals == []
    return finish(labels, d, T, ["HOLD"], "HOLD" if ok else "FAIL",
                   {"outer_reap": rcs_word(rcs, {"helper": 0}), "fixtures": "ok"}, runroot,
                   notes={"violations": kinds})


# ---------------------------------------------------------------- T27 (choice 5, Q4)
def t27(d, scratch, runroot):
    """The supplementary pre-connect predicate: one valid target and the no-connect
    negatives (absent, wrong type, symlink, foreign lock, symlinked lock, non-canonical)."""
    T = "T27"
    names = []
    for port in range(25432, 25441):
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
    bound(25438)
    os.mkfifo("%s/.s.PGSQL.25438.lock" % sdir, 0o600)      # R3: FIFO lock, no writer
    bound(25439, "1" * 100 + "\n")                          # R3: oversized first line
    bound(25440, "pid-%s\n" % me)                           # R3: malformed first line

    def check(port, sd=sdir, cd=canon):
        try:
            W.target_socket_check(sd, cd, port, me)
            return "ok"
        except W.Refuse as r:
            return str(r).split(" ", 1)[1] if " " in str(r) else str(r)

    got = {"valid": check(25432), "absent": check(25433), "not_socket": check(25434),
           "symlink": check(25435), "foreign_lock": check(25436), "lock_symlink": check(25437),
           "oversized": check(25439), "malformed": check(25440),
           "non_canonical": check(25432, cd=canon + "-other")}
    # The FIFO case runs in a child under its own bounded wait, so a regression that blocks
    # in open() cannot hang this control: on timeout the write end is opened (no signal),
    # which unblocks the reader, and the case is recorded as BLOCKED.
    intent(d, T, "fifo-check", "proc")
    fc = subprocess.Popen([PY, "-I", "-B", os.path.join(HERE, "sink_watch.py"), "target-socket-check",
                           "--socket-dir", sdir, "--canonical-dir", canon, "--port", "25438",
                           "--postmaster-pid", me], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, close_fds=True)
    set_identity(d, T, "fifo-check", proc_identity(fc.pid, os.getpid()))
    try:
        fc.wait(timeout=5.0)
        err = fc.stderr.read().decode("utf-8", "replace")
        got["fifo"] = observed_class(err) + ("/%d" % fc.returncode)
    except subprocess.TimeoutExpired:
        wfd = os.open("%s/.s.PGSQL.25438.lock" % sdir, os.O_WRONLY | os.O_NONBLOCK)
        os.close(wfd)
        reap(fc, D_REAP)
        got["fifo"] = "BLOCKED"
    for s in socks:
        s.close()
    labels = ['sockdir']  # disposed by finish() only after a validated outcome (R2)
    want = {"valid": "ok", "absent": "socket absent", "not_socket": "not an owned socket",
            "symlink": "not an owned socket", "foreign_lock": "lock names another process",
            "lock_symlink": "lock is a symlink", "oversized": "lock first line malformed",
            "malformed": "lock first line malformed", "fifo": "REFUSE-TARGET/2",
            "non_canonical": "socket dir not the canonical runtime dir"}
    ok = got == want
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=got)


# ---------------------------------------------------------------- T4a repair controls (r2, r3, B1-B4)
COREUTILS_SLEEP = W.PKG["coreutils"] + "/bin/sleep"
# argv-tolerant accepting fixture (B3): any argv0 and any trailing arguments; readiness on
# fd 3; waits for one stdin byte, autonomously bounded (8 s)
HOLDER = "import os,select\nos.write(3, b'r\\n')\nselect.select([0], [], [], 8)\n"


def live_fixture(d, T, label, code=None, stdin=None):
    return start_fixture(d, T, label, code or "import time; time.sleep(3)",
                         stdin=stdin if stdin is not None else subprocess.DEVNULL)


def adopt_or_hold(w, p, role, image=None, argv=None):
    e = w.adopt(p.pid, role, image=image, argv=argv)
    if e is None:
        raise RealUncertainty("fixture %d gone before adoption" % p.pid)
    return e


def pa_buf(argc, exec_path, args, env=(), extra_nul=0, pad_bytes=None):
    """A KERN_PROCARGS2-shaped buffer under the H-pad hypothesis (fixture-synthetic)."""
    ep = exec_path if isinstance(exec_path, bytes) else exec_path.encode()
    pad = W.align_up(len(ep) + 1, W.ARGV_ALIGN) - (len(ep) + 1)
    padding = pad_bytes if pad_bytes is not None else b"\0" * pad
    body = ep + b"\0" + padding + b"\0" * extra_nul + b"".join(a + b"\0" for a in args) + \
        b"".join(e + b"\0" for e in env)
    return argc.to_bytes(4, sys.byteorder, signed=True) + body


def parse(buf, cap=None):
    return W.parse_procargs(buf, len(buf), cap or len(buf) + 1)


def t30a(d, scratch, runroot):
    """Parser on byte buffers (pure): closed states, preserved empties, no NUL skipping."""
    T = "T30a"
    got = {
        "valid": parse(pa_buf(3, "/bin/sh", [b"sh", b"-c", b"x y"])),
        "argc0": parse(pa_buf(0, "/bin/sh", [b"sh"])),
        "argc5000": parse(pa_buf(5000, "/bin/sh", [b"sh"])),
        "no_nul_after_path": parse((1).to_bytes(4, sys.byteorder) + b"/bin/shXXXX"),
        "path_too_long": parse(pa_buf(1, b"/" + b"a" * 5000, [b"x"])),
        "pad_not_nul": parse(pa_buf(1, b"/b", [b"x"], pad_bytes=b"\0Z\0\0\0")),
        "empty_argv0": parse(pa_buf(2, "/bin/sh", [b"", b"x"])),
        "internal_empty": parse(pa_buf(3, "/bin/sh", [b"a", b"", b"b"])),
        "truncated": parse(pa_buf(3, "/bin/sh", [b"a", b"b"])[:-1]),
        "n_equals_cap": W.parse_procargs(pa_buf(1, "/bin/sh", [b"sh"]),
                                         len(pa_buf(1, "/bin/sh", [b"sh"])),
                                         len(pa_buf(1, "/bin/sh", [b"sh"]))),
        "n_lt_6": parse(b"\x01\x00\x00\x00/"),
        "bad_utf8": parse(pa_buf(1, "/bin/sh", [b"\xff"])),
    }
    want = {"valid": ("OK", ["sh", "-c", "x y"]), "argc0": ("MALFORMED", None),
            "argc5000": ("MALFORMED", None), "no_nul_after_path": ("MALFORMED", None),
            "path_too_long": ("MALFORMED", None), "pad_not_nul": ("UNSUPPORTED", None),
            "empty_argv0": ("OK", ["", "x"]), "internal_empty": ("OK", ["a", "", "b"]),
            "truncated": ("MALFORMED", None), "n_equals_cap": ("MALFORMED", None),
            "n_lt_6": ("MALFORMED", None), "bad_utf8": ("UNREPRESENTABLE", None)}
    obs = {k: (v["status"], v["argv"]) for k, v in got.items()}
    ok = obs == want and got["bad_utf8"]["meta"]["lengths"] == [1]
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:pure parser"}, runroot,
                   notes={"observed": {k: list(v) for k, v in obs.items()}})


def t30b(d, scratch, runroot):
    """errno mapping with an injected reader and identity (r2 1.3)."""
    T = "T30b"
    me = W.bsdinfo(os.getpid())
    real_bsd = W.bsdinfo
    out = {}

    def reader_err(err):
        return lambda pid, cap: (-1, err, b"", 0)
    try:
        W.bsdinfo = lambda pid: None
        out["einval_gone"] = W.procargs(424242, 1, reader=reader_err(errno.EINVAL))["status"]
        W.bsdinfo = lambda pid: dict(me, birth_us=7)
        for name, err in (("einval_alive", errno.EINVAL), ("esrch_alive", errno.ESRCH),
                          ("eperm", errno.EPERM), ("enomem", errno.ENOMEM)):
            try:
                W.procargs(424242, 7, reader=reader_err(err))
                out[name] = "no-hold"
            except W.Hold:
                out[name] = "HOLD"
        W.bsdinfo = lambda pid: dict(me, birth_us=8)
        out["einval_other_birth"] = W.procargs(424242, 7, reader=reader_err(errno.EINVAL))["status"]
    finally:
        W.bsdinfo = real_bsd
    saved = (W._argmax, W.ARGMAX_RANGE)
    try:
        W._argmax, W.ARGMAX_RANGE = None, (1, 2)
        try:
            W.kern_argmax()
            out["argmax_implausible"] = "no-hold"
        except W.Hold:
            out["argmax_implausible"] = "HOLD"
    finally:
        W._argmax, W.ARGMAX_RANGE = saved
    want = {"einval_gone": "GONE", "einval_alive": "HOLD", "esrch_alive": "HOLD", "eperm": "HOLD",
            "enomem": "HOLD", "einval_other_birth": "GONE", "argmax_implausible": "HOLD"}
    return verdict(d, T, ["PASS"], "PASS" if out == want else "FAIL",
                   {"fixtures": "not-applicable:injected reader"}, runroot, notes=out)


def t30c(d, scratch, runroot):
    """Identity reuse during the reads: never attributed (r2 1.2)."""
    T = "T30c"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    p = live_fixture(d, T, "target")
    e = adopt_or_hold(w, p, "fixture")
    real_bsd, calls = W.bsdinfo, [0]

    def shifting(pid):
        cur = real_bsd(pid)
        if pid == p.pid and cur is not None:
            calls[0] += 1
            if calls[0] >= 2:
                return dict(cur, birth_us=cur["birth_us"] + 1)
        return cur
    try:
        W.bsdinfo = shifting
        res = w.snapshot(e["gen"], W.now() + 2.0)["result"]
    finally:
        W.bsdinfo = real_bsd
    rc = reap(p, D_REAP)
    labels = ["root"]
    ok = res == "GONE" and e["image"] is None and rc == 0
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot, notes={"result": res})


def t30d(d, scratch, runroot):
    """An exec event observed by the POST fence voids the snapshot; once handled, a fresh
    VALID snapshot is recorded (real reads of the live fixture)."""
    T = "T30d"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    p = live_fixture(d, T, "target")
    e = adopt_or_hold(w, p, "fixture")
    g = e["gen"]
    w.kq = StubKq([[], [FakeEv(p.pid, W.NOTE_EXEC, udata=g)]])
    first = w.snapshot(g, W.now() + 2.0)["result"]
    w.process_pending(W.now() + 1.0)
    pending_kind = (w.requests.get(g) or {}).get("kind")
    w.requests.pop(g, None)
    second = w.snapshot(g, W.now() + 2.0)
    rc = reap(p, D_REAP)
    labels = ["root"]
    ok = first == "VOID" and pending_kind == "exec" and second["result"] == "VALID" and \
        os.path.realpath(second["image"]) == os.path.realpath(PY) and rc == 0
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot,
                  notes={"first": first, "second": second["result"]})


def t30e(d, scratch, runroot):
    """No partial attribution: pidpath succeeds but procargs is GONE after a handled exec;
    then the exit arrives. exec-image-unobserved-before-exit, no image, no argv."""
    T = "T30e"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    p = live_fixture(d, T, "target")
    e = adopt_or_hold(w, p, "fixture", image=PY)
    g = e["gen"]
    w.kq = StubKq([])
    w.handle(FakeEv(p.pid, W.NOTE_EXEC, udata=g))
    real = W.procargs
    try:
        W.procargs = lambda pid, birth_us, reader=None: {"status": "GONE", "exec_path": None,
                                                        "argv": None, "meta": None}
        res = w.snapshot(g, W.now() + 2.0)["result"]
    finally:
        W.procargs = real
    w.handle(FakeEv(p.pid, W.NOTE_EXIT | W.NOTE_EXITSTATUS, 0, udata=g))
    kinds = [v["kind"] for v in w.violations]
    dead = [x for x in w.dead if x["gen"] == g]
    rc = reap(p, D_REAP)
    labels = ["root"]
    ok = res == "GONE" and kinds == ["exec-image-unobserved-before-exit"] and len(dead) == 1 and \
        dead[0]["image"] is None and dead[0]["argv"] is None and dead[0]["role"] == "unknown-image"
    return finish(labels, d, T, ["PASS"], "PASS" if ok and rc == 0 else "FAIL",
                  {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot,
                  notes={"result": res, "violations": kinds})


# R4 (review 930cad6): every fixture stage that waits on the controller has its OWN
# autonomous bound. A gate is a pipe whose read end the fixture selects on for at most
# FIXTURE_HOLD_S: one release byte "g" proceeds; the bound, or EOF (the controller gone),
# exits 3. A shell stage that must stay alive reads a stdin pipe whose write end is held by
# a registered holder fixture that exits on release, on EOF or after FIXTURE_HOLD_S, so the
# shell's read always ends without any signal.
FIXTURE_HOLD_S = 8
GATED = ("import os,select,sys\nfd=int(sys.argv[1])\n"
         "if not select.select([fd], [], [], %d)[0] or os.read(fd, 1) != b'g':\n"
         "    sys.exit(3)\n" % FIXTURE_HOLD_S)
# gate fd, path, argv...: exec path with argv after the release
EXECER = GATED + "os.execv(sys.argv[2], sys.argv[3:])\n"
# gate fd, command: libc popen(command), then pclose (the child is reaped by this fixture)
POPENER = GATED + ("import ctypes,ctypes.util\nc=ctypes.CDLL(ctypes.util.find_library('c'))\n"
                   "c.popen.restype=ctypes.c_void_p\n"
                   "c.popen.argtypes=[ctypes.c_char_p, ctypes.c_char_p]\n"
                   "c.pclose.argtypes=[ctypes.c_void_p]\n"
                   "f=c.popen(sys.argv[2].encode(), b'r')\n"
                   "sys.exit(0 if f and c.pclose(f) == 0 else 4)\n")
HOLDER_CODE = ("import os,select\nselect.select([0], [], [], %d)\ntry:\n"
               "    os.write(1, b'\\n')\nexcept OSError:\n    pass\n" % FIXTURE_HOLD_S)


def gate_open():
    """(read end for the fixture, write end kept by the controller)."""
    return os.pipe()


def release_gate(wfd, data=b"g"):
    try:
        os.write(wfd, data)
        return True
    except BrokenPipeError:
        return False


def gated_fixture(d, T, label, code, *args, **kw):
    """A fixture whose first argument is its gate fd. Returns (Popen, gate write end)."""
    gr, gw = gate_open()
    try:
        p = start_fixture(d, T, label, code, gr, *args, pass_fds=(gr,), **kw)
    finally:
        os.close(gr)
    return p, gw


def stdin_holder(d, T, label):
    """(read end to use as a shell's stdin, holder Popen). The holder holds the only write
    end; on release, on controller EOF or after FIXTURE_HOLD_S it writes one newline (the
    shell's `read` returns) and exits, closing the pipe."""
    r, w = os.pipe()
    try:
        h = start_fixture(d, T, label, HOLDER_CODE, stdin=subprocess.PIPE, stdout=w)
    finally:
        os.close(w)
    return r, h


def release_holder(h):
    try:
        h.stdin.write(b"\n")
        h.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass


def run_watch_until(w, cond, deadline, each=None):
    while W.now() < deadline and not cond():
        w.step(0.05, min(W.now() + W.ITER_SLICE_S, deadline))
        if each is not None:
            each()
    return cond()


def t30f(d, scratch, runroot):
    """Real kernel: the gated fixture execs pinned coreutils `sleep 5` and stays alive; a
    VALID snapshot records the exact exec_path, image and argv vector."""
    T = "T30f"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    p, gw = gated_fixture(d, T, "execer", EXECER, COREUTILS_SLEEP, "sleep", "5")
    e = adopt_or_hold(w, p, "fixture", image=PY)
    seen = {}

    def record(entry, s, kind):
        seen.update(image=s["image"], exec_path=s["exec_path"], argv=s["argv"], kind=kind)
    w.apply_snapshot = record
    release_gate(gw)
    run_watch_until(w, lambda: "argv" in seen, W.now() + 5.0)
    os.close(gw)
    rc = reap(p, D_REAP)
    labels = ["root"]
    ok = seen.get("kind") == "exec" and seen.get("exec_path") == COREUTILS_SLEEP and \
        os.path.realpath(seen.get("image") or "") == os.path.realpath(COREUTILS_SLEEP) and \
        seen.get("argv") == ["sleep", "5"] and e["gen"] and rc == 0
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot, notes=seen)


def t30g(d, scratch, runroot):
    """Measurement on the pinned macOS ([A], B3/B4): (a) execv("/bin/sh", ["/bin/sh","-c",
    CMD]): every observed SYSTEM_SH stage keeps exactly that vector (the shim hand-off
    equality apply_snapshot relies on); (b) libc popen(CMD): the child's observed shell stage
    is exactly ["sh","-c",CMD] (the popen argv0 the forms rely on). CMD reads one line from
    a holder pipe (R4: the holder bounds it autonomously), so the shell stage stays alive
    until observed; the holder is then released and the shell execs pinned sleep. Each side
    needs at least one observed shell stage: an unobserved stage is UNMEASURED (a non-pass
    that returns the [A] premise for review), never assumed. This measures the shell/popen
    vectors only, NOT the devenv-tasks wrapper vector (still an unmeasured premise)."""
    T = "T30g"
    root = mkroot(d, scratch, T, "root")
    cmd = "read x; exec %s 3" % COREUTILS_SLEEP
    sleep_real = os.path.realpath(COREUTILS_SLEEP)
    stages = {"a": [], "b": []}

    def watched(key, label, code, *args):
        sin, h = stdin_holder(d, T, label + "-holder")
        try:
            p, gw = gated_fixture(d, T, label, code, *args, stdin=sin)
        finally:
            os.close(sin)
        w = bare_watch(root)
        adopt_or_hold(w, p, "fixture", image=PY)
        w.apply_snapshot = lambda entry, s, kind: stages[key].append(
            {"pid": entry["pid"], "image": s["image"], "argv": s["argv"]})
        mine = (lambda x: True) if key == "a" else (lambda x: x["pid"] != p.pid)
        poll = None if key == "a" else (lambda: w.scan_children(p.pid, "poll"))
        release_gate(gw)
        run_watch_until(w, lambda: any(mine(x) and os.path.realpath(x["image"]) in W.SYSTEM_SH
                                       for x in stages[key]), W.now() + 6.0, poll)
        release_holder(h)
        run_watch_until(w, lambda: any(mine(x) and os.path.realpath(x["image"]) == sleep_real
                                       for x in stages[key]), W.now() + 6.0, poll)
        os.close(gw)
        return p, h
    pa, ha = watched("a", "shim", EXECER, "/bin/sh", "/bin/sh", "-c", cmd)
    pb, hb = watched("b", "popen", POPENER, cmd)
    rcs = {k: reap(x, D_REAP) for k, x in (("shim", pa), ("shim-holder", ha), ("popen", pb),
                                           ("popen-holder", hb))}
    sh_a = [x for x in stages["a"] if os.path.realpath(x["image"]) in W.SYSTEM_SH]
    sh_b = [x for x in stages["b"] if x["pid"] != pb.pid and
            os.path.realpath(x["image"]) in W.SYSTEM_SH]
    if not sh_a or not sh_b:
        obs = "UNMEASURED"
    elif all(x["argv"] == ["/bin/sh", "-c", cmd] for x in sh_a) and \
            all(x["argv"] == ["sh", "-c", cmd] for x in sh_b):
        obs = "PASS"
    else:
        obs = "FAIL"
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], obs,
                  {"fixtures": "ok" if all(v == 0 for v in rcs.values()) else "rc-%r" % rcs},
                  runroot, notes={"stages": stages, "shell_stages_observed":
                                  {"a": len(sh_a), "b": len(sh_b)}})


def t30i(d, scratch, runroot):
    """Popen-parent coalescing: a child first seen as a non-shell image is
    exec-chain-unobserved; the healthy pair (shell first) is allowed."""
    T = "T30i"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root, port=25432)
    P = W.PG_BIN + "/postgres"
    parent = {"pid": 7001, "birth_us": 7001, "image": W.PG_BIN + "/initdb",
              "exe": W.PG_BIN + "/initdb", "argv": ["initdb", "--locale=C", "--encoding=UTF8"],
              "lineage": True, "parent": None, "exit": None, "role": "pg-tool", "gen": None}
    w.entries[7001] = parent

    def child(pid):
        e = {"pid": pid, "birth_us": pid, "image": parent["image"], "exe": parent["image"],
             "argv": list(parent["argv"]), "lineage": True, "parent": 7001,
             "parent_birth_us": 7001, "exit": None, "role": "pg-tool", "gen": None}
        w.entries[pid] = e
        return e

    def snap(image, argv):
        return {"image": image, "exec_path": image, "argv": argv, "meta": None,
                "argv_status": "OK", "cutoff": W.now()}
    bad = child(7002)
    before = len(w.violations)
    w.apply_snapshot(bad, snap(P, [P, "-V"]), "exec")
    skipped = [v["kind"] for v in w.violations[before:]]
    good = child(7003)
    before = len(w.violations)
    w.apply_snapshot(good, snap("/bin/sh", ["sh", "-c", '"%s" -V' % P]), "exec")
    healthy = w.violations[before:] == [] and "allowance" in good
    labels = ["root"]
    ok = "exec-chain-unobserved" in skipped and healthy
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                  notes={"skipped": skipped, "healthy": healthy})


class HidingKq(object):
    """fixture-synthetic injection: the REAL kqueue with every event carrying `udata` and
    NOTE_EXEC withheld (a delayed/missing exec event). Used only to prove the T30j oracle
    fails on the new image when the event is not visible."""

    def __init__(self, kq, udata):
        self.kq, self.udata = kq, udata

    def control(self, changes, n, timeout=None):
        return [e for e in self.kq.control(changes, n, timeout)
                if not (e.udata == self.udata and e.fflags & W.NOTE_EXEC)]


# gate fd, progress fd, bash: write "b", exec pinned bash, which writes "a" (progress after
# the exec) and waits on the gate fd for at most FIXTURE_HOLD_S (R4).
ORDER_EXECER = GATED + ("p=int(sys.argv[2])\nos.write(p, b'b')\n"
                        "os.execv(sys.argv[3], ['bash', '-c', 'printf a >&%d; read -t %d -u %d x'"
                        " % (p, " + str(FIXTURE_HOLD_S) + ", fd)])\n")


def ordering_run(d, T, label, w, hide=False):
    """One adverse-ordering schedule (R3): the target's exec is triggered INSIDE the
    snapshot interval (after the pre-fence, the pending check and the first identity read;
    before the image/argv reads) and is independently observed to have happened (progress
    "b" before the exec, "a" from the new image) before those reads run, and before its
    event is handled. Oracle: VOID or DEFERRED is PASS; VALID (the new image attributed
    while its NOTE_EXEC is invisible to the post-fence) is FAIL; an unobserved schedule or
    an UNKNOWN snapshot is UNMEASURED; anything else is FAIL. `hide` withholds the target's
    exec events, which must make the oracle FAIL."""
    bash = W.PKG["bash"] + "/bin/bash"
    pr, pw = os.pipe()
    gr, gw = gate_open()
    want_argv = ["bash", "-c", "printf a >&%d; read -t %d -u %d x" % (pw, FIXTURE_HOLD_S, gr)]
    try:
        p = start_fixture(d, T, label, ORDER_EXECER, gr, pw, bash, pass_fds=(gr, pw))
    finally:
        os.close(gr)
        os.close(pw)
    e = adopt_or_hold(w, p, "fixture", image=PY)
    g = e["gen"]
    if hide:
        w.kq = HidingKq(w.kq, g)
    progress, real_pidpath = {}, W.pidpath

    def hooked(pid):
        if pid == p.pid and "released" not in progress:
            progress["released"] = W.now()
            release_gate(gw)
            got, end = b"", W.now() + 5.0
            while W.now() < end and got != b"ba":
                if select.select([pr], [], [], max(0.0, end - W.now()))[0]:
                    chunk = os.read(pr, 2 - len(got))
                    if chunk == b"":
                        break
                    got += chunk
            progress["observed"] = got.decode("ascii", "replace")
            progress["observed_t"] = W.now()
        return real_pidpath(pid)
    try:
        W.pidpath = hooked
        s = w.snapshot(g, W.now() + 10.0)
    finally:
        W.pidpath = real_pidpath
    handled_before = e["execs"]
    release_gate(gw, b"\n")              # the bash stage's own read ends at once
    os.close(gw)
    os.close(pr)
    rc = reap(p, D_REAP)
    if progress.get("observed") != "ba" or s["result"] == "UNKNOWN":
        oracle = "UNMEASURED"
    elif s["result"] in ("VOID", "DEFERRED"):
        oracle = "PASS"
    else:
        oracle = "FAIL"
    return {"oracle": oracle, "result": s["result"], "progress": progress.get("observed"),
            "execs_handled_at_snapshot": handled_before,
            "image": os.path.realpath(s.get("image") or ""), "argv": s.get("argv"),
            "want_image": os.path.realpath(bash), "want_argv": want_argv, "rc": rc}


def hidden_companion_proves(run):
    """R3 (review e3d897b): the hidden-EXEC companion counts as proof that the ordering
    oracle detects the intended attribution bug ONLY for the specific unsafe outcome: the
    schedule observed (progress "ba"), no target exec handled before the result, and VALID
    for exactly the new image and its known vector. GONE, INCONSISTENT, UNKNOWN, missing
    progress, an old image or any other result establishes nothing (UNMEASURED/HOLD)."""
    return isinstance(run, dict) and run.get("progress") == "ba" and \
        run.get("execs_handled_at_snapshot") == 0 and run.get("result") == "VALID" and \
        run.get("oracle") == "FAIL" and bool(run.get("want_image")) and \
        run.get("image") == run.get("want_image") and \
        run.get("argv") is not None and run.get("argv") == run.get("want_argv")


def t30j(d, scratch, runroot):
    """Target event BEHIND 256 unrelated events (R1a) and the adverse-ordering oracle (R3).
    Stub-ordered on the real snapshot code: VOID, an exec obligation, then VALID once
    handled. Real kernel: 300 registered pinned-coreutils sleepers EXIT (queued ahead), then
    the ordering schedule (ordering_run) must give VOID/DEFERRED; the same schedule with the
    target's exec event withheld (HidingKq) must produce exactly the unsafe outcome
    (hidden_companion_proves: progress "ba", no exec handled, VALID for the new image and
    vector), proving the oracle detects it; GONE, INCONSISTENT or any other hidden result is
    UNMEASURED. An unobserved schedule is UNMEASURED (non-pass: HOLD for review). Sampled evidence for
    the UNVERIFIED kernel-ordering premise, never a theorem."""
    T = "T30j"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    t = live_fixture(d, T, "target")
    o = live_fixture(d, T, "other")
    et, eo = adopt_or_hold(w, t, "fixture"), adopt_or_hold(w, o, "fixture")
    filler = [FakeEv(o.pid, 0, udata=eo["gen"]) for _ in range(256)]
    w.kq = StubKq([[], filler, [FakeEv(t.pid, W.NOTE_EXEC, udata=et["gen"])], []])
    first = w.snapshot(et["gen"], W.now() + 3.0)["result"]
    w.process_pending(W.now() + 2.0, W.PENDING_CAP)
    req = dict(w.requests.get(et["gen"]) or {})
    w.requests.pop(et["gen"], None)
    second = w.snapshot(et["gen"], W.now() + 2.0)
    stub_ok = first == "VOID" and req.get("kind") == "exec" and second["result"] == "VALID"
    rct, rco = reap(t, D_REAP), reap(o, D_REAP)
    # real kernel: a queued backlog of 300 exits, then the schedule
    wr = bare_watch(root)
    sleepers = []
    for i in range(300):
        intent(d, T, "s%d" % i, "proc")
        sp = subprocess.Popen([COREUTILS_SLEEP, "1.5"], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, close_fds=True)
        set_identity(d, T, "s%d" % i, proc_identity(sp.pid, os.getpid()))
        sleepers.append(sp)
        if wr.adopt(sp.pid, "fixture") is None:
            raise RealUncertainty("T30j: sleeper %d gone before adoption" % sp.pid)
    time.sleep(2.0)                                   # every sleeper's 1.5 s has passed
    real = ordering_run(d, T, "order-real", wr)
    rcs = [reap(sp, D_REAP) for sp in sleepers]
    wh = bare_watch(root)
    hidden = ordering_run(d, T, "order-hidden", wh, hide=True)
    proves = hidden_companion_proves(hidden)
    if real["oracle"] == "UNMEASURED" or not proves:
        obs = "UNMEASURED"          # an unproven negative companion is HOLD, never a pass
    elif stub_ok and real["oracle"] == "PASS" and \
            [v["kind"] for v in wr.violations] == []:
        obs = "PASS"
    else:
        obs = "FAIL"
    labels = ["root"]
    allrc = rcs + [rct, rco]
    fixtures = "ok" if all(r == 0 for r in allrc) and real["rc"] in (0, 1) and \
        hidden["rc"] in (0, 1) else "nonzero"
    return finish(labels, d, T, ["PASS"], obs, {"fixtures": fixtures}, runroot,
                  notes={"stub": [first, req.get("kind"), second["result"]], "real": real,
                         "hidden": hidden, "hidden_companion_proves": proves,
                         "violations": [v["kind"] for v in wr.violations],
                         "premise": "kernel ordering UNVERIFIED (sampled)"})


def t30k(d, scratch, runroot):
    """Persistent backlog (never an empty fence) and slow handling of the target's own
    exec events (handler time counted; the earliest deadline is never reset, B1)."""
    T = "T30k"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    t = live_fixture(d, T, "target")
    o = live_fixture(d, T, "other")
    et, eo = adopt_or_hold(w, t, "fixture"), adopt_or_hold(w, o, "fixture")
    w.kq = StubKq([], forever=[FakeEv(o.pid, 0, udata=eo["gen"])])   # never an empty fence
    t0 = W.now()
    try:
        backlog = w.snapshot(et["gen"], t0 + 1.0)["result"]
    except W.Hold:
        backlog = "HOLD"
    backlog_s = W.now() - t0
    backlog_kinds = [v["kind"] for v in w.violations]
    # slow handling
    w2 = bare_watch(root)
    t2 = live_fixture(d, T, "target2")
    e2 = adopt_or_hold(w2, t2, "fixture")
    g2 = e2["gen"]
    w2.request(g2, "exec")
    first_deadline = w2.requests[g2]["deadline"]
    w2.kq = StubKq([[FakeEv(t2.pid, W.NOTE_EXEC, udata=g2) for _ in range(20)]])
    real_handle = w2.handle

    def slow(ev, deadline=W.INF):
        time.sleep(0.3)
        real_handle(ev, deadline)
    w2.handle = slow
    t1 = W.now()
    while W.now() < first_deadline + 1.0 and g2 in w2.requests:
        w2.step(0.05, min(W.now() + W.ITER_SLICE_S, first_deadline + 1.0))
        if g2 in w2.requests and w2.requests[g2]["deadline"] != first_deadline:
            break
    deadline_kept = g2 not in w2.requests or w2.requests[g2]["deadline"] == first_deadline
    slow_kinds = [v["kind"] for v in w2.violations]
    slow_s = W.now() - t1
    rcs = [reap(x, D_REAP) for x in (t, o, t2)]
    labels = ["root"]
    ok = backlog == "HOLD" and backlog_s <= 1.5 and \
        backlog_kinds == ["event-queue-saturated"] and deadline_kept and \
        "image-snapshot-unresolved" in slow_kinds and slow_s <= 2.0 + 1.5 and \
        all(r == 0 for r in rcs)
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if all(r == 0 for r in rcs) else "nonzero"}, runroot,
                  notes={"backlog": backlog, "backlog_s": backlog_s, "slow_kinds": slow_kinds,
                         "slow_s": slow_s, "deadline_kept": deadline_kept})


def t30l(d, scratch, runroot):
    """Healthy pair: an idle registered fixture gives a VALID snapshot with its cutoff."""
    T = "T30l"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    p = live_fixture(d, T, "idle")
    e = adopt_or_hold(w, p, "fixture")
    s = w.snapshot(e["gen"], W.now() + 2.0)
    rc = reap(p, D_REAP)
    labels = ["root"]
    ok = s["result"] == "VALID" and s["pre"] <= s["cutoff"] and \
        os.path.realpath(s["image"]) == os.path.realpath(PY) and rc == 0
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot,
                  notes={"result": s["result"]})


def fork_execve(path, argv, env, stdin_fd=None, ready_fd=None):
    """Fork, then execve(path, argv, env) through libc in the child (argv0 may be empty).
    The child is this process's own; reaped with reap_pid."""
    lib = W.libc()
    pid = os.fork()
    if pid == 0:
        try:
            if stdin_fd is not None:
                os.dup2(stdin_fd, 0)
            if ready_fd is not None:
                if ready_fd == 3:
                    os.set_inheritable(3, True)
                else:
                    os.dup2(ready_fd, 3)
            cargv = (ctypes.c_char_p * (len(argv) + 1))(*[a.encode() for a in argv], None)
            cenv = (ctypes.c_char_p * (len(env) + 1))(*[e.encode() for e in env], None)
            lib.execve(path.encode(), cargv, cenv)
        finally:
            os._exit(127)
    return pid


def reap_pid(pid, deadline_s):
    end = W.now() + deadline_s
    while W.now() < end:
        r, st = os.waitpid(pid, os.WNOHANG)
        if r == pid:
            return os.waitstatus_to_exitcode(st)
        time.sleep(0.05)
    raise RealUncertainty("forked fixture %d alive after %.0f s" % (pid, deadline_s))


def join_owned(steps):
    """A finite, ordered list of bounded release/join steps for owned fixtures (a40f005
    review A3): [(label, fn)]. EVERY step is attempted even after an earlier one failed, and
    each outcome is recorded: {step, ok, value} or {step, ok: false, error_class, error}.
    Catching here never continues a test or upgrades a verdict: settle_joins raises the
    primary failure, or an uncertainty for any failed step. An interruption
    (BaseException other than Exception) is not handled and stays an explicit HOLD."""
    out = []
    for label, fn in steps:
        try:
            out.append({"step": label, "ok": True, "value": fn()})
        except Exception as e:
            out.append({"step": label, "ok": False, "error_class": type(e).__name__,
                        "error": str(e)[:300]})
    return out


_JOIN_SEQ = [0]


def write_join_record(path, rec):
    """Create one join record; never replaces an existing file (O_EXCL)."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=1, sort_keys=True, default=str)
        f.write("\n")


def settle_joins(d, T, primary, outcomes):
    """After join_owned: with a primary failure, re-raise THAT exception object unchanged
    (class, args, traceback) with every outcome attached (`join_outcomes`) and its record
    path (`join_record`); without one, any failed step raises RealUncertainty naming every
    failed step (all were attempted). Each settlement gets its OWN record,
    <d>/<T>.joins.<pid>.<seq>.json, created exclusively and never replaced or deleted
    (2eaff27 review R2). If that record cannot be written, the failure is added to the
    outcomes and the failed steps, and a closed, metadata-only diagnostic line is written to
    stderr (test id, error class, primary class, failed step names; no message text), which
    the guarded runner retains. No signal, no disposal, no receipt; a nonzero or
    unconfirmed fixture outcome is never called joined. Returns None when nothing failed."""
    failed = [o["step"] for o in outcomes if not o["ok"]]
    if primary is None and not failed:
        return None
    _JOIN_SEQ[0] += 1
    path = "%s/%s.joins.%d.%03d.json" % (d, T, os.getpid(), _JOIN_SEQ[0])
    rec = {"test": T, "failed_steps": list(failed), "joins": outcomes,
           "primary": None if primary is None else
           {"class": type(primary).__name__, "message": str(primary)[:300]},
           "proof": "owned release/join outcomes only; not a teardown proof"}
    diagnostic = "not-needed"
    try:
        write_join_record(path, rec)
    except OSError as e:
        outcomes.append({"step": "joins-record", "ok": False, "error_class": type(e).__name__,
                         "error": str(e)[:300]})
        failed.append("joins-record")
        path = None
        if primary is not None:            # evidence attached BEFORE the diagnostic attempt
            primary.join_outcomes, primary.join_record = outcomes, None
        try:
            sys.stderr.write("JOINS-RECORD-UNWRITTEN test=%s error_class=%s primary_class=%s "
                             "failed_steps=%s\n" % (T, type(e).__name__,
                                                     type(primary).__name__
                                                     if primary is not None else "none",
                                                     ",".join(failed)))
            sys.stderr.flush()
            diagnostic = "written"
        except Exception as de:            # both sinks failed: kept, never claimed retained
            outcomes.append({"step": "joins-diagnostic", "ok": False,
                             "error_class": type(de).__name__, "error": str(de)[:300]})
            failed.append("joins-diagnostic")
            diagnostic = "UNWRITTEN"
    if primary is not None:
        primary.join_outcomes = outcomes
        primary.join_record = path
        primary.join_diagnostic = diagnostic
        raise primary
    u = RealUncertainty("%s: owned release/join steps failed (all attempted): %s; record %s;"
                        " diagnostic %s" % (T, failed, path or "UNWRITTEN", diagnostic))
    u.join_outcomes, u.join_record, u.join_diagnostic = outcomes, path, diagnostic
    raise u


def close_fd(fd):
    """os.close, as a named step (the post-fork close controls inject here)."""
    os.close(fd)


def release_pipe(fd):
    """Write the release byte to a fixture's stdin pipe and close our end."""
    try:
        os.write(fd, b"\n")
        return "released"
    except BrokenPipeError:
        return "fixture already gone"
    finally:
        os.close(fd)


def t30m_case(d, T, n, case, shells, holders):
    """One T30m layout case: fork + execve the fixture, read its KERN_PROCARGS2 once it is
    ready, then release it and reap it. `holders` collects the holder fixtures started so
    far (the caller reaps them after the loop on the normal path). On a handled failure (or
    a failed release/join) every owned step is attempted and recorded: this case's ready
    pipe, its release, its bounded reap, then every holder started so far; the primary
    failure is re-raised unchanged with that metadata (settle_joins)."""
    path, argv, env, mode, held = case
    r, wfd = os.pipe()
    h, sw, sin = None, None, None
    try:
        if held:
            sin, h = stdin_holder(d, T, "case%d-holder" % n)
            holders.append(h)
        else:
            sin, sw = os.pipe()
        intent(d, T, "case%d" % n, "proc")
        pid = fork_execve(path, argv, env, stdin_fd=sin, ready_fd=wfd)
    except Exception as e:      # nothing forked: join what was started, keep the failure
        steps = [("case%d-close-ready" % n, lambda: os.close(r)),
                 ("case%d-close-ready-w" % n, lambda: os.close(wfd))]
        if sin is not None:
            steps.append(("case%d-close-stdin-r" % n, lambda: os.close(sin)))
        if sw is not None:
            steps.append(("case%d-release-stdin" % n, lambda: release_pipe(sw)))
        steps += [("holder%d-reap" % i, (lambda hh=hh: reap(hh, D_REAP)))
                  for i, hh in enumerate(holders)]
        settle_joins(d, T, e, join_owned(steps))
    res = {"case": n, "path_len": len(path), "argc": len(argv), "mode": mode, "pid": pid}
    primary = None
    open_fds = {"ready-w": wfd, "stdin-r": sin}
    try:
        # R1 (2eaff27 review): the post-fork closes are inside the protected path
        set_identity(d, T, "case%d" % n, proc_identity(pid, os.getpid()))
        for name in ("ready-w", "stdin-r"):
            close_fd(open_fds[name])
            del open_fds[name]
        ready = bool(select.select([r], [], [], D_LINE)[0]) and os.read(r, 2) == b"r\n"
        cur = W.bsdinfo(pid)
        a = W.procargs(pid, cur["birth_us"]) if ready and cur else {"status": "NOT-READY"}
        ep = a.get("exec_path")
        res.update(status=a["status"], match=a.get("argv") == argv,
                   exec_path_ok=(ep == path) if mode == "exact" else
                   (ep is not None and os.path.realpath(ep) in shells))
    except Exception as e:      # the primary failure: kept, re-raised after the joins
        primary = e
    steps = [("case%d-close-%s" % (n, name), (lambda fd=fd: close_fd(fd)))
             for name, fd in sorted(open_fds.items())]
    steps.append(("case%d-close-ready" % n, lambda: os.close(r)))
    if h is not None:
        steps.append(("case%d-release-holder" % n, lambda: release_holder(h)))
    else:
        steps.append(("case%d-release-stdin" % n, lambda: release_pipe(sw)))
    steps.append(("case%d-reap" % n, lambda: reap_pid(pid, D_REAP)))
    out = join_owned(steps)
    if primary is not None or not all(o["ok"] for o in out):
        out += join_owned([("holder%d-reap" % i, (lambda hh=hh: reap(hh, D_REAP)))
                           for i, hh in enumerate(holders)])
        settle_joins(d, T, primary, out)
    by = {o["step"]: o for o in out}
    if by["case%d-release-%s" % (n, "holder" if h is not None else "stdin")].get(
            "value") == "fixture already gone":
        res["stdin"] = "fixture already gone"
    res["rc"] = by["case%d-reap" % n]["value"]
    return res


def t30m_join_holders(d, T, holders):
    """T30m's final holder phase (2eaff27 review R1): every holder's bounded reap is attempted
    even after an earlier one fails; any failure settles (uncertainty, own record). Returns
    the rcs in order."""
    out = join_owned([("holder%d-reap" % i, (lambda hh=hh: reap(hh, D_REAP)))
                      for i, hh in enumerate(holders)])
    settle_joins(d, T, None, out)
    return [o["value"] for o in out]


def t30m(d, scratch, runroot):
    """Layout gate (r3 3.2, B3): owned ARGV-TOLERANT accepting fixtures, execve'd through
    libc: the pinned python (HOLDER: any argv0, any trailing arguments after -c CODE; it
    waits on its stdin for at most 8 s) via declared symlinks whose exec_path lengths cover
    every residue mod 8; the source-known shell forms (/bin/sh with argv0 "sh" and
    "/bin/sh", pinned bash with "bash") reading a holder pipe (R4: the registered holder
    bounds the read autonomously). argc, argument lengths, empties (including an empty
    argv0) and environment sizes vary. Each fixture signals readiness on fd 3 and is held
    alive while its KERN_PROCARGS2 is read: the parse under H-pad (A = 8) must be exactly
    the known vector and exec_path (the shells: a SYSTEM_SH/bash image after any shim
    hand-off). Any mismatch is FAIL and returns the hypothesis for review: no later
    reliance, no fallback. Python start-up with an empty/short argv0 and a minimal env is a
    fixture premise: a start-up refusal is a fixture issue, not an H-pad falsification."""
    T = "T30m"
    names = ["l" * k for k in range(1, 9)]
    root = mkroot(d, scratch, T, "root", names)
    links = []
    for name in names:
        os.symlink(PY, root + "/" + name)
        links.append(root + "/" + name)
    tails = [[], [""], ["a", "", "b"], ["x" * 100], ["KEY=VALUE", "-c", ""]]
    argv0s = ["", "p", "pp", "python-fixture"]
    envs = [["E=1"], ["E=" + "x" * 7], ["E=" + "x" * 64, "F="], ["E=" + "x" * 1000]]
    cases = []
    for i, lp in enumerate(links):
        cases.append((lp, [argv0s[i % 4], "-I", "-c", HOLDER] + tails[i % 5], envs[i % 4],
                      "exact", False))
    sh_cmd = "echo r >&3; read x"
    bash = W.PKG["bash"] + "/bin/bash"
    cases.append(("/bin/sh", ["sh", "-c", sh_cmd], ["E=1"], "shell", True))
    cases.append(("/bin/sh", ["/bin/sh", "-c", sh_cmd], ["E=" + "y" * 333], "shell", True))
    cases.append((bash, ["bash", "-c", sh_cmd], ["E=" + "z" * 13], "exact", True))
    shells = {os.path.realpath(x) for x in W.SYSTEM_SH}
    results, holders = [], []
    for n, case in enumerate(cases):
        results.append(t30m_case(d, T, n, case, shells, holders))
    hrcs = t30m_join_holders(d, T, holders)
    residues = sorted({len(c[0]) % 8 for c in cases[:8]})
    labels = ["root"]
    ok = len(results) == len(cases) and residues == list(range(8)) and \
        all(x["status"] == "OK" and x["match"] and x["exec_path_ok"] for x in results)
    fixtures = "ok" if all(x["rc"] == 0 for x in results) and all(x == 0 for x in hrcs) \
        else "nonzero"
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": fixtures},
                  runroot, notes={"results": results, "residues": residues,
                                  "holder_rcs": hrcs})


def t30n(d, scratch, runroot):
    """The ambiguous pair (B3): (i) an empty argv[0] after exact padding parses as "";
    (ii) one extra NUL after the exact padding is read as another EMPTY argument (the
    parser cannot know it was padding) and no source-known form matches; (iii) the old
    skip-NUL reading is never produced."""
    T = "T30n"
    w = bare_watch(scratch, port=25432)
    i = parse(pa_buf(2, "/bin/sh", [b"", b"x"]))
    ii = parse(pa_buf(2, "/bin/sh", [b"x", b"y"], extra_nul=1))

    def any_form(argv):
        return any(len(argv) == 3 and argv[0] == f["child_argv0"] and argv[1] == "-c" and
                   f["child_cmd"].fullmatch(argv[2]) for f in w.forms.values()) or \
            any(W.vec_match(f["exec_argv"], argv) for f in w.forms.values())
    ok = i["status"] == "OK" and i["argv"] == ["", "x"] and not any_form(i["argv"]) and \
        ii["status"] == "OK" and ii["argv"] == ["", "x"] and not any_form(ii["argv"]) and \
        ii["argv"] != ["x", "y"]
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:pure parser"}, runroot,
                   notes={"i": i["argv"], "ii": ii["argv"]})


def t30o(d, scratch, runroot):
    """Environment-looking bytes after a truncated argv: the parse consumes them, no shell
    form is granted, and receipts hold metadata only (no "PATH=" anywhere)."""
    T = "T30o"
    w = bare_watch(scratch, port=25432)
    a = parse(pa_buf(3, "/bin/sh", [b"sh", b"-c"], env=[b"PATH=/x"]))
    parent = {"pid": 7101, "birth_us": 7101, "image": W.PG_BIN + "/initdb",
              "exe": W.PG_BIN + "/initdb", "argv": ["initdb", "--locale=C", "--encoding=UTF8"],
              "lineage": True, "parent": None, "exit": None, "role": "pg-tool", "gen": None}
    e = {"pid": 7102, "birth_us": 7102, "image": "/bin/sh", "exe": "/bin/sh", "argv": a["argv"],
         "argv_meta": a["meta"], "argv_known": False, "lineage": True, "parent": 7101,
         "parent_birth_us": 7101, "exit": None, "role": "pg-sh", "gen": None}
    w.entries.update({7101: parent, 7102: e})
    w.check_exe(e)
    kinds = [v["kind"] for v in w.violations]
    blob = json.dumps({"entry": W.entry_view(e), "violations": w.violations}, default=str)
    ok = a["argv"] == ["sh", "-c", "PATH=/x"] and kinds == ["sh-form-mismatch"] and \
        "PATH=" not in blob and "allowance" not in e
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:fabricated records"}, runroot,
                   notes={"violations": kinds})


def t30p(d, scratch, runroot):
    """PG title only (r3 3.3, B4): under a postmaster parent only argv[0] is consumed and
    recorded; trailing KEY=VALUE bytes never reach the receipt, not even as metadata."""
    T = "T30p"
    w = bare_watch(scratch)
    P = W.PG_BIN + "/postgres"
    pm = {"pid": 7201, "birth_us": 7201, "image": P, "exe": P, "argv": None, "lineage": True,
          "parent": None, "exit": None, "role": "postmaster-final", "gen": None}
    ch = {"pid": 7202, "birth_us": 7202, "image": P, "exe": P,
          "argv": ["postgres: logger ", "", "KEY=VALUE"],
          "argv_meta": W.argv_meta([b"postgres: logger ", b"", b"KEY=VALUE"]),
          "argv_known": False, "lineage": True, "parent": 7201, "parent_birth_us": 7201,
          "exit": None, "role": "pg-aux", "gen": None}
    w.entries.update({7201: pm, 7202: ch})
    role = w.classify(ch)
    other = dict(ch, pid=7203, argv=["postgres: checkpointer ", "KEY=VALUE"])
    w.entries[7203] = other
    role2 = w.classify(other)
    blob = json.dumps([W.entry_view(ch), W.entry_view(other)])
    ok = role == "pg-logger" and role2 == "pg-aux" and ch["title"] == "postgres: logger " and \
        "KEY=" not in blob and W.entry_view(ch).get("argv_meta") is None
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:fabricated records"}, runroot,
                   notes={"roles": [role, role2]})


# -- R2 controls
def unregistered_gone(w, d, T, label):
    """An entry for a real exited fixture whose generation has NO knote (fixture-synthetic)."""
    p = start_fixture(d, T, label, "import time; time.sleep(0.2)")
    cur = W.bsdinfo(p.pid)
    reap(p, D_REAP)
    g = w.alloc_gen()
    e = {"pid": p.pid, "birth_us": (cur or {}).get("birth_us", 1), "gen": g, "role": "fixture",
         "lineage": True, "parent": None, "exit": None, "image": None, "argv": None,
         "argv_meta": None, "argv_known": False}
    w.gens[g] = {"pid": p.pid, "birth_us": e["birth_us"], "state": "live", "entry": e}
    w.entries[p.pid] = e
    return e


def t31(d, scratch, runroot, variant):
    T = "T31" + variant
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    notes, ok, rcs = {}, False, []
    if variant in ("a", "d"):
        ps = [live_fixture(d, T, "f%d" % i, code="import time; time.sleep(0.3)")
              for i in range(1 if variant == "a" else 2)]
        es = [adopt_or_hold(w, p, "fixture") for p in ps]
        rcs = [reap(p, D_REAP) for p in ps]
        w.refresh()
        kinds = [v["kind"] for v in w.violations]
        dead = [sum(1 for x in w.dead if x["gen"] == e["gen"]) for e in es]
        notes = {"violations": kinds, "dead": dead}
        ok = kinds == [] and dead == [1] * len(es) and all(e["exit"]["kind"] == "exited"
                                                            for e in es)
    elif variant in ("b", "c", "e"):
        n = 5 if variant == "c" else 1
        es = [unregistered_gone(w, d, T, "u%d" % i) for i in range(n)]
        t0 = W.now()
        w.refresh(enclosing=(t0 + 0.2) if variant == "e" else None)
        took = W.now() - t0
        kinds = [v["kind"] for v in w.violations]
        notes = {"violations": kinds, "took_s": took}
        bound = 0.2 + 0.2 if variant == "e" else W.SETTLE_S + 0.3
        ok = kinds == ["exit-unobserved"] * n and took <= bound and \
            all(w.gens[e["gen"]]["state"] == "unobserved" for e in es)
    elif variant == "f":
        p = live_fixture(d, T, "late", code="import time; time.sleep(0.2)")
        e = adopt_or_hold(w, p, "fixture")
        rcs = [reap(p, D_REAP)]
        w.kq = StubKq([])
        w.refresh(enclosing=W.now() + 0.2)
        w.kq = StubKq([[FakeEv(p.pid, W.NOTE_EXIT | W.NOTE_EXITSTATUS, 0, udata=e["gen"])]])
        w.step(0.0, W.now() + 0.5)
        kinds = [v["kind"] for v in w.violations]
        notes = {"violations": kinds, "late_exit": e.get("late_exit")}
        ok = kinds == ["exit-unobserved"] and (e.get("late_exit") or {}).get("code") == 0 and \
            sum(1 for x in w.dead if x["gen"] == e["gen"]) == 1 and \
            w.gens[e["gen"]]["state"] == "retired" and e["exit"]["kind"] == "unobserved"
    elif variant == "h":   # R2: the LAST census read crosses the bound -> nothing judged
        u = unregistered_gone(w, d, T, "late-census")
        real_bsd = W.bsdinfo

        def slow(pid):
            if pid == u["pid"]:
                time.sleep(0.3)
            return real_bsd(pid)
        t0 = W.now()
        try:
            W.bsdinfo = slow
            w.refresh(enclosing=t0 + 0.2)
        finally:
            W.bsdinfo = real_bsd
        late_kinds = [v["kind"] for v in w.violations]
        late_state = w.gens[u["gen"]]["state"]
        w.refresh(enclosing=W.now() + 0.2)                 # healthy pair: judged
        kinds = [v["kind"] for v in w.violations]
        notes = {"late": [late_kinds, late_state], "healthy": kinds}
        ok = late_kinds == [] and late_state == "live" and kinds == ["exit-unobserved"] and \
            w.gens[u["gen"]]["state"] == "unobserved"
    else:   # g: bounded event work
        p = live_fixture(d, T, "noisy")
        e = adopt_or_hold(w, p, "fixture")
        u = unregistered_gone(w, d, T, "gone")
        w.kq = StubKq([], forever=[FakeEv(p.pid, 0, udata=e["gen"])] * 200)
        per_call = []
        real_pp = w.process_pending

        def counting(deadline, max_events=256):
            n = real_pp(deadline, max_events)
            per_call.append(n)
            return n
        w.process_pending = counting
        t0 = W.now()
        try:
            w.refresh(enclosing=t0 + 0.5)
            outcome = "returned"
        except W.Hold:
            outcome = "HOLD"
        took = W.now() - t0
        rcs = [reap(p, D_REAP)]
        notes = {"outcome": outcome, "took_s": took, "max_per_call": max(per_call or [0])}
        ok = took <= 0.5 + 0.5 and max(per_call or [0]) <= 256 and u is not None
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if all(r in (0, -15) for r in rcs) else "rc-%r" % rcs},
                  runroot, notes=notes)


def t32(d, scratch, runroot):
    """lsof_holders on fabricated outputs (F4, review 930cad6): exact outcomes with rc,
    stdout and stderr distinct, and the exact p / c / (f, n)+ group grammar: every empty
    value, orphan, repeat, missing field, group without files or trailing partial pair is
    HOLD, never holders or none."""
    T = "T32"

    def runner(rc, out, err):
        return lambda argv, env=None, timeout=None: (rc, out, err)

    def timeout_runner(argv, env=None, timeout=None):
        raise subprocess.TimeoutExpired(argv, timeout)
    cases = {
        "rc0_holders": (runner(0, "p11\ncbash\nf3\nn/x\nf4\nn/x/y\np12\ncsh\nfcwd\nn/y\n",
                               ""), "holders"),
        "rc1_holders": (runner(1, "p13\ncpg\nf5\nn/z\n", ""), "holders"),
        "empty_c": (runner(0, "p11\nc\nf3\nn/x\n", ""), "hold"),
        "empty_n": (runner(0, "p11\ncbash\nf3\nn\n", ""), "hold"),
        "empty_f": (runner(0, "p11\ncbash\nf\nn/x\n", ""), "hold"),
        "missing_c": (runner(0, "p11\nf3\nn/x\n", ""), "hold"),
        "repeated_c": (runner(0, "p11\ncbash\ncsh\nf3\nn/x\n", ""), "hold"),
        "n_without_f": (runner(0, "p11\ncbash\nn/x\n", ""), "hold"),
        "group_without_files": (runner(0, "p11\ncbash\np12\ncsh\nf3\nn/y\n", ""), "hold"),
        "trailing_f": (runner(0, "p11\ncbash\nf3\nn/x\nf4\n", ""), "hold"),
        "zero_pid": (runner(0, "p0\ncbash\nf3\nn/x\n", ""), "hold"),
        "rc1_empty": (runner(1, "", ""), "none"),
        "rc1_stderr": (runner(1, "", "lsof: WARNING\n"), "hold"),
        "rc2": (runner(2, "", ""), "hold"),
        "malformed_p": (runner(0, "pX\nn/x\n", ""), "hold"),
        "orphan_n": (runner(0, "n/x\np1\n", ""), "hold"),
        "unknown_record": (runner(0, "p1\nz9\n", ""), "hold"),
        "rc0_empty": (runner(0, "", ""), "hold"),
        "timeout": (timeout_runner, "hold"),
    }
    out = {}
    for name, (rn, want) in sorted(cases.items()):
        r = W.lsof_holders("/x", runner=rn)
        out[name] = {"outcome": r["outcome"], "rc": r["rc"], "stdout_bytes": r["stdout_bytes"],
                     "stderr_bytes": r["stderr_bytes"], "pids": r["pids"], "want": want}
    ok = all(v["outcome"] == v["want"] for v in out.values()) and \
        out["rc0_holders"]["pids"] == [11, 12] and out["rc1_holders"]["pids"] == [13] and \
        out["rc1_stderr"]["stderr_bytes"] > 0 and out["rc2"]["rc"] == 2
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:injected runner"}, runroot, notes=out)


def t34(d, scratch, runroot):
    """F7 import control: in a registered disposable COPY of the two Python files (never the
    reviewed worktree), running sink_selftest.py (which imports sink_watch) with -I -B and
    with -I alone must leave no bytecode anywhere in the copy."""
    T = "T34"
    root = mkroot(d, scratch, T, "copy", ["sink_watch.py", "sink_selftest.py", "empty.txt"])
    for name in ("sink_watch.py", "sink_selftest.py"):
        with open(os.path.join(HERE, name), "rb") as f, open(root + "/" + name, "wb") as g:
            g.write(f.read())
    open(root + "/empty.txt", "w").close()
    rcs = []
    for flags in (["-I", "-B"], ["-I"]):
        rc, _, _ = W.run([PY] + flags + [root + "/sink_selftest.py", "observed-class", "--file",
                                         root + "/empty.txt"], env=W.TOOL_ENV, timeout=60)
        rcs.append(rc)
    found = [rel for rel, rec in W.walk(root) if "__pycache__" in rel or rel.endswith(".pyc")]
    labels = ["copy"]
    ok = rcs == [0, 0] and found == []
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                  notes={"rcs": rcs, "bytecode": found})


def t35(d, scratch, runroot):
    """Capability gate (R1b, B2) on the pinned macOS/python: three EV_UDATA_SPECIFIC knotes
    with DISTINCT udata on the SAME live pid. Removal oracle: EV_DELETE of the exact tuple
    (pid, EVFILT_PROC, udata). Expected: deleting udata 103 while the process lives
    succeeds (control) and its NOTE_EXIT never arrives; udata 101 and 102 each deliver
    their own NOTE_EXIT with the exit status (independent attribution); after delivery,
    while the process is still an unreaped zombie, EV_DELETE of 101 and of 102 fails with
    ENOENT (removed; this expectation is itself UNVERIFIED). Anything else is a non-pass
    that returns the capability for review; there is no pid-keyed fallback. The subject
    waits on its stdin for at most FIXTURE_HOLD_S (R4)."""
    T = "T35"
    kq = select.kqueue()
    p = start_fixture(d, T, "subject", HOLDER_CODE, stdin=subprocess.PIPE,
                      stdout=subprocess.DEVNULL)
    flags = select.KQ_EV_ADD | select.KQ_EV_ENABLE | W.KQ_EV_UDATA_SPECIFIC

    def ev(u, fl):
        return select.kevent(p.pid, filter=select.KQ_FILTER_PROC, flags=fl,
                             fflags=W.PROC_FFLAGS, data=0, udata=u)

    def delete(u):
        try:
            kq.control([ev(u, select.KQ_EV_DELETE | W.KQ_EV_UDATA_SPECIFIC)], 0, 0)
            return "deleted"
        except OSError as e:
            return "errno-%d" % e.errno
    out = {}
    try:
        kq.control([ev(101, flags), ev(102, flags), ev(103, flags)], 0, 0)
        out["registered"] = True
    except OSError as e:
        out["registered"] = "errno-%d" % e.errno
    out["delete_present_103"] = delete(103)
    release_holder(p)
    got, end = {}, W.now() + 5.0
    while W.now() < end and len(got) < 2:
        for e in kq.control(None, 16, 0.2):
            if e.flags & select.KQ_EV_ERROR:
                out.setdefault("ev_error", []).append(e.data)
            elif e.ident == p.pid and e.fflags & W.NOTE_EXIT:
                got.setdefault(e.udata, []).append(
                    W.decode_status(e.data) if e.fflags & W.NOTE_EXITSTATUS else None)
    out["exit_udata"] = sorted(got)
    out["statuses"] = [[(x or {}).get("code") for x in got[u]] for u in sorted(got)]
    out["delete_removed_101"] = delete(101)     # the zombie is not yet reaped
    out["delete_removed_102"] = delete(102)
    out["extra_events"] = len(kq.control(None, 16, 0.2))
    rc = reap(p, D_REAP)
    kq.close()
    want_enoent = "errno-%d" % errno.ENOENT
    ok = out["registered"] is True and out["delete_present_103"] == "deleted" and \
        out["exit_udata"] == [101, 102] and out["statuses"] == [[0], [0]] and \
        out["delete_removed_101"] == want_enoent and \
        out["delete_removed_102"] == want_enoent and out["extra_events"] == 0 and \
        "ev_error" not in out
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot, notes=out)


def t36(d, scratch, runroot, variant):
    """Generation attribution (R1b): a, old EXIT queued then the same pid; b, EXEC for a
    retired generation; c, unattributable events; d, healthy interleaving."""
    T = "T36" + variant
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    notes, ok, rcs = {}, False, []
    if variant == "a":
        p = live_fixture(d, T, "old", code="import time; time.sleep(0.2)")
        e = adopt_or_hold(w, p, "fixture")
        rcs.append(reap(p, D_REAP))
        real_kq = w.kq
        w.kq = StubKq([])
        w.refresh(enclosing=W.now() + 0.05)   # a census, then no settle budget
        refused = False
        try:
            w.register(p.pid)
        except W.Hold:
            refused = True
        w.kq = real_kq                      # the REAL queued NOTE_EXIT of generation g1
        w.step(0.5, W.now() + 1.0)
        kinds = [v["kind"] for v in w.violations]
        gens_for_pid = sorted(g for g, x in w.gens.items() if x["pid"] == p.pid)
        notes = {"violations": kinds, "late_exit": e.get("late_exit"), "gens": gens_for_pid}
        ok = refused and "pid-generation-unresolved" in kinds and "exit-unobserved" in kinds and \
            (e.get("late_exit") or {}).get("kind") == "exited" and \
            sum(1 for x in w.dead if x["gen"] == e["gen"]) == 1 and \
            w.gens[e["gen"]]["state"] == "retired" and gens_for_pid[0] == e["gen"] and \
            all(w.gens[g]["state"] in ("retired", "refused-gone") for g in gens_for_pid)
    elif variant == "b":
        p = live_fixture(d, T, "retired", code="import time; time.sleep(0.2)")
        e = adopt_or_hold(w, p, "fixture")
        rcs.append(reap(p, D_REAP))
        w.step(0.5, W.now() + 1.0)
        before = (e["exit"], len(w.dead))
        w.handle(FakeEv(p.pid, W.NOTE_EXEC, udata=e["gen"]))
        kinds = [v["kind"] for v in w.violations]
        notes = {"violations": kinds}
        ok = kinds == ["event-after-retirement"] and (e["exit"], len(w.dead)) == before
    elif variant == "c":
        p = live_fixture(d, T, "live")
        e = adopt_or_hold(w, p, "fixture")
        snapshot = json.dumps(W.entry_view(e), sort_keys=True, default=str)
        for ev in (FakeEv(p.pid, W.NOTE_EXIT, udata=0), FakeEv(p.pid, W.NOTE_EXIT, udata=999999),
                   FakeEv(p.pid + 1, W.NOTE_EXIT, udata=e["gen"])):
            w.handle(ev)
        kinds = [v["kind"] for v in w.violations]
        rcs.append(reap(p, D_REAP))
        notes = {"violations": kinds}
        ok = kinds == ["event-unattributable"] * 3 and \
            json.dumps(W.entry_view(e), sort_keys=True, default=str) == snapshot and \
            p.pid not in [x["pid"] for x in w.dead]
    else:
        ps = [live_fixture(d, T, "f%d" % i, code="import time; time.sleep(0.%d)" % (2 + i))
              for i in range(2)]
        es = [adopt_or_hold(w, p, "fixture") for p in ps]
        rcs = [reap(p, D_REAP) for p in ps]
        run_watch_until(w, lambda: all(x["exit"] is not None for x in es), W.now() + 3.0)
        kinds = [v["kind"] for v in w.violations]
        notes = {"violations": kinds}
        ok = kinds == [] and all(sum(1 for x in w.dead if x["gen"] == e["gen"]) == 1 and
                                 e["exit"]["kind"] == "exited" for e in es)
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if all(r == 0 for r in rcs) else "rc-%r" % rcs}, runroot,
                  notes=notes)


def t37(d, scratch, runroot):
    """Locale provenance binding (F2/Q4) with an injected references runner: a reference
    list without the owning output refuses; with it, the file and literal checks decide."""
    T = "T37"
    present = W.locale_binding("nix-store", runner=lambda argv, env=None, timeout=None:
                               (0, W.LOCALE_OUT + "\n/nix/store/other\n", ""))
    absent = W.locale_binding("nix-store", runner=lambda argv, env=None, timeout=None:
                              (0, "/nix/store/other\n", ""))
    erred = W.locale_binding("nix-store", runner=lambda argv, env=None, timeout=None:
                             (1, W.LOCALE_OUT + "\n", "error\n"))
    ok = present["references"] is True and absent["references"] is False and \
        absent["ok"] is False and erred["references"] is False and erred["ok"] is False and \
        present["ok"] == (present["file"] and present["literal"])
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:injected runner"}, runroot,
                   notes={"present": present, "absent": absent, "erred": erred})


def t38_joins(d, T, primary, procs, pids, fds):
    """T38's owned joins (a40f005 review Q3): every handle and forked pid is WAITED for,
    bounded, and only then are the controller's fds closed. No step ever writes a release:
    the withheld-release condition and the autonomous-lifetime proof are preserved (a gate
    fd closed early would release its fixture by EOF). Returns {name: rc}; any handled
    failure is settled by settle_joins (primary kept, every secondary recorded)."""
    steps = [("reap-" + k, (lambda x=x: reap(x, D_REAP))) for k, x in procs.items()]
    steps += [("reap-" + k, (lambda x=x: reap_pid(x, D_REAP))) for k, x in pids.items()]
    out = join_owned(steps)
    out += join_owned([("close-fd%d" % i, (lambda fd=fd: os.close(fd)))
                       for i, fd in enumerate(fds)])
    settle_joins(d, T, primary, out)
    return {o["step"][len("reap-"):]: o["value"] for o in out if o["step"].startswith("reap-")}


def t38(d, scratch, runroot):
    """R4 withheld-release control: every controller-held fixture stage is started and NEVER
    released. Each must end by its own bound (FIXTURE_HOLD_S) and be reaped by its handle,
    with no signal from the harness: the gated execer and popen-er (exit 3), the holder and
    the holder-fed shell, the T35-style subject, the argv-tolerant HOLDER via execve, and the
    ordering target's bash stage (released past its gate, its own read -t bounds it). A
    handled failure while starting them still joins every started fixture (t38_joins)
    before the failure is re-raised."""
    T = "T38"
    root = mkroot(d, scratch, T, "root")
    t0 = W.now()
    procs, pids, fds = {}, {}, []
    primary = None
    try:
        p, gw = gated_fixture(d, T, "execer", EXECER, "/usr/bin/true", "true")
        procs["execer"] = p
        fds.append(gw)
        sin, h = stdin_holder(d, T, "popen-holder")
        procs["popen-holder"] = h
        try:
            p, gw = gated_fixture(d, T, "popen", POPENER, "read x", stdin=sin)
        finally:
            os.close(sin)
        procs["popen"] = p
        fds.append(gw)
        sin, h = stdin_holder(d, T, "shell-holder")
        procs["shell-holder"] = h
        try:
            intent(d, T, "shell", "proc")
            pids["shell"] = fork_execve("/bin/sh", ["sh", "-c", "read x"], ["E=1"],
                                        stdin_fd=sin)
        finally:
            os.close(sin)
        set_identity(d, T, "shell", proc_identity(pids["shell"], os.getpid()))
        procs["subject"] = start_fixture(d, T, "subject", HOLDER_CODE, stdin=subprocess.PIPE,
                                         stdout=subprocess.DEVNULL)
        sr, sw = os.pipe()
        fds.append(sw)
        r3, w3 = os.pipe()                   # HOLDER's readiness fd (kept open, not read)
        fds.append(r3)
        try:
            intent(d, T, "holder-exec", "proc")
            pids["holder-exec"] = fork_execve(PY, ["", "-I", "-c", HOLDER, "x"], ["E=1"],
                                              stdin_fd=sr, ready_fd=w3)
        finally:
            os.close(sr)
            os.close(w3)
        set_identity(d, T, "holder-exec", proc_identity(pids["holder-exec"], os.getpid()))
        pr, pw = os.pipe()
        fds.append(pr)
        gr, gw = gate_open()
        fds.append(gw)
        try:
            procs["order"] = start_fixture(d, T, "order", ORDER_EXECER, gr, pw,
                                           W.PKG["bash"] + "/bin/bash", pass_fds=(gr, pw))
        finally:
            os.close(gr)
            os.close(pw)
        release_gate(gw)                     # past the gate; the bash read is withheld
    except Exception as e:                   # kept; every started fixture is still joined
        primary = e
    rcs = t38_joins(d, T, primary, procs, pids, fds)
    took = W.now() - t0
    want = {"execer": 3, "popen": 3, "popen-holder": 0, "shell": 0, "shell-holder": 0,
            "subject": 0, "holder-exec": 0}
    ok = all(rcs.get(k) == v for k, v in want.items()) and rcs.get("order") not in (None, 0) \
        and took <= FIXTURE_HOLD_S + 6.0
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                  notes={"rcs": rcs, "took_s": took, "signals_sent": 0})


class FakeLauncher(object):
    def __init__(self, pid):
        self.pid, self.returncode = pid, None


def t30q(d, scratch, runroot):
    """R1/B4: image observation never grants operational permission without a closed,
    representable argv vector. Fabricated records: launcher, process-compose, devenv-tasks,
    bash shell, postmaster under the wrapper and a pg tool each give "unknown-argv" plus
    argv-unknown-operational for a missing, UNSUPPORTED or UNREPRESENTABLE vector, and their
    operational role for a known OK vector (healthy pairs); a postmaster child keeps the
    reviewed title-only rule. Effects: with os.kill INTERCEPTED (no real signal), a live
    adopted fixture whose snapshot has an unknown vector is refused (frozen, then by role
    once unfrozen for the check), and its healthy pair reaches the intercepted kill."""
    T = "T30q"
    root = mkroot(d, scratch, T, "root")
    P = W.PG_BIN + "/postgres"
    bash = W.PKG["bash"] + "/bin/bash"
    cases = {"launcher": (bash, None), "process-compose": (W.PC_BIN, None),
             "devenv-tasks": (W.DT_BIN, None), "shell": (bash, None),
             "postmaster-final": (P, "wrapper"), "pg-tool": (W.PG_BIN + "/initdb", None)}
    got, pid = {}, [8000]
    for want, (img, prole) in sorted(cases.items()):
        for status in (None, "UNSUPPORTED", "UNREPRESENTABLE", "OK"):
            w = bare_watch(root)
            pid[0] += 2
            parent = None
            if prole is not None:
                parent = {"pid": pid[0] - 1, "birth_us": 1, "role": prole, "image": bash,
                          "lineage": True, "exit": None, "parent": None, "gen": None}
                w.entries[parent["pid"]] = parent
            e = {"pid": pid[0], "birth_us": 1, "image": img, "exe": img, "lineage": True,
                 "parent": parent["pid"] if parent else None,
                 "parent_birth_us": 1 if parent else None, "exit": None, "gen": None,
                 "argv": ["x", "y"] if status == "OK" else None, "argv_status": status,
                 "argv_known": False}
            if want == "launcher":
                w.launcher = FakeLauncher(e["pid"])
            w.entries[e["pid"]] = e
            role = w.classify(e)
            kinds = [v["kind"] for v in w.violations]
            got["%s/%s" % (want, status)] = [role, kinds]
    pm = {"pid": 8901, "birth_us": 1, "role": "postmaster-final", "image": P, "lineage": True,
          "exit": None, "parent": None, "gen": None}
    child = {"pid": 8902, "birth_us": 1, "image": P, "exe": P, "lineage": True, "parent": 8901,
             "parent_birth_us": 1, "exit": None, "gen": None, "argv": None,
             "argv_status": "UNREPRESENTABLE", "argv_known": False}
    wp = bare_watch(root)
    wp.entries.update({8901: pm, 8902: child})
    got["pg-child/UNREPRESENTABLE"] = [wp.classify(child), [v["kind"] for v in wp.violations]]
    gate_ok = all(
        v == (["unknown-argv", ["argv-unknown-operational"]] if not k.endswith("/OK")
              else [k.split("/")[0], []])
        for k, v in got.items() if not k.startswith("pg-child")) and \
        got["pg-child/UNREPRESENTABLE"] == ["pg-aux", []]
    # effects, intercepted
    real_kill, kills = os.kill, []

    def snap_for(argv, status):
        return {"image": W.PC_BIN, "exec_path": W.PC_BIN, "argv": argv, "meta": None,
                "argv_status": status, "cutoff": W.now()}
    fx = {}
    eff = {}
    try:
        os.kill = lambda p_, s_: kills.append((p_, int(s_)))
        for label, argv, status in (("healthy", ["process-compose", "up"], "OK"),
                                    ("unknown", None, "UNSUPPORTED")):
            p = live_fixture(d, T, label)
            fx[label] = p
            w = bare_watch(root)
            e = adopt_or_hold(w, p, "unsnapshotted")
            w.check_exe = lambda e_: None       # the image allowlist is not the subject here
            w.apply_snapshot(e, snap_for(argv, status), "admission")
            out = []
            for attempt in (1, 2):
                try:
                    out.append(w.signal_verified(p.pid, signal.SIGTERM, "T30q"))
                except W.Hold as h:
                    out.append("HOLD:" + str(h).split(":")[0])
                if label == "unknown" and attempt == 1:
                    w.signals_frozen = False    # test-only: show the ROLE also refuses
                else:
                    break
            eff[label] = {"role": e["role"], "results": out, "signals": len(w.harness_signals)}
    finally:
        os.kill = real_kill
    rcs = {k: reap(p, D_REAP) for k, p in fx.items()}
    eff_ok = eff.get("healthy", {}).get("results") == ["sent"] and \
        eff["healthy"]["role"] == "process-compose" and \
        kills == [(fx["healthy"].pid, int(signal.SIGTERM))] and \
        eff.get("unknown", {}).get("role") == "unknown-argv" and \
        len(eff["unknown"]["results"]) == 2 and \
        all(r.startswith("HOLD") for r in eff["unknown"]["results"]) and \
        eff["unknown"]["signals"] == 0
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if gate_ok and eff_ok else "FAIL",
                  {"fixtures": "ok" if all(r == 0 for r in rcs.values()) else "rc-%r" % rcs},
                  runroot, notes={"classify": got, "effects": eff, "kills": kills})


def t30r(d, scratch, runroot):
    """R2: nested admission under the shared bound. A live fixture X has a live child Y
    (bounded). (a) A slow identity read of Y crosses the bound BEFORE registration: no
    later stage starts, Y gets no generation and stays unadmitted, no violation. (b) The
    bound expires DURING registration: the token is never sealed (unbound-deadline,
    registration-deadline violation), Y is not admitted, and Y's own NOTE_EXIT retires the
    token. (c) The bound expires during admit's FINAL parent read: the sealed token is
    withdrawn (unbound-deadline, registration-deadline), no entry and no obligation is
    created. (d) Healthy pair: Y is admitted with its admission obligation. handle()
    returns promptly in a-c."""
    T = "T30r"
    root = mkroot(d, scratch, T, "root")
    notes, oks, rcs = {}, [], []
    for v in ("a", "b", "c", "d"):
        try:
            ok = t30r_variant(d, T, root, v, notes, rcs)
        except Exception as e:   # kept; the variant's fixture and watch are still joined
            t30r_joins(d, T, v, e, getattr(e, "t30r_x", None), getattr(e, "t30r_w", None))
        oks.append(ok)
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if all(oks) else "FAIL",
                  {"fixtures": "ok" if all(r == 0 for r in rcs) else "rc-%r" % rcs}, runroot,
                  notes=notes)


def t30r_joins(d, T, v, primary, x, w):
    """T30r's owned joins on a handled failure (a40f005 review Q3): the variant's fixture X
    is reaped (bounded; X exits after its own 2 s child) and the variant's watch kqueue is
    closed; monkeypatches were already restored by the variant's own finally. The primary
    failure is re-raised unchanged with every outcome recorded (settle_joins)."""
    steps = []
    if x is not None:
        steps.append(("x-%s-reap" % v, lambda: reap(x, D_REAP)))
    if w is not None:
        steps.append(("watch-%s-kq-close" % v, lambda: w.kq.close()))
    settle_joins(d, T, primary, join_owned(steps))


def t30r_variant(d, T, root, v, notes, rcs):
    """One T30r variant (see t30r). A handled failure carries the started fixture and
    watch on the exception (t30r_x, t30r_w) for t30r_joins."""
    x = w = None
    try:
        x = start_fixture(d, T, "x-" + v, "import subprocess,sys;"
                          "y=subprocess.Popen([sys.executable,'-I','-B','-c',"
                          "'import time; time.sleep(2)']);print(y.pid,flush=True);y.wait()",
                          stdout=subprocess.PIPE)
        ypid = int(bounded_readline(x.stdout))
        intent(d, T, "y-" + v, "proc")
        set_identity(d, T, "y-" + v, proc_identity(ypid, x.pid))
        w = bare_watch(root)
        ex = adopt_or_hold(w, x, "fixture")
        real_bsd, real_reg = W.bsdinfo, w.register
        parent_reads = [0]

        def slow_bsd(pid):
            if pid == ypid:
                time.sleep(0.3)
            return real_bsd(pid)

        def slow_final_parent(pid):
            if pid == x.pid:
                parent_reads[0] += 1
                if parent_reads[0] == 2:          # admit's final parent read
                    time.sleep(0.3)
            return real_bsd(pid)

        def slow_reg(pid):
            g = real_reg(pid)
            time.sleep(0.3)
            return g
        t0 = W.now()
        try:
            if v == "a":
                W.bsdinfo = slow_bsd
            elif v == "b":
                w.register = slow_reg
            elif v == "c":
                W.bsdinfo = slow_final_parent
            w.handle(FakeEv(x.pid, W.NOTE_FORK, udata=ex["gen"]),
                     t0 + (2.0 if v == "d" else 0.2))
        finally:
            W.bsdinfo = real_bsd
            if v == "b":
                del w.register
        took = W.now() - t0
        ygens = [g for g, r in w.gens.items() if r["pid"] == ypid]
        kinds = [k["kind"] for k in w.violations]
        if v == "a":
            ok = ygens == [] and ypid not in w.entries and kinds == [] and took <= 0.6
        elif v in ("c", "d"):
            st0 = [w.gens[g]["state"] for g in ygens]
            req = [w.requests.get(g, {}).get("kind") for g in ygens]
            if v == "c":      # sealed, then the final parent read returned late
                ok = st0 == ["unbound-deadline"] and ypid not in w.entries and req == [None] \
                    and kinds == ["registration-deadline"] and took <= 0.6
            else:             # healthy pair: admitted with its admission obligation
                ok = st0 == ["live"] and ypid in w.entries and req == ["admission"] and \
                    kinds == []
            notes[v + "_state"] = [st0, req]
        else:
            st0 = [w.gens[g]["state"] for g in ygens]
            rcs.append(reap(x, D_REAP))
            run_watch_until(w, lambda: all(w.gens[g]["state"] == "retired" for g in ygens),
                            W.now() + 5.0)
            st1 = [w.gens[g]["state"] for g in ygens]
            ok = st0 == ["unbound-deadline"] and st1 == ["retired"] and \
                ypid not in w.entries and kinds == ["registration-deadline"] and took <= 0.6
            notes["b_states"] = [st0, st1]
        if v != "b":
            rcs.append(reap(x, D_REAP))
        notes[v] = {"took_s": took, "violations": kinds, "gens": len(ygens)}
        return ok
    except Exception as e:
        e.t30r_x, e.t30r_w = x, w
        raise


class SlowEmptyKq(object):
    """fixture-synthetic: every fetch returns [] only after `delay` seconds."""

    def __init__(self, delay):
        self.delay = delay

    def control(self, changes, n, timeout=None):
        if changes:
            raise OSError(1, "stub kqueue takes no registrations")
        time.sleep(self.delay)
        return []


def t30s(d, scratch, runroot):
    """R2: a read, a path resolution or an empty fetch that RETURNS after the bound never
    yields VALID or an empty-fence claim: slow procargs, slow pidpath and a slow final
    realpath give UNKNOWN; a slow empty fetch makes fence() None and the snapshot UNKNOWN;
    the healthy pair is VALID."""
    T = "T30s"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    p = live_fixture(d, T, "target")
    e = adopt_or_hold(w, p, "fixture")
    g = e["gen"]
    out = {}
    real_pa, real_pp = W.procargs, W.pidpath

    def slow(fn):
        def f(*a, **k):
            time.sleep(0.3)
            return fn(*a, **k)
        return f
    try:
        W.procargs = slow(real_pa)
        out["slow_procargs"] = w.snapshot(g, W.now() + 0.2)["result"]
        W.procargs = real_pa
        W.pidpath = slow(real_pp)
        out["slow_pidpath"] = w.snapshot(g, W.now() + 0.2)["result"]
    finally:
        W.procargs, W.pidpath = real_pa, real_pp
    real_rp = os.path.realpath
    try:
        os.path.realpath = slow(real_rp)
        out["slow_realpath"] = w.snapshot(g, W.now() + 0.2)["result"]
    finally:
        os.path.realpath = real_rp
    real_kq = w.kq
    w.kq = SlowEmptyKq(0.3)
    out["slow_fence"] = w.fence(W.now() + 0.2)
    out["slow_fetch_snapshot"] = w.snapshot(g, W.now() + 0.2)["result"]
    w.kq = real_kq
    out["healthy"] = w.snapshot(g, W.now() + 2.0)["result"]
    rc = reap(p, D_REAP)
    labels = ["root"]
    ok = out == {"slow_procargs": "UNKNOWN", "slow_pidpath": "UNKNOWN",
                 "slow_realpath": "UNKNOWN", "slow_fence": None,
                 "slow_fetch_snapshot": "UNKNOWN", "healthy": "VALID"}
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if rc == 0 else "rc-%s" % rc}, runroot, notes=out)


def t30t(d, scratch, runroot):
    """R2 effect path: quiesce refuses an effect while a required image obligation of ANOTHER
    target is unresolved after a handler consumed the bound (os.kill INTERCEPTED, no real
    signal): HOLD, no kill, no harness signal. The final identity proof returning after the
    quiesce bound (slowproof) is also HOLD with no kill even though the overall deadline is
    far away. Healthy pair: the obligation resolves inside the bound and the intercepted
    kill is reached once."""
    T = "T30t"
    root = mkroot(d, scratch, T, "root")
    real_kill, kills, res, fx = os.kill, [], {}, {}
    try:
        os.kill = lambda p_, s_: kills.append((p_, int(s_)))
        for label in ("slow", "slowproof", "healthy"):
            a = live_fixture(d, T, "a-" + label)
            b = live_fixture(d, T, "b-" + label)
            fx["a-" + label], fx["b-" + label] = a, b
            w = bare_watch(root)
            ea = adopt_or_hold(w, a, "process-compose", image=W.PC_BIN, argv=["process-compose"])
            eb = adopt_or_hold(w, b, "fixture")
            w.kq = StubKq([[FakeEv(b.pid, W.NOTE_EXEC, udata=eb["gen"])]])
            w.apply_snapshot = lambda e_, s_, k_: None     # B's image is not the subject
            if label == "slow":
                real_handle = w.handle

                def slow(ev, deadline=W.INF, _h=real_handle):
                    time.sleep(0.3)
                    _h(ev, deadline)
                w.handle = slow
            n0 = len(kills)
            real_bsd = W.bsdinfo

            def slow_proof(pid, _a=a.pid, _r=real_bsd):
                if pid == _a:
                    time.sleep(0.3)               # past the 0.25 s quiesce bound
                return _r(pid)
            try:
                if label == "slowproof":
                    W.bsdinfo = slow_proof
                r = w.signal_verified(a.pid, signal.SIGTERM, "T30t", deadline=W.now() + 30.0)
            except W.Hold as h:
                r = "HOLD:" + str(h)[:60]
            finally:
                W.bsdinfo = real_bsd
            res[label] = {"result": r, "kills": len(kills) - n0,
                          "harness_signals": len(w.harness_signals),
                          "unresolved": sorted(w.requests), "a_role": ea["role"]}
    finally:
        os.kill = real_kill
    rcs = {k: reap(p, D_REAP) for k, p in fx.items()}
    ok = all(res[k]["result"].startswith("HOLD") and res[k]["kills"] == 0 and
             res[k]["harness_signals"] == 0 for k in ("slow", "slowproof")) and \
        res["healthy"]["result"] == "sent" and res["healthy"]["kills"] == 1
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if all(r == 0 for r in rcs.values()) else "rc-%r" % rcs},
                  runroot, notes=res)


def t30u(d, scratch, runroot):
    """R2 multi-request expiry: expired obligations of three live fixtures. (a) Bound already
    exhausted: all three are judged unread (image-snapshot-unresolved, liveness unread) and
    NO identity read is started. (b) The first read is slow and crosses the bound: exactly
    one read happens; the other two are judged unread. (c) Healthy pair: with time left each
    live identity is read and judged, and a gone identity's obligation is kept (for its
    exit event), never dropped."""
    T = "T30u"
    root = mkroot(d, scratch, T, "root")
    fx, out = [], {}
    real_bsd = W.bsdinfo
    for case in ("a", "b", "c"):
        w = bare_watch(root)
        ents = []
        for i in range(3):
            p = live_fixture(d, T, "%s%d" % (case, i))
            fx.append(p)
            ents.append(adopt_or_hold(w, p, "fixture"))
        gone = unregistered_gone(w, d, T, "%s-gone" % case) if case == "c" else None
        for e in ents + ([gone] if gone else []):
            w.request(e["gen"], "exec")
            w.requests[e["gen"]]["deadline"] = W.now() - 1.0     # already expired
        pids = {e["pid"] for e in ents + ([gone] if gone else [])}
        reads = []

        def counting(pid, _slow=(case == "b")):
            if pid in pids:
                reads.append(pid)
                if _slow and len(reads) == 1:
                    time.sleep(0.3)
            return real_bsd(pid)
        try:
            W.bsdinfo = counting
            bound = W.now() - 0.001 if case == "a" else W.now() + (0.2 if case == "b" else 2.0)
            w.expire_requests(bound)
        finally:
            W.bsdinfo = real_bsd
        v = w.violations
        out[case] = {"reads": len(reads),
                     "unread": sum(1 for x in v if x.get("liveness")),
                     "read_judged": sum(1 for x in v if x["kind"] == "image-snapshot-unresolved"
                                        and not x.get("liveness")),
                     "kept": sorted(w.requests) == ([gone["gen"]] if gone else [])}
    rcs = [reap(p, D_REAP) for p in fx]
    ok = out["a"] == {"reads": 0, "unread": 3, "read_judged": 0, "kept": True} and \
        out["b"] == {"reads": 1, "unread": 2, "read_judged": 1, "kept": True} and \
        out["c"] == {"reads": 4, "unread": 0, "read_judged": 3, "kept": True}
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if all(r == 0 for r in rcs) else "rc-%r" % rcs}, runroot,
                  notes=out)


def t30v(d, scratch, runroot):
    """R3 negative-companion control (pure): hidden_companion_proves accepts ONLY the
    specific unsafe outcome (progress "ba", no exec handled, VALID for the new image and
    vector). GONE, INCONSISTENT, UNKNOWN, missing progress, a handled exec, the old image
    or another vector cannot satisfy the negative-companion requirement."""
    T = "T30v"
    base = {"oracle": "FAIL", "result": "VALID", "progress": "ba",
            "execs_handled_at_snapshot": 0, "image": "/nix/store/x-bash/bin/bash",
            "want_image": "/nix/store/x-bash/bin/bash", "argv": ["bash", "-c", "k"],
            "want_argv": ["bash", "-c", "k"]}
    cases = {
        "unsafe_valid": dict(base),
        "gone": dict(base, oracle="FAIL", result="GONE", image="", argv=None),
        "inconsistent": dict(base, oracle="FAIL", result="INCONSISTENT", image="", argv=None),
        "unknown": dict(base, oracle="UNMEASURED", result="UNKNOWN"),
        "no_progress": dict(base, progress="b"),
        "exec_handled": dict(base, execs_handled_at_snapshot=1),
        "old_image": dict(base, image="/nix/store/y-python3/bin/python3"),
        "other_vector": dict(base, argv=["bash", "-c", "other"]),
        "void": dict(base, oracle="PASS", result="VOID"),
    }
    got = {k: hidden_companion_proves(v) for k, v in sorted(cases.items())}
    ok = got == {k: k == "unsafe_valid" for k in cases}
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:fabricated run records"}, runroot, notes=got)


def raw_procargs2(pid, oldlen):
    """A test-local KERN_PROCARGS2 sysctl with a buffer and oldlen of exactly `oldlen` bytes,
    independent of sink_watch's own reader: (rc, errno, data, n). Raw bytes stay in memory;
    receipts record only rc, errno, n and parse status."""
    buf = ctypes.create_string_buffer(max(int(oldlen), 1))
    size = ctypes.c_size_t(int(oldlen))
    mib = (ctypes.c_int * 3)(W.CTL_KERN, W.KERN_PROCARGS2, os.getpid() if pid is None else pid)
    ctypes.set_errno(0)
    rc = W.libc().sysctl(mib, 3, buf, ctypes.byref(size), None, 0)
    return rc, ctypes.get_errno(), buf.raw, size.value


T30W_CASES = ("width_invariant", "requested_cap", "at_bound", "cap_eq_argmax", "one_over",
              "old_cap", "argc_only", "underflow", "too_small", "live_einval_hold")


def t30w(d, scratch, runroot):
    """KERN_PROCARGS2 INTERFACE bounds (a40f005 review A1/A2), on this process's own argument
    area; no fixture, no layout decoding. Source (xnu-11417.140.69 kern_sysctl.c
    sysctl_procargsx 1359-1369, 1555-1613): buflen = oldlen - sizeof(int) must satisfy
    0 < buflen <= ARG_MAX (= kern.argmax), else EINVAL; a buffer smaller than the area returns
    rc 0 with n == oldlen (its tail). Pinned cases (all must be present):
    width_invariant (argc word is 4 bytes), requested_cap (sink_watch.procargs requests
    exactly kern.argmax + 4 through its reader seam), at_bound / cap_eq_argmax (rc 0 and a
    bounded n, NOT a decoded argv: that is T30m's layout claim), one_over / old_cap /
    argc_only / underflow (EINVAL), too_small (rc 0, n == oldlen, and parse_procargs refuses
    it as MALFORMED by its n >= cap rule, which precedes any layout decoding),
    live_einval_hold (EINVAL for a live identity is HOLD, unchanged). The public source vs
    running .709.8 build gap is an inference: a mismatch here returns for review; nothing is
    adjusted at runtime."""
    T = "T30w"
    A = W.kern_argmax()
    me_b = W.bsdinfo(os.getpid())["birth_us"]
    got = {}
    got["width_invariant"] = ctypes.sizeof(ctypes.c_int) == 4
    seen = []

    def recorder(pid, cap):
        seen.append(cap)
        return 0, 0, b"\0" * 8, 8
    W.procargs(os.getpid(), me_b, reader=recorder)
    got["requested_cap"] = {"requested_minus_argmax": seen[0] - A if seen else None,
                            "ok": seen == [A + 4]}

    def case(oldlen):
        rc, err, data, n = raw_procargs2(None, oldlen)
        return rc, err, n
    rc, err, n = case(A + 4)
    got["at_bound"] = {"rc": rc, "errno": err, "ok": rc == 0 and 4 < n < A + 4}
    rc, err, n = case(A)
    got["cap_eq_argmax"] = {"rc": rc, "errno": err, "ok": rc == 0 and 4 < n < A}
    for name, oldlen in (("one_over", A + 5), ("old_cap", A + 4096), ("argc_only", 4),
                         ("underflow", 3)):
        rc, err, n = case(oldlen)
        got[name] = {"rc": rc, "errno": err, "ok": rc != 0 and err == errno.EINVAL}
    rc, err, data, n = raw_procargs2(None, 20)
    st = W.parse_procargs(data, n, 20)["status"] if rc == 0 else None
    got["too_small"] = {"rc": rc, "n": n, "status": st,
                        "ok": rc == 0 and n == 20 and st == "MALFORMED"}
    try:
        W.procargs(os.getpid(), me_b, reader=lambda pid, cap: (-1, errno.EINVAL, b"", 0))
        held = False
    except W.Hold as h:
        held = "errno 22 for the live tracked identity" in str(h)
    got["live_einval_hold"] = held
    ok = tuple(sorted(got)) == tuple(sorted(T30W_CASES)) and all(
        (v is True) if isinstance(v, bool) else v.get("ok") is True for v in got.values())
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL",
                   {"fixtures": "not-applicable:own process, no fixture"}, runroot, notes=got)


T30X_SUBCASES = ("primary_observation_failure", "release_failure",
                 "child_join_failure_later_holders_joined", "holder_join_failure",
                 "t38_joins_withheld", "t30r_joins", "post_fork_close_failure",
                 "final_holder_reap_failure", "leftover_exception_path",
                 "record_write_failure", "leftover_rc_binding",
                 "orchestration_registration", "record_and_diagnostic_failure")


def leftover_rc_problems(expected, outcomes):
    """Per-fixture rc binding (2eaff27 review R3): `expected` maps each leftover step label
    to its exact expected rc; an unjoined, failed, missing or different rc is a problem.
    There is no blanket nonzero allowance."""
    by = {o["step"]: o for o in outcomes}
    probs = []
    for label, want in sorted(expected.items()):
        o = by.get(label)
        if o is None:
            probs.append((label, "missing"))
        elif not o["ok"]:
            probs.append((label, "join-failed:%s" % o.get("error_class")))
        elif o["value"] != want:
            probs.append((label, "rc %r != expected %r" % (o["value"], want)))
    return probs


def t30x_join_leftovers(d, T, primary, leftovers, joiners=None):
    """T30x's own leftover joins (2eaff27 R1/R3, e52fc41 review): `leftovers` is a list of
    (label, kind, handle-or-pid-or-fd, expected value); kinds: proc (bounded reap), pid
    (bounded reap_pid), fd (close; expected None). Every join is attempted even after an
    earlier one fails. The expected-value binding is computed BEFORE settlement and kept:
    each mismatch marks its outcome rc_ok false and adds a failed "<label>-expected-rc"
    outcome, so a nonzero rc is never shown as joined, with or without a primary. A
    primary failure is re-raised unchanged with all outcomes on its own record; otherwise
    any failed step raises an uncertainty. Returns (outcomes, rc problems)."""
    j = {"proc": lambda x: reap(x, D_REAP), "pid": lambda x: reap_pid(x, D_REAP),
         "fd": lambda x: close_fd(x)}
    j.update(joiners or {})
    steps = [(label, (lambda x=x, f=j[kind]: f(x))) for label, kind, x, _want in leftovers]
    out = join_owned(steps)
    want = {lab: w for lab, _k, _x, w in leftovers}
    probs = leftover_rc_problems(want, out)
    bad = {lab for lab, _why in probs}
    for o in out:
        if o["step"] in want:
            o["expected_rc"] = want[o["step"]]
            o["rc_ok"] = o["step"] not in bad
    out += [{"step": lab + "-expected-rc", "ok": False, "error_class": "UnexpectedOutcome",
             "error": why} for lab, why in probs if not why.startswith("join-failed")]
    settle_joins(d, T, primary, out)
    return out, probs


def own_holders(own, sub):
    """Register a holder list with the T30x collector at acquisition: t30m_case appends each
    holder to it as soon as the holder is started."""
    lst = []
    own["holders"].append((sub, lst))
    return lst


def own_pid(own, pid):
    """Register a forked child the harness has NOT reaped (expected rc 0)."""
    own["pids"].append(pid)


def own_fd(own, name, fd):
    own["fds"][name] = fd


def disown_fd(own, name):
    own["fds"].pop(name, None)


def t30x_leftovers(own):
    out = []
    for sub, lst in own["holders"]:
        out += [("leftover-%s-holder%d" % (sub, i), "proc", hh, 0) for i, hh in enumerate(lst)]
    out += [("leftover-pid%d" % pp, "pid", pp, 0) for pp in own["pids"]]
    out += [("leftover-fd-%s" % name, "fd", fd, None) for name, fd in sorted(own["fds"].items())]
    return out


def t30x_orchestrate(d, T, body, joiners=None):
    """T30x's outer orchestration (e52fc41 review R1): ownership is registered in `own` at
    acquisition (own_holders, own_pid, own_fd) by `body`; ANY handled failure in body is the
    primary, and every registered leftover is then joined (all attempted, each against its
    expected value) before the primary is re-raised unchanged. Returns
    (body result, outcomes, rc problems) on the normal path."""
    own = {"holders": [], "pids": [], "fds": {}}
    primary, result = None, None
    try:
        result = body(own)
    except Exception as e:
        primary = e
    out, probs = t30x_join_leftovers(d, T, primary, t30x_leftovers(own), joiners)
    return result, out, probs


class FakeJoinProc(object):
    """fixture-synthetic process handle for the T38/T30r join controls: wait() records the
    call and whether the watched fds were still open, then returns `rc` or times out."""

    def __init__(self, rc, fds, calls):
        self.rc, self.fds, self.calls, self.pid, self.returncode = rc, fds, calls, 0, None

    def wait(self, timeout=None):
        open_now = []
        for fd in self.fds:
            try:
                os.fstat(fd)
                open_now.append(True)
            except OSError:
                open_now.append(False)
        self.calls.append(("wait", self.rc, all(open_now)))
        if self.rc is None:
            raise subprocess.TimeoutExpired("fake", timeout)
        self.returncode = self.rc
        return self.rc


class FakeJoinKq(object):
    def __init__(self, calls):
        self.calls = calls

    def close(self):
        self.calls.append(("kq-close",))
        raise OSError("injected kqueue close failure (fixture-synthetic)")


def t30x(d, scratch, runroot):
    """Exception-path regressions for T30m/T38/T30r joins (a40f005 A3, 2eaff27 R1-R3). Each
    real-fixture subcase runs one t30m_case with an INJECTED failure and requires: every
    owned release/join attempted and recorded; the primary re-raised as the same object;
    every secondary failure kept on that settlement's OWN record (never unlinked or
    overwritten; each result links its record path); no receipt, no disposal, no signal.
    (1) observation failure; (2) release failure (no primary); (3) child join failure with
    an earlier holder still joined; (4) holder join failure under a primary; (5) T38 joins
    on fake handles (withheld release preserved); (6) T30r joins on fakes; (7) post-fork
    close failure (the child and its holder still joined); (8) T30m's final holder phase:
    the first reap fails and the next is still attempted, plus a healthy pair; (9) T30x's
    own leftover joins under a primary failure, plus a healthy pair; (10) join-record write
    failure with a primary and with only a secondary: the failure is added to the failed
    steps and a metadata-only diagnostic line is written to stderr; (11) the per-fixture
    leftover rc binding: an unexpected exit 1 for an expected-zero fixture is a problem,
    the healthy expected-zero pair is not; (12) the REAL outer orchestration
    (t30x_orchestrate): a failure after ownership acquisition and before record inspection
    still joins every registered holder and injected-unreaped child, plus a healthy pair,
    plus an unexpected rc under a primary (computed and kept before settlement); (13) the
    record write AND its stderr diagnostic both failing: the primary is kept with the
    failure recorded, and the secondary-only path names it. Every holder list,
    injected-unreaped child and descriptor is registered AT ACQUISITION; the collector
    joins them all, bounded, each against its own expected value, and re-raises a primary
    unchanged."""
    T = "T30x"
    root = mkroot(d, scratch, T, "root")
    shells = {os.path.realpath(x) for x in W.SYSTEM_SH}
    py_case = (PY, ["px", "-I", "-c", HOLDER], ["E=1"], "exact", False)
    sh_case = ("/bin/sh", ["sh", "-c", "echo r >&3; read x"], ["E=1"], "shell", True)
    g = globals()
    real = {k: g[k] for k in ("release_holder", "reap_pid", "reap", "close_fd",
                              "write_join_record")}
    out, records, n = {}, {}, [0]

    def run(case, holders):
        n[0] += 1
        try:
            t30m_case(d, T, n[0], case, shells, holders)
            return None
        except Exception as e:
            return e

    def rec(e, key):
        path = getattr(e, "join_record", None)
        records[key] = path
        return W.jload(path) if path and os.path.exists(path) else None

    def undisposed():
        return [f["label"] for f in registry(d)["fixtures"]
                if f["test"] == T and f.get("disposed") is not None]

    injected = W.Hold("injected observation failure (fixture-synthetic)")
    real_pa = W.procargs

    def body(own):
        """The subcases. Every holder list, injected-unreaped child and descriptor is
        registered with the collector AT ACQUISITION (own_holders / own_pid / own_fd), so a
        failure anywhere here still joins it (t30x_orchestrate)."""
        try:
            # (1) primary observation failure
            W.procargs = lambda pid, birth_us, reader=None: (_ for _ in ()).throw(injected)
            holders = own_holders(own, "1")
            e = run(py_case, holders)
            W.procargs = real_pa
            j = rec(e, "1")
            out["primary_observation_failure"] = {
                "same_primary": e is injected,
                "own_record": bool(j) and (j.get("primary") or {}).get("class") == "Hold",
                "all_ok": bool(j) and all(o["ok"] for o in j["joins"]),
                "reaped": bool(j) and any(o["step"].endswith("-reap") and o["ok"]
                                          for o in j["joins"])}
            # (2) release failure, no primary
            holders = own_holders(own, "2")

            def bad_release(h):
                raise OSError("injected release failure (fixture-synthetic)")
            g["release_holder"] = bad_release
            e = run(sh_case, holders)
            g["release_holder"] = real["release_holder"]
            j = rec(e, "2")
            steps = {o["step"]: o for o in (j or {}).get("joins", [])}
            out["release_failure"] = {
                "uncertainty": isinstance(e, RealUncertainty) and "release-holder" in str(e),
                "release_recorded_failed": any(k.endswith("release-holder") and not v["ok"]
                                               for k, v in steps.items()),
                "child_reaped": any(k.startswith("case") and k.endswith("-reap") and v["ok"]
                                    and v["value"] == 0 for k, v in steps.items())}
            # (3) the child's join fails; an earlier holder's join is still attempted
            holders = own_holders(own, "3")
            e0 = run(sh_case, holders)                  # healthy held case: its holder stays

            def bad_reap_pid(pid, deadline_s):
                own_pid(own, pid)           # registered at the injection itself
                raise RealUncertainty("injected child join failure (fixture-synthetic)")
            g["reap_pid"] = bad_reap_pid
            e = run(py_case, holders)
            g["reap_pid"] = real["reap_pid"]
            j = rec(e, "3")
            steps = {o["step"]: o for o in (j or {}).get("joins", [])}
            out["child_join_failure_later_holders_joined"] = {
                "healthy_first": e0 is None,
                "uncertainty": isinstance(e, RealUncertainty) and "-reap" in str(e),
                "holder_join_attempted": any(k.startswith("holder") and v["ok"]
                                             for k, v in steps.items()),
                "holder_reaped": all(hh.returncode is not None for hh in holders)}
            # (4) a holder's join fails under a primary failure
            holders = own_holders(own, "4")
            e0 = run(sh_case, holders)
            g["reap"] = lambda proc, deadline_s: (_ for _ in ()).throw(
                RealUncertainty("injected holder join failure (fixture-synthetic)"))
            W.procargs = lambda pid, birth_us, reader=None: (_ for _ in ()).throw(injected)
            e = run(py_case, holders)
            W.procargs = real_pa
            g["reap"] = real["reap"]
            j = rec(e, "4")
            out["holder_join_failure"] = {
                "healthy_first": e0 is None, "same_primary": e is injected,
                "holder_failure_recorded": bool(j) and any(
                    o["step"].startswith("holder") and not o["ok"] for o in j["joins"]),
                "primary_recorded": bool(j) and (j.get("primary") or {}).get("class") == "Hold"}
            # (5) T38 joins: withheld release preserved, all attempted, fds closed after
            calls = []
            f1, f2 = os.pipe()
            own_fd(own, "s5-r", f1)
            own_fd(own, "s5-w", f2)
            fds = [f1, f2]
            procs = {"bad": FakeJoinProc(None, fds, calls), "good": FakeJoinProc(0, fds, calls)}
            try:
                t38_joins(d, T, None, procs, {}, fds)
                e = None
            except Exception as ex:
                e = ex
            j = rec(e, "5")
            still_open = []
            for fd in fds:
                try:
                    os.fstat(fd)
                    still_open.append(fd)
                except OSError:
                    pass
            for fd in still_open:
                os.close(fd)
            disown_fd(own, "s5-r")
            disown_fd(own, "s5-w")
            out["t38_joins_withheld"] = {
                "uncertainty": isinstance(e, RealUncertainty) and "reap-bad" in str(e),
                "both_waited": [c[1] for c in calls] == [None, 0],
                "fds_open_during_waits": all(c[2] for c in calls),
                "fds_closed_after": still_open == [],
                "no_release_step": bool(j) and not any("release" in o["step"]
                                                       for o in j["joins"])}
            # (6) T30r joins: a failing reap and a failing kqueue close, primary preserved
            calls = []
            prim = W.Hold("injected T30r variant failure (fixture-synthetic)")

            class FakeWatch(object):
                kq = FakeJoinKq(calls)
            try:
                t30r_joins(d, T, "z", prim, FakeJoinProc(None, [], calls), FakeWatch())
                e = None
            except Exception as ex:
                e = ex
            j = rec(e, "6")
            out["t30r_joins"] = {
                "same_primary": e is prim,
                "both_attempted": [c[0] for c in calls] == ["wait", "kq-close"],
                "both_failures_recorded": bool(j) and sorted(
                    o["step"] for o in j["joins"] if not o["ok"]) == ["watch-z-kq-close",
                                                                      "x-z-reap"]}
            # (7) post-fork close failure: the child and its holder are still joined
            holders = own_holders(own, "7")
            boom = OSError("injected post-fork close failure (fixture-synthetic)")
            first = [True]

            def bad_close(fd):
                real["close_fd"](fd)
                if first[0]:
                    first[0] = False
                    raise boom
            g["close_fd"] = bad_close
            e = run(sh_case, holders)
            g["close_fd"] = real["close_fd"]
            j = rec(e, "7")
            steps = {o["step"]: o for o in (j or {}).get("joins", [])}
            out["post_fork_close_failure"] = {
                "same_primary": e is boom,
                "child_reaped": any(k.startswith("case") and k.endswith("-reap") and v["ok"]
                                    for k, v in steps.items()),
                "holder_reaped": any(k.startswith("holder") and v["ok"] for k, v in steps.items())}
            # (8) T30m's final holder phase: first reap fails, the next is still attempted
            calls = []
            try:
                t30m_join_holders(d, T, [FakeJoinProc(None, [], calls), FakeJoinProc(0, [], calls)])
                e = None
            except Exception as ex:
                e = ex
            j = rec(e, "8")
            healthy_calls = []
            healthy = t30m_join_holders(d, T, [FakeJoinProc(0, [], healthy_calls),
                                               FakeJoinProc(0, [], healthy_calls)])
            out["final_holder_reap_failure"] = {
                "uncertainty": isinstance(e, RealUncertainty) and "holder0-reap" in str(e),
                "second_attempted": [c[1] for c in calls] == [None, 0],
                "own_record": bool(j) and j["failed_steps"] == ["holder0-reap"],
                "healthy_pair": healthy == [0, 0] and len(healthy_calls) == 2}
            # (9) T30x's own leftover joins under a primary failure, and a healthy pair
            calls = []
            prim = W.Hold("injected T30x subcase failure (fixture-synthetic)")
            fakes = [("fake-a", "proc", FakeJoinProc(None, [], calls), 0),
                     ("fake-b", "proc", FakeJoinProc(0, [], calls), 0)]
            try:
                t30x_join_leftovers(d, T, prim, fakes)
                e = None
            except Exception as ex:
                e = ex
            j = rec(e, "9")
            hcalls = []
            hout, hprobs = t30x_join_leftovers(d, T, None, [
                ("fake-c", "proc", FakeJoinProc(0, [], hcalls), 0),
                ("fake-d", "proc", FakeJoinProc(0, [], hcalls), 0)])
            out["leftover_exception_path"] = {
                "same_primary": e is prim,
                "both_attempted": [c[1] for c in calls] == [None, 0],
                "recorded": bool(j) and j["failed_steps"] == ["fake-a"],
                "healthy_pair": hprobs == [] and len(hcalls) == 2}
            # (10) join-record write failure: with a primary, and with only a secondary
            def bad_write(path, rec_):
                raise OSError("injected record write failure (fixture-synthetic)")
            cap = io.StringIO()
            real_err = sys.stderr
            g["write_join_record"] = bad_write
            try:
                sys.stderr = cap
                prim = W.Hold("injected primary for the record-write control (fixture-synthetic)")
                try:
                    settle_joins(d, T, prim, [{"step": "s-a", "ok": False, "error_class": "X",
                                               "error": "x"}])
                    ep = None
                except Exception as ex:
                    ep = ex
                try:
                    settle_joins(d, T, None, [{"step": "s-b", "ok": False, "error_class": "X",
                                               "error": "x"}])
                    es = None
                except Exception as ex:
                    es = ex
            finally:
                sys.stderr = real_err
                g["write_join_record"] = real["write_join_record"]
            diag = [ln for ln in cap.getvalue().splitlines()
                    if ln.startswith("JOINS-RECORD-UNWRITTEN ")]
            out["record_write_failure"] = {
                "primary_kept": ep is prim and getattr(ep, "join_record", "x") is None and any(
                    o["step"] == "joins-record" and not o["ok"] for o in ep.join_outcomes),
                "secondary_uncertainty": isinstance(es, RealUncertainty) and
                "joins-record" in str(es) and "s-b" in str(es) and "UNWRITTEN" in str(es),
                "diagnostics": len(diag) == 2 and "primary_class=Hold" in diag[0] and
                "failed_steps=s-a,joins-record" in diag[0] and "primary_class=none" in diag[1] and
                "failed_steps=s-b,joins-record" in diag[1] and
                not any("fixture-synthetic" in ln for ln in diag)}
            # (11) per-fixture rc binding: unexpected exit 1 vs the healthy expected-zero pair
            neg = leftover_rc_problems({"h": 0}, [{"step": "h", "ok": True, "value": 1}])
            pos = leftover_rc_problems({"h": 0, "k": 0},
                                       [{"step": "h", "ok": True, "value": 0},
                                        {"step": "k", "ok": True, "value": 0}])
            out["leftover_rc_binding"] = {"unexpected_exit1_rejected": neg == [
                ("h", "rc 1 != expected 0")], "healthy_zero_pair_accepted": pos == []}
            # (12) the REAL outer orchestration: a failure after ownership acquisition
            # but before record inspection still joins every registered leftover
            calls = []
            boom = ValueError("injected record read failure (fixture-synthetic)")
            fake_pid = {"pid": lambda x: calls.append(("pid", x)) or 0}

            def failing_body(own2):
                own_holders(own2, "s").append(FakeJoinProc(0, [], calls))
                own_pid(own2, 424242)
                raise boom

            def healthy_body(own2):
                lst = own_holders(own2, "s")
                lst.append(FakeJoinProc(0, [], calls))
                lst.append(FakeJoinProc(0, [], calls))
                return "done"

            def unexpected_rc_body(own2):
                own_holders(own2, "s").append(FakeJoinProc(1, [], calls))
                raise boom
            try:
                t30x_orchestrate(d, T, failing_body, fake_pid)
                e = None
            except Exception as ex:
                e = ex
            failing_calls, calls[:] = list(calls), []
            j = rec(e, "12-failing")
            hres, hout, hprobs = t30x_orchestrate(d, T, healthy_body, fake_pid)
            healthy_calls, calls[:] = list(calls), []
            try:
                t30x_orchestrate(d, T, unexpected_rc_body, fake_pid)
                eu = None
            except Exception as ex:
                eu = ex
            ju = rec(eu, "12-unexpected-rc")
            out["orchestration_registration"] = {
                "same_primary": e is boom,
                "all_registered_joined": [c[0] for c in failing_calls] == ["wait", "pid"],
                "recorded": bool(j) and all(o["ok"] for o in j["joins"]),
                "healthy_pair": hres == "done" and hprobs == [] and
                [c[0] for c in healthy_calls] == ["wait", "wait"],
                "unexpected_rc_under_primary": eu is boom and bool(ju) and any(
                    o["step"] == "leftover-s-holder0-expected-rc" and not o["ok"]
                    for o in ju["joins"]) and any(
                    o["step"] == "leftover-s-holder0" and o.get("rc_ok") is False
                    for o in ju["joins"])}
            # (13) record write AND diagnostic both fail: the primary is still kept
            class BadErr(object):
                def write(self, *_a):
                    raise OSError("injected diagnostic failure (fixture-synthetic)")

                def flush(self):
                    pass

            def bad_write2(path, rec_):
                raise OSError("injected record write failure (fixture-synthetic)")
            real_err = sys.stderr
            g["write_join_record"] = bad_write2
            try:
                sys.stderr = BadErr()
                prim = W.Hold("injected primary, both sinks failing (fixture-synthetic)")
                try:
                    settle_joins(d, T, prim, [{"step": "s-c", "ok": False,
                                               "error_class": "X", "error": "x"}])
                    ep = None
                except Exception as ex:
                    ep = ex
                try:
                    settle_joins(d, T, None, [{"step": "s-d", "ok": False,
                                               "error_class": "X", "error": "x"}])
                    es = None
                except Exception as ex:
                    es = ex
            finally:
                sys.stderr = real_err
                g["write_join_record"] = real["write_join_record"]
            steps_p = [o["step"] for o in (getattr(ep, "join_outcomes", None) or [])
                       if not o["ok"]]
            out["record_and_diagnostic_failure"] = {
                "primary_kept": ep is prim and getattr(ep, "join_record", "x") is None and
                getattr(ep, "join_diagnostic", None) == "UNWRITTEN" and
                steps_p == ["s-c", "joins-record", "joins-diagnostic"],
                "secondary_uncertainty": isinstance(es, RealUncertainty) and
                "joins-diagnostic" in str(es) and "diagnostic UNWRITTEN" in str(es)}
        finally:
            W.procargs = real_pa
            g.update(real)
    _res, left_out, left_probs = t30x_orchestrate(d, T, body)
    out["no_disposal_during_failures"] = undisposed() == []
    want = set(T30X_SUBCASES) | {"no_disposal_during_failures"}
    ok = set(out) == want and all(
        v is True if isinstance(v, bool) else all(x is True for x in v.values())
        for v in out.values())
    labels = ["root"]
    return finish(labels, d, T, ["PASS"], "PASS" if ok else "FAIL",
                  {"fixtures": "ok" if left_probs == [] else "rc-problems-%r" % left_probs},
                  runroot, notes={"subcases": out, "records": records,
                                  "leftovers": [(o["step"], o.get("expected_rc"), o.get("value"))
                                                for o in left_out]})


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
    "T20g": lambda d, s, r: t20(d, s, r, "g"),
    "T21a": lambda d, s, r: t21(d, s, r, "a"), "T21b": lambda d, s, r: t21(d, s, r, "b"),
    "T21c": lambda d, s, r: t21(d, s, r, "c"), "T21d": lambda d, s, r: t21(d, s, r, "d"),
    "T21e": t21e,
    "T22a": t22a, "T22b": t22b, "T22c": t22c, "T22d": t22d,
    "T23a": lambda d, s, r: t23(d, s, r, "a"), "T23b": lambda d, s, r: t23(d, s, r, "b"),
    "T23c": lambda d, s, r: t23(d, s, r, "c"), "T23d": lambda d, s, r: t23(d, s, r, "d"),
    "T23e": lambda d, s, r: t23(d, s, r, "e"),
    "T24": t24, "T26a": t26a, "T26b": t26b, "T26c": t26c, "T27": t27,
    "T30a": t30a, "T30b": t30b, "T30c": t30c, "T30d": t30d, "T30e": t30e, "T30f": t30f,
    "T30g": t30g, "T30i": t30i, "T30j": t30j, "T30k": t30k, "T30l": t30l, "T30m": t30m,
    "T30n": t30n, "T30o": t30o, "T30p": t30p,
    "T31a": lambda d, s, r: t31(d, s, r, "a"), "T31b": lambda d, s, r: t31(d, s, r, "b"),
    "T31c": lambda d, s, r: t31(d, s, r, "c"), "T31d": lambda d, s, r: t31(d, s, r, "d"),
    "T31e": lambda d, s, r: t31(d, s, r, "e"), "T31f": lambda d, s, r: t31(d, s, r, "f"),
    "T31g": lambda d, s, r: t31(d, s, r, "g"),
    "T32": t32, "T34": t34, "T35": t35,
    "T36a": lambda d, s, r: t36(d, s, r, "a"), "T36b": lambda d, s, r: t36(d, s, r, "b"),
    "T36c": lambda d, s, r: t36(d, s, r, "c"), "T36d": lambda d, s, r: t36(d, s, r, "d"),
    "T37": t37,
    "T30q": t30q, "T30r": t30r, "T30s": t30s, "T30t": t30t, "T38": t38,
    "T31h": lambda d, s, r: t31(d, s, r, "h"), "T30u": t30u, "T30v": t30v,
    "T30w": t30w, "T30x": t30x,
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
        elif cmd == "client-gate":
            res = client_gate(a["file"], a["actual"], a["case"])
            W.jdump({"case": a["case"], "gate": res})
            return 0 if res == "ok" else 3
        elif cmd == "precheck":
            ok = precheck(a["dir"], a["test"], a["expected"].split(","), a["observed"],
                          json.loads(a["partial"]))
            return 0 if ok else 3
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
