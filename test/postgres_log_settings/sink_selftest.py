#!/usr/bin/env python3
"""5b sink test: self-test fixtures and synthetic self-tests.

Plan r2 9, r3 7, r4 2.6/3.5, r5 2.3/3.4, r6 2, R6-1 T18d; repaired per
claude-5b-harness-repair-plan.md (35a4926f), its amendment (25092856) and A1/A2.

Run only by sink-test.sh in `selftest` mode, with the locked-nixpkgs python3 (-I).

Registry (repair H3): every fixture gets an INTENT record before it is created and an
IDENTITY record after (path: dev/ino/type/mode; process: pid, birth_us, ppid at start,
uid). A test's verdict is computed here, not by the caller: the observed refusal class
must equal the test's fixed expected class, the teardown proof must be complete, and an
independent reconciliation must find no leftover that is not explicitly authorized for
retention. Anything else is REAL-UNCERTAINTY, and the suite stops.

Fixture processes are owned children with retained Popen handles, or shell jobs whose
identity is recorded; they are stopped only by identity (SIGTERM, bounded wait) and the
T19 subjects end by themselves (amendment R1). Labels: `fixture-synthetic` marks
classifier inputs built here; `kernel-event` / `fixture-handshake` mark measured facts.
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
FORK_CLASS = "fork in window by role fixture-writer without source-gated attribution"


class RealUncertainty(Exception):
    """An actual (not expected) identity, observation or teardown uncertainty."""


# ---------------------------------------------------------------- registry
def reg_path(d):
    return d + "/fixtures.json"


def registry(d):
    p = reg_path(d)
    return W.jload(p) if os.path.exists(p) else {"fixtures": [], "retain": {}}


def save(d, r):
    W.jdump(r, reg_path(d))


def intent(d, test, label, kind):
    r = registry(d)
    if any(f["test"] == test and f["label"] == label for f in r["fixtures"]):
        raise RealUncertainty("duplicate fixture label %s/%s" % (test, label))
    r["fixtures"].append({"test": test, "label": label, "kind": kind, "intent_t": W.now()})
    save(d, r)


def set_identity(d, test, label, ident):
    r = registry(d)
    for f in r["fixtures"]:
        if f["test"] == test and f["label"] == label:
            f["identity"] = ident
            save(d, r)
            return
    raise RealUncertainty("identity without intent: %s/%s" % (test, label))


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


def register_path(d, test, label, path, kind="dir"):
    intent(d, test, label, kind)
    if kind == "dir":
        os.mkdir(path, 0o700)
    elif kind == "file":
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    set_identity(d, test, label, path_identity(path))
    return path


def retain(d, test, labels):
    """Explicit per-test retention authorization (amendment, H3)."""
    r = registry(d)
    r["retain"][test] = sorted(set(r["retain"].get(test, [])) | set(labels))
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


# ---------------------------------------------------------------- verdicts and reconciliation
def reconcile(d, test_id, runroot, retained_manifests=()):
    """Independent leftover scan (repair H3). Returns a list of problems."""
    r = registry(d)
    problems = []
    auth = set(r["retain"].get(test_id, []))
    registered_paths = {}
    for f in r["fixtures"]:
        ident = f.get("identity")
        if ident and "path" in ident:
            registered_paths[ident["path"]] = ident
    for f in r["fixtures"]:
        if f["test"] != test_id:
            continue
        ident = f.get("identity")
        if ident is None:
            problems.append("intent without identity: %s" % f["label"])
            continue
        if "path" in ident:
            if os.path.lexists(ident["path"]):
                cur = W.lstat_rec(ident["path"])
                if f["label"] not in auth:
                    problems.append("leftover not authorized: %s" % ident["path"])
                elif (cur["dev"], cur["ino"]) != (ident["dev"], ident["ino"]):
                    problems.append("retained identity changed: %s" % ident["path"])
        elif "birth_us" in ident:
            if not identity_gone(ident):
                problems.append("fixture process alive: %s" % f["label"])
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
    for mp in retained_manifests:
        try:
            m = W.load_manifest(mp)
            W.inventory(m)
            for top in (m["root"], m["runtime_canonical"]):
                if os.path.lexists(top) and W.open_handles_under(top):
                    problems.append("open handles under retained %s" % top)
        except (W.Fail, W.Hold, W.Refuse, OSError, ValueError) as e:
            problems.append("retained instance not clean: %s" % str(e)[:120])
    return problems


def verdict(d, test_id, expected, observed, teardown, runroot, retained_manifests=(),
            notes=None):
    """`expected`: the test's fixed class list; `observed`: the parsed actual class;
    `teardown`: each value "ok" or "not-applicable:<reason>"."""
    problems = reconcile(d, test_id, runroot, retained_manifests)
    bad_teardown = sorted(k for k, v in (teardown or {}).items()
                          if not (v == "ok" or str(v).startswith("not-applicable:")))
    if not teardown:
        bad_teardown = ["missing"]
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


def summary(d, head, ids):
    missing, bad, recs = [], [], {}
    for tid in ids:
        p = "%s/%s.json" % (d, tid)
        if not os.path.exists(p):
            missing.append(tid)
            continue
        r = W.jload(p)
        recs[tid] = r["verdict"]
        if r["verdict"] not in ("PASS", "EXPECTED-REFUSAL") or r.get("problems") or \
                r.get("bad_teardown"):
            bad.append(tid)
    out = {"head": head, "pass": not missing and not bad, "missing": missing, "bad": bad,
           "verdicts": recs}
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


def mkroot(d, scratch, test, label):
    return register_path(d, test, label, scratch + "/" + test.lower() + "-" + label, "dir")


def rmtree(path):
    rc, _, err = W.run(["/bin/rm", "-rf", "--", path], env=W.TOOL_ENV)
    if rc != 0 or os.path.lexists(path):
        raise RealUncertainty("could not remove fixture %s" % path)


def bare_watch(root, port=25000):
    return W.Watch(fake_manifest(root, port), root + "/watch-state.json")


class FakeEv(object):
    def __init__(self, ident, fflags, data=0):
        self.ident, self.fflags, self.data = ident, fflags, data


# ---------------------------------------------------------------- healthy synthetic facts
def healthy(t0, t_pre, t_stop, t_post, sockets=None):
    """A graceful epoch as classifier inputs (fixture-synthetic): window singletons with
    (pid, birth) parent links, graceful exits in source order, R6-1-consistent sockets, a
    lockout record and a consistent H record. classify_epoch must call it complete."""
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


# ---------------------------------------------------------------- T16 capability
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
    gpid = int(mid.stdout.readline().decode().strip())
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
        os.waitid(os.P_PID, si.pid, os.WEXITED | os.WNOWAIT)
        notes["waitid_wnowait"] = "ok"
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
        rmtree(root)
        return verdict(d, T, ["REFUSE-SIGNAL"], "INCONCLUSIVE-NO-SAME-SECOND-PAIR",
                       {"fixtures": "ok"}, runroot)
    d2, i1, i2, l1, l2 = found
    notes = {"lstart_equal": True, "us_distinct": i1["birth_us"] != i2["birth_us"]}
    if not notes["us_distinct"]:
        d2.terminate()
        reap(d2, D_REAP)
        rmtree(root)
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
    rmtree(root)
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
    ypid = int(x.stdout.readline().decode().strip())
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
    rmtree(root)
    notes = {"admitted_via_exited_parent": admitted, "signal_refused": refused, "y_alive": alive,
             "stale_admitted": stale_admit, "y_ended_by_itself": gone}
    obs = "REFUSE-ADMISSION" if (not admitted and refused and alive and not stale_admit) else "FAIL"
    td = {"y": "ok" if gone else "y-still-alive"}
    return verdict(d, T, ["REFUSE-ADMISSION"], obs, td, runroot, notes=notes)


# ---------------------------------------------------------------- T10 / T11 / T12
def t10(d, scratch, runroot):
    T = "T10"
    root = mkroot(d, scratch, T, "root")
    sub = register_path(d, T, "locked", root + "/locked", "dir")
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
    rmtree(root)
    return verdict(d, T, ["FAIL-CLEANUP"], obs, {"fixtures": "ok"}, runroot)


def t11(d, scratch, runroot):
    T = "T11"
    root = mkroot(d, scratch, T, "root")
    sentinel = mkroot(d, scratch, T, "sentinel")
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
    W.cleanup(m, root + "/no-claim.json")
    after = (W.lstat_rec(sentinel)["ino"], sorted(os.listdir(sentinel)))
    rmtree(sentinel)
    obs = inv if before == after and not os.path.lexists(root) else "FAIL"
    return verdict(d, T, ["FAIL-SYMLINK"], obs, {"fixtures": "ok"}, runroot,
                   notes={"sentinel_intact": before == after})


def t12(d, scratch, runroot):
    T = "T12"
    root = mkroot(d, scratch, T, "root")
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
    rmtree(root)
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
    root = mkroot(d, scratch, T, "root")
    kq = select.kqueue()
    cases = {"d1": ("no-source-traced-drain", signal.SIGTERM, False, False),
             "d2": ("source-traced-graceful-exit0", signal.SIGTERM, True, True),
             "d3": ("no-source-traced-drain", signal.SIGKILL, False, False),
             "d4": ("no-source-traced-drain", signal.SIGTERM, False, False)}
    notes, ok = {}, True
    for name, (binding, sig, want_eligible, want_b) in sorted(cases.items()):
        path = root + "/" + name + ".out"
        p = start_fixture(d, T, name, PRODUCER, path, name, stdout=subprocess.PIPE)
        p.stdout.readline()
        kq_register(kq, p.pid)
        os.kill(p.pid, sig)
        st = kq_exit(kq, p.pid)
        reap(p, D_REAP)
        content = open(path).read()
        eligible = W.producer_exit_eligible(binding, st)
        notes[name] = {"status": st, "eligible": eligible, "has_A": "A" in content,
                       "has_B": "B" in content, "proof": "fixture-synthetic"}
        ok &= eligible == want_eligible and ("A" in content) and (("B" in content) == want_b)
    rmtree(root)
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
    lines = [f.stdout.readline().decode().strip() for _ in range(3)]
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
    f.stdout.readline()
    reap(f, D_REAP)
    w.drain(0.3)
    with open(cap, "rb") as fh:
        final = fh.read()
    if variant == "b":
        want_len = old_len + N
        tail_ok = final[old_len:] == b"Y" * N
    else:
        want_len = old_len + N
        tail_ok = True
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
    rmtree(root)
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
    root = mkroot(d, scratch, T, "root")
    intent(d, T, "sockdir", "dir")
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
    srv.stdout.readline()
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
    rmtree(root)
    rmtree(sdir)
    notes = {"eacces_after_lock": eacces, "complete": res["complete"], "reasons": res["reasons"],
             "socket_post": "present" if W.socket_rec(sock)["present"] else "unlinked",
             "proof": "fixture-synthetic"}
    if variant == "d":
        ok = res["complete"] and eacces == "errno-13" and notes["socket_post"] == "unlinked"
        return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                       notes=notes)
    ok = (not res["complete"]) and (eacces == "errno-13" or variant.startswith("d-"))
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
                   runroot, notes=notes)


# ---------------------------------------------------------------- T19 (R1, A1, A2)
TERM_RESISTANT = """
import signal, time, sys
for s in sys.argv[1].split(","):
    if s: signal.signal(getattr(signal, s), signal.SIG_IGN)
print("ready", flush=True)
time.sleep(float(sys.argv[2]))
"""
STAGES = {"launcher": D_SUBJECT, "pc": D_SUBJECT, "dt": D_SUBJECT, "kill": D_SUBJECT,
          "pgctl": 5.0, "pgctl_t": 2, "overall": 5 * D_SUBJECT}  # < L_FIXTURE


def watch_with(d, T, root, fixtures):
    """A Watch whose entries are registered owned fixtures: [(label, role, ignore, pgdata)]."""
    w = bare_watch(root)
    procs = {}
    for label, role, ignore, cwd in fixtures:
        p = start_fixture(d, T, label, TERM_RESISTANT, ignore, L_FIXTURE, cwd=cwd,
                          stdout=subprocess.PIPE)
        if p.stdout.readline().strip() != b"ready":  # handlers installed before any stop
            raise RealUncertainty("fixture %s/%s not ready" % (T, label))
        cur = W.bsdinfo(p.pid)
        w.register(p.pid)
        w.entries[p.pid] = {"pid": p.pid, "birth_us": cur["birth_us"], "lineage": True,
                            "role": role, "exit": None, "parent": None, "admitted": W.now(),
                            "exe": PY, "args": label}
        if role == "launcher":
            w.launcher = p
        procs[label] = p
    return w, procs


def outer_reap(procs):
    """Separate outer teardown: no signals; reap every owned fixture by its handle."""
    rcs = {}
    for label, p in procs.items():
        rcs[label] = reap(p, D_REAP)
    return rcs


def t19a(d, scratch, runroot):
    T = "T19a"
    root = mkroot(d, scratch, T, "root")
    os.mkdir(root + "/evidence", 0o700)
    script = root + "/launcher.sh"
    with open(script, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(script, 0o700)
    m = fake_manifest(root)
    m["launch_env"] = {"PATH": "/usr/bin:/bin"}
    state_path = root + "/state.json"
    rc = W.supervise(m, root + "/ctl", state_path, script, "E1", seam_exit_before_register=True,
                     post_stop_s=5)
    st = W.jload(state_path)
    kinds = [v["kind"] for v in st["violations"]]
    li = st.get("launcher_identity") or {}
    reaped = (st.get("launcher_reaped") or {}).get("returncode")
    rmtree(root)
    ok = rc == W.EXIT_HOLD and "launcher-unregistered" in kinds and li.get("identity") == "unknown" \
        and li.get("birth_us") is None and reaped == 0
    return verdict(d, T, ["HOLD-LAUNCHER-UNREGISTERED"], "HOLD-LAUNCHER-UNREGISTERED" if ok else
                   "FAIL", {"launcher_reap": "ok" if reaped == 0 else "not-reaped"}, runroot,
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
    rmtree(root)
    ok = res["ok"] is False and [r["role"] for r in res["remaining"]] == ["launcher"] and frozen \
        and not kills
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": "ok" if rcs["launcher"] == 0 else "rc-%s" % rcs["launcher"]},
                   runroot, notes={"result": res, "outer_rcs": rcs})


def t19c(d, scratch, runroot):
    T = "T19c"
    root = mkroot(d, scratch, T, "root")
    pgd = root + "/.devenv/state/postgres"
    os.makedirs(pgd, 0o700)
    w, procs = watch_with(d, T, root, [("launcher", "launcher", "", None),
                                      ("pm", "postmaster-final", "SIGTERM,SIGINT", pgd)])
    with open(pgd + "/postmaster.pid", "w") as f:
        f.write("%d\n%s\n" % (procs["pm"].pid, pgd))
    m = fake_manifest(root)
    res = W.stop_tree(w, m, stages=STAGES)
    rcs = outer_reap(procs)
    rmtree(root)
    pgctl = [s for s in res["stages"] if s[0] == "pg_ctl"]
    ok = res["ok"] is False and pgctl and pgctl[0][1] != 0 and \
        any(r["role"] == "postmaster-final" for r in res["remaining"]) and \
        not [s for s in w.harness_signals if s["signal"] == int(signal.SIGKILL)]
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": "ok" if rcs["pm"] == 0 else "rc-%s" % rcs["pm"]}, runroot,
                   notes={"result": res, "outer_rcs": rcs})


def t19d(d, scratch, runroot):
    T = "T19d"
    root = mkroot(d, scratch, T, "root")
    w, procs = watch_with(d, T, root, [("launcher", "launcher", "", None),
                                      ("pc", "process-compose", "SIGTERM", None),
                                      ("dt", "devenv-tasks", "SIGTERM", None),
                                      ("aux", "pg-aux", "SIGTERM", None)])
    res = W.stop_tree(w, fake_manifest(root), stages=STAGES)
    rcs = outer_reap(procs)
    rmtree(root)
    killed = sorted(s["role"] for s in w.harness_signals if s["signal"] == int(signal.SIGKILL))
    ok = res["ok"] is False and [r["role"] for r in res["remaining"]] == ["pg-aux"] and \
        killed == ["devenv-tasks", "process-compose"] and rcs["pc"] == -9 and rcs["dt"] == -9 \
        and rcs["aux"] == 0
    return verdict(d, T, ["HOLD-STOP"], "HOLD-STOP" if ok else "FAIL",
                   {"outer_reap": "ok" if rcs["aux"] == 0 else "rc-%s" % rcs["aux"]}, runroot,
                   notes={"result": res, "outer_rcs": rcs, "killed": killed})


# ---------------------------------------------------------------- T20 (fabricated verdict inputs)
def t20(d, scratch, runroot, variant):
    """Meta-controls on FABRICATED records in a private directory (amendment R1): they
    assert the verdict functions' outputs and never touch the suite's own records."""
    T = "T20" + variant
    priv = mkroot(d, scratch, T, "private")
    pd = priv + "/selftest"
    os.mkdir(pd, 0o700)
    fake_runroot = priv + "/run"
    os.mkdir(fake_runroot, 0o700)
    if variant == "a":
        rec = verdict(pd, "X", ["FAIL-CLEANUP"], "FAIL-CLEANUP", {"cleanup": "failed"}, fake_runroot)
        ok = rec["verdict"] == "REAL-UNCERTAINTY"
    elif variant == "b":
        leftover = register_path(pd, "X", "fx", fake_runroot + "/fx", "dir")
        with open(leftover + "/stray", "w") as f:
            f.write("x")
        os.mkdir(fake_runroot + "/unregistered", 0o700)
        rec = verdict(pd, "X", ["REFUSE-X"], "REFUSE-X", {"cleanup": "ok"}, fake_runroot)
        ok = rec["verdict"] == "REAL-UNCERTAINTY"
    elif variant == "c":
        p = start_fixture(pd, "X", "proc", "import time; time.sleep(3)")
        r = registry(pd)
        for f in r["fixtures"]:
            if f["label"] == "proc":
                f["identity"]["uid"] += 1  # same birth, mismatching owner: HOLD, not "gone"
        save(pd, r)
        try:
            kill_fixture(pd, "X", "proc")
            ok = False
        except RealUncertainty:
            ok = True
        reap(p, D_REAP)
    else:
        verdict(pd, "X1", ["PASS"], "PASS", {"cleanup": "ok"}, fake_runroot)
        verdict(pd, "X2", ["PASS"], "PASS", {"cleanup": "failed"}, fake_runroot)
        s = summary(pd, "head", ["X1", "X2"])
        ok = s["pass"] is False and "X2" in s["bad"]
    rmtree(priv)
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot)


# ---------------------------------------------------------------- T21 (snapshot integrity, H5)
def t21(d, scratch, runroot, variant):
    T = "T21" + variant
    root = mkroot(d, scratch, T, "root")
    src = root + "/src.log"
    with open(src, "wb") as f:
        f.write(b"line-one\n" * 100 + b"needle-in-the-tail\n")
    sd = root + "/snap"
    os.mkdir(sd, 0o700)
    ok, obs = False, "FAIL"
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
        if variant == "c":
            with open(sd + "/copy", "r+b") as f:
                f.seek(0)
                f.write(b"X")
        else:
            with open(sd + "/copy", "r+b") as f:
                f.truncate(meta["len"] - 10)
        try:
            W.count_markers(sd, {"n": "needle-in-the-tail"})
            obs = "COUNTED"
        except W.Hold:
            obs = "HOLD"
    rmtree(root)
    want = "PASS" if variant == "a" else "HOLD"
    return verdict(d, T, [want], obs, {"fixtures": "ok"}, runroot)


def t21e(d, scratch, runroot):
    """grep -F -c -a line-semantics equivalence on verified bytes (review 29bdd2d6)."""
    T = "T21e"
    root = mkroot(d, scratch, T, "root")
    cases = {"multi": b"mk mk mk\nmk\nnone\n", "unterminated": b"none\nmk-last",
             "empty": b"", "binary": b"\xff\x00mk\x01\n\x00\x00\nmk\xfe", "zero": b"a\nb\n"}
    res, ok = {}, True
    for name, data in sorted(cases.items()):
        p = root + "/" + name
        with open(p, "wb") as f:
            f.write(data)
        rc, out, _ = W.run(["/usr/bin/grep", "-F", "-c", "-a", "--", "mk", p], env=W.TOOL_ENV)
        g = int(out.strip()) if rc in (0, 1) else None
        mine = W.grep_count(data, b"mk")
        res[name] = {"grep": g, "in_memory": mine, "grep_rc": rc}
        ok &= g is not None and g == mine
    rmtree(root)
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes=res)


# ---------------------------------------------------------------- T22 (H1, D-1)
def t22a(d, scratch, runroot):
    T = "T22a"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
    c = start_fixture(d, T, "child", "pass")
    reap(c, D_REAP)
    w.entries[c.pid] = {"pid": c.pid, "birth_us": 1, "lineage": True, "role": "process-compose",
                        "exit": None, "parent": None, "exe": PC_FAKE, "args": "old", "execs": 0,
                        "admitted": W.now()}
    w.handle(FakeEv(c.pid, W.NOTE_EXEC | W.NOTE_EXIT | W.NOTE_EXITSTATUS, 0))
    dead = next(x for x in w.dead if x["pid"] == c.pid)
    kinds = [v["kind"] for v in w.violations]
    state, snaps, lock = healthy_now()
    state["violations"] = w.violations
    state["h"] = dict(w.h_record(), closure_verified=True)
    res = classify(state, snaps, lock)
    rmtree(root)
    ok = "exec-image-unobserved-before-exit" in kinds and dead["exe"] is None and \
        dead["role"] == "unknown-image" and dead["prior_images"][0]["exe"] == PC_FAKE and \
        not res["complete"]
    return verdict(d, T, ["INCOMPLETE"], "INCOMPLETE" if ok else "FAIL", {"fixtures": "ok"},
                   runroot, notes={"violations": kinds, "reasons": res["reasons"]})


PC_FAKE = "/nix/store/old-image"


def t22b(d, scratch, runroot):
    T = "T22b"
    root = mkroot(d, scratch, T, "root")
    w = bare_watch(root)
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
    h = w.h_record()
    reap(c, D_REAP)
    rmtree(root)
    ok = held and "admission-image-unreadable-live" in kinds and h["verdict"] is False
    return verdict(d, T, ["HOLD"], "HOLD" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes={"violations": kinds, "h": h})


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
    # an allowed shell that execs something other than postgres
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
    rmtree(root)
    positives = ("pgctl_ok", "check_ok", "boot_ok", "single_ok")
    ok = all(cases[k] for k in positives) and not any(v for k, v in cases.items()
                                                      if k not in positives)
    return verdict(d, T, ["PASS"], "PASS" if ok else "FAIL", {"fixtures": "ok"}, runroot,
                   notes={"allowed": cases, "proof": "fixture-synthetic"})


# ---------------------------------------------------------------- T23 (H4)
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
    else:
        sn["SNAP-post"]["violations"] = [("capture-replaced", "/x")]
        res = classify(st, sn, lk)
        j = W.judge("A", [], {}, res["complete"])
        ok = not res["complete"] and j["pass"] is False
        want = "INCOMPLETE"
    return verdict(d, T, [want], want if ok else "FAIL",
                   {"fixtures": "not-applicable:synthetic records only"}, runroot,
                   notes={"reasons": res["reasons"], "proof": "fixture-synthetic"})


# ---------------------------------------------------------------- T24 (cross-snapshot, H7/D-8)
def t24(d, scratch, runroot):
    T = "T24"
    root = mkroot(d, scratch, T, "root")
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
    rmtree(root)
    ok = only_post["pass"] is True and all_snaps["pass"] is False
    return verdict(d, T, ["FAIL-CROSS-CHECK"], "FAIL-CROSS-CHECK" if ok else "FAIL",
                   {"fixtures": "ok"}, runroot,
                   notes={"post_only_pass": only_post["pass"], "all_pass": all_snaps["pass"]})


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
    "T19a": t19a, "T19b": t19b, "T19c": t19c, "T19d": t19d,
    "T20a": lambda d, s, r: t20(d, s, r, "a"), "T20b": lambda d, s, r: t20(d, s, r, "b"),
    "T20c": lambda d, s, r: t20(d, s, r, "c"), "T20d": lambda d, s, r: t20(d, s, r, "d"),
    "T21a": lambda d, s, r: t21(d, s, r, "a"), "T21b": lambda d, s, r: t21(d, s, r, "b"),
    "T21c": lambda d, s, r: t21(d, s, r, "c"), "T21d": lambda d, s, r: t21(d, s, r, "d"),
    "T21e": t21e,
    "T22a": t22a, "T22b": t22b, "T22c": t22c, "T22d": t22d,
    "T23a": lambda d, s, r: t23(d, s, r, "a"), "T23b": lambda d, s, r: t23(d, s, r, "b"),
    "T23c": lambda d, s, r: t23(d, s, r, "c"), "T23d": lambda d, s, r: t23(d, s, r, "d"),
    "T24": t24,
}


def main(argv):
    cmd, a = argv[0], W.parse_kv(argv[1:])
    try:
        if cmd == "intent":
            intent(a["dir"], a["test"], a["label"], a["kind"])
        elif cmd == "identity-path":
            set_identity(a["dir"], a["test"], a["label"], path_identity(a["path"]))
        elif cmd == "identity-proc":
            set_identity(a["dir"], a["test"], a["label"], proc_identity(a["pid"], a["ppid"]))
        elif cmd == "retain":
            retain(a["dir"], a["test"], a["labels"].split(","))
        elif cmd == "kill-fixture":
            W.jdump({"result": kill_fixture(a["dir"], a["test"], a["label"])})
        elif cmd == "wait-gone":
            ident = lookup(a["dir"], a["test"], a["label"])["identity"]
            ok = wait_gone(ident, float(a.get("deadline", D_REAP)))
            W.jdump({"gone": ok})
            return 0 if ok else 3
        elif cmd == "observed-class":
            W.jdump({"class": observed_class(open(a["file"]).read())})
        elif cmd == "verdict":
            rec = verdict(a["dir"], a["test"], a["expected"].split(","), a["observed"],
                          json.loads(a["teardown"]), a["runroot"],
                          [x for x in a.get("retained_manifests", "").split(",") if x],
                          json.loads(a.get("notes", "{}")))
            W.jdump(rec)
            return 0 if rec["verdict"] in ("PASS", "EXPECTED-REFUSAL") else (
                3 if rec["verdict"] == "REAL-UNCERTAINTY" else 4)
        elif cmd == "summary":
            out = summary(a["dir"], a["head"], a["ids"].split(","))
            W.jdump(out)
            return 0 if out["pass"] else 4
        elif cmd == "inject":
            W.jdump(inject(a["kind"], a["path"], a.get("pid")))
        elif cmd == "state-has-pid":
            st = W.jload(a["state"])
            pid = int(a["pid"])
            W.jdump({"admitted": any(e["pid"] == pid for e in st["live"] + st["dead"])})
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
            return 0 if rec["verdict"] in ("PASS", "EXPECTED-REFUSAL") else (
                3 if rec["verdict"] == "REAL-UNCERTAINTY" else 4)
        else:
            return 64
        return 0
    except (RealUncertainty, W.Hold) as h:
        sys.stderr.write("HOLD REAL-UNCERTAINTY %s\n" % h)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
