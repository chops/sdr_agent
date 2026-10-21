#!/usr/bin/env python3
"""5b sink test: self-test fixtures and synthetic self-tests (plan r2 9, r3 7, r4 2.6/3.5,
r5 2.3/3.4, r6 2, R6-1 T18d).

Run only by sink-test.sh in `selftest` mode, with the locked-nixpkgs python3 (-I).
Every fixture is registered in <dir>/fixtures.json BEFORE it is created. A test's
verdict is EXPECTED-REFUSAL/PASS only when its observed outcome equals the expected one
AND every object it retained is registered (r3 7.2). Anything else is real uncertainty.

Fixture programs (`fixture-*`) are long-running helpers the orchestrator starts in the
background and stops by their recorded identity. They never touch a path outside the
self-test scratch root they are given, and never connect to a database.
"""

import json
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # explicit: -I does not add the script directory on 3.11+
import sink_watch as W  # noqa: E402

PY = sys.executable


# ---------------------------------------------------------------- registry
def reg_path(d):
    return d + "/fixtures.json"


def registry(d):
    p = reg_path(d)
    return W.jload(p) if os.path.exists(p) else {"fixtures": []}


def register(d, test_id, kind, what):
    r = registry(d)
    r["fixtures"].append({"test": test_id, "kind": kind, "what": what, "t": W.now()})
    W.jdump(r, reg_path(d))


def verdict(d, test_id, expected, observed, ok, notes=None, retained=()):
    reg = [f["what"] for f in registry(d)["fixtures"] if f["test"] == test_id]
    unregistered = [x for x in retained if x not in reg]
    v = "EXPECTED-REFUSAL" if ok and expected.startswith(("REFUSE", "FAIL", "HOLD", "INCOMPLETE")) \
        else ("PASS" if ok else "FAIL")
    if unregistered:
        v = "REAL-UNCERTAINTY"
    rec = {"id": test_id, "expected": expected, "observed": observed, "verdict": v,
           "notes": notes or {}, "unregistered": unregistered}
    W.jdump(rec, "%s/%s.json" % (d, test_id))
    return rec


# ---------------------------------------------------------------- fixture programs
def fixture_tcp_decoy(addr, port, count_file):
    """T4a/T4b: listen on addr:port and count every accepted connection."""
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
    """T2: a live listener at a would-be pc.sock path."""
    s = socket.socket(socket.AF_UNIX)
    s.bind(path)
    s.listen(4)
    while True:
        c, _ = s.accept()
        c.close()


def fixture_cwd_holder(cwd):
    """T8: an unowned process holding a cwd handle under an instance root."""
    os.chdir(cwd)
    while True:
        time.sleep(1)


def fixture_sleeper(seconds):
    time.sleep(float(seconds))


def kill_fixture(pid, birth_us):
    """Stop a registered fixture by its recorded identity only (never a generic kill)."""
    cur = W.bsdinfo(int(pid))
    if cur is None:
        return "gone"
    if cur["birth_us"] != int(birth_us) or cur["uid"] != W.me():
        raise W.Hold("fixture identity changed: %s" % pid)
    os.kill(int(pid), signal.SIGTERM)
    return "sent"


# ---------------------------------------------------------------- helpers
def spawn(code, *args):
    return subprocess.Popen([PY, "-I", "-c", code] + list(args), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, close_fds=True)


def kq_register(kq, pid):
    ev = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD,
                       fflags=W.PROC_FFLAGS)
    kq.control([ev], 0, 0)


def kq_exit(kq, pid, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for ev in kq.control(None, 16, 0.5):
            if ev.ident == pid and ev.fflags & W.NOTE_EXIT:
                if not ev.fflags & W.NOTE_EXITSTATUS:
                    return {"kind": "no-exitstatus"}
                return W.decode_status(ev.data)
    raise W.Hold("no exit event for %d" % pid)


def fake_manifest(root):
    return {"root": root, "runtime": root + "/.no-runtime", "runtime_canonical": root + "/.no-runtime",
            "pgdata": root + "/.devenv/state/postgres", "pg_socket": root + "/.no-sock",
            "pc_socket": root + "/.no-pc", "native_socket": root + "/.no-native",
            "launch_env": {"USER": os.environ.get("USER", "")}, "root_lstat": W.lstat_rec(root),
            "inst": "selftest", "kind": "S", "port": 0}


def mkroot(scratch, name, d, test_id):
    path = scratch + "/" + name
    register(d, test_id, "dir", path)
    os.mkdir(path, 0o700)
    return path


# ---------------------------------------------------------------- T16 capability
def t16(d, scratch):
    notes, ok = {}, True
    notes["struct_size"] = __import__("ctypes").sizeof(W.ProcBsdInfo)
    me = W.bsdinfo(os.getpid())
    ok &= notes["struct_size"] == 136 and me["pid"] == os.getpid() and me["ppid"] == os.getppid() \
        and me["uid"] == os.getuid()
    kq = select.kqueue()
    # direct child: normal exit 3
    c = spawn("import sys,time; time.sleep(0.5); sys.exit(3)")
    register(d, "T16", "proc", c.pid)
    ok &= c.pid in W.child_pids(os.getpid())
    notes["pidpath_child"] = W.pidpath(c.pid)
    ok &= os.path.realpath(notes["pidpath_child"] or "") == os.path.realpath(PY)
    kq_register(kq, c.pid)
    st = kq_exit(kq, c.pid)
    c.wait()
    notes["child_exit3"] = st
    ok &= st == {"kind": "exited", "code": 3, "raw": st.get("raw")} and c.returncode == 3
    # direct child: SIGTERM and SIGKILL
    for sig in (signal.SIGTERM, signal.SIGKILL):
        c = spawn("import time; time.sleep(30)")
        register(d, "T16", "proc", c.pid)
        kq_register(kq, c.pid)
        time.sleep(0.2)
        os.kill(c.pid, sig)
        st = kq_exit(kq, c.pid)
        c.wait()
        notes["child_sig_%d" % sig] = st
        ok &= st.get("kind") == "signaled" and st.get("signal") == sig and c.returncode == -sig
    # non-child grandchild: SIGTERM decoded through the "allowed to signal" branch
    mid = spawn("import subprocess,sys,time;"
                "g=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(30)']);"
                "print(g.pid,flush=True); g.wait()")
    register(d, "T16", "proc", mid.pid)
    gpid = int(mid.stdout.readline().decode().strip())
    register(d, "T16", "proc", gpid)
    ok &= gpid not in W.child_pids(os.getpid())
    kq_register(kq, gpid)
    os.kill(gpid, signal.SIGTERM)
    st = kq_exit(kq, gpid)
    mid.wait()
    notes["grandchild_sigterm"] = st
    ok &= st.get("kind") == "signaled" and st.get("signal") == signal.SIGTERM
    # ESRCH on an already reaped pid: registration fails -> the harness HOLDs
    c = spawn("pass")
    register(d, "T16", "proc", c.pid)
    c.wait()
    try:
        kq_register(kq, c.pid)
        notes["esrch"] = "registered (unexpected)"
        ok = False
    except OSError as e:
        notes["esrch"] = "errno-%d" % e.errno
    # quiet parent: zero notifications
    q = spawn("import time; time.sleep(2)")
    register(d, "T16", "proc", q.pid)
    kq_register(kq, q.pid)
    forks = 0
    end = time.time() + 1.0
    while time.time() < end:
        for ev in kq.control(None, 16, 0.2):
            if ev.ident == q.pid and ev.fflags & W.NOTE_FORK:
                forks += 1
    notes["quiet_parent_fork_notes"] = forks
    ok &= forks == 0
    q.wait()
    # burst of 20 forks: notes <= forks; coverage possible-gap; no loss is asserted
    b = spawn("import os,time; time.sleep(0.5)\n"
              "for i in range(20):\n"
              "    p=os.fork()\n"
              "    if p==0: os._exit(0)\n"
              "    os.waitpid(p,0)\n"
              "time.sleep(0.5)")
    register(d, "T16", "proc", b.pid)
    kq_register(kq, b.pid)
    nfork, identified = 0, set()
    while b.poll() is None:
        for ev in kq.control(None, 64, 0.1):
            if ev.ident == b.pid and ev.fflags & W.NOTE_FORK:
                nfork += 1
                identified.update(W.child_pids(b.pid))
    notes["burst"] = {"notifications": nfork, "identified": len(identified),
                      "coverage": "possible-gap" if nfork else "no-notifications"}
    ok &= nfork <= 20 and len(identified) <= 20 and nfork >= 1
    # NOTE_EXEC: image change is observed and pidpath re-read
    e = spawn("import os,time; time.sleep(0.5); os.execv('/bin/sh',['/bin/sh','-c','exit 0'])")
    register(d, "T16", "proc", e.pid)
    kq_register(kq, e.pid)
    saw_exec = False
    while e.poll() is None:
        for ev in kq.control(None, 16, 0.1):
            if ev.ident == e.pid and ev.fflags & W.NOTE_EXEC:
                saw_exec = True
    notes["note_exec"] = saw_exec
    ok &= saw_exec
    return verdict(d, "T16", "PASS", notes, ok)


# ---------------------------------------------------------------- T9a / T9b
def bare_watch(scratch, role="process-compose"):
    m = fake_manifest(scratch)
    return W.Watch(m, scratch + "/watch-state.json")


def t9a(d, scratch):
    """Emulated PID-reuse record on two real same-second processes (r4 3.4)."""
    for _attempt in range(8):
        d1 = spawn("import time; time.sleep(30)")
        register(d, "T9a", "proc", d1.pid)
        i1 = W.bsdinfo(d1.pid)
        l1 = W.run(["/bin/ps", "-o", "lstart=", "-p", str(d1.pid)], env=W.TOOL_ENV)[1].strip()
        d1.terminate()
        d1.wait()
        d2 = spawn("import time; time.sleep(30)")
        register(d, "T9a", "proc", d2.pid)
        i2 = W.bsdinfo(d2.pid)
        l2 = W.run(["/bin/ps", "-o", "lstart=", "-p", str(d2.pid)], env=W.TOOL_ENV)[1].strip()
        if l1 == l2:
            break
        d2.terminate()
        d2.wait()
    else:
        return verdict(d, "T9a", "REFUSE", {"why": "no same-second pair"}, False)
    notes = {"lstart_equal": l1 == l2, "us_distinct": i1["birth_us"] != i2["birth_us"]}
    if not notes["us_distinct"]:
        d2.terminate()
        d2.wait()
        rec = verdict(d, "T9a", "REFUSE", notes, False)
        rec["verdict"] = "INCONCLUSIVE"
        W.jdump(rec, "%s/T9a.json" % d)
        return rec
    # the old predicate (pid, uid, comm, lstart second) would match D2 with D1's record
    old_match = (i1["uid"], i1["comm"], l1) == (i2["uid"], i2["comm"], l2)
    w = bare_watch(scratch)
    w.entries[d2.pid] = {"pid": d2.pid, "birth_us": i1["birth_us"], "lineage": True,
                         "role": "process-compose", "exit": None}
    refused = False
    try:
        w.signal_verified(d2.pid, signal.SIGTERM, "T9a")
    except W.Hold:
        refused = True
    alive = W.bsdinfo(d2.pid) is not None
    d2.terminate()
    d2.wait()
    notes.update({"old_predicate_matches": old_match, "new_rule_refused": refused,
                  "d2_not_signalled": alive})
    return verdict(d, "T9a", "REFUSE", notes, old_match and refused and alive)


def t9b(d, scratch):
    """Changed parent: X spawns Y and exits; admission through X and signalling Y refuse."""
    x = spawn("import subprocess,sys;"
              "y=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(30)']);"
              "print(y.pid,flush=True)")
    register(d, "T9b", "proc", x.pid)
    w = bare_watch(scratch)
    cur = W.bsdinfo(x.pid)
    w.register(x.pid)
    w.entries[x.pid] = {"pid": x.pid, "birth_us": cur["birth_us"], "lineage": True,
                        "role": "process-compose", "exit": None, "parent": None}
    ypid = int(x.stdout.readline().decode().strip())
    register(d, "T9b", "proc", ypid)
    x.wait()
    deadline = time.time() + 5
    while x.pid in w.entries and time.time() < deadline:
        w.drain(0.2)
    admitted = w.admit(ypid, x.pid, "T9b") is not None
    refused = False
    try:
        w.signal_verified(ypid, signal.SIGTERM, "T9b")
    except W.Hold:
        refused = True
    alive = W.bsdinfo(ypid) is not None
    # variant: a stale live-looking record of the exited X (its handle already fired)
    w.entries[x.pid] = {"pid": x.pid, "birth_us": cur["birth_us"], "lineage": True,
                        "role": "process-compose", "exit": None, "parent": None}
    stale_admit = w.admit(ypid, x.pid, "T9b-stale") is not None
    w.entries.pop(x.pid)
    os.kill(ypid, signal.SIGTERM)
    notes = {"admitted_via_exited_parent": admitted, "signal_refused": refused, "y_alive": alive,
             "stale_admitted": stale_admit}
    return verdict(d, "T9b", "REFUSE", notes, not admitted and refused and alive and not stale_admit)


# ---------------------------------------------------------------- T10 / T11 / T12
def t10(d, scratch):
    root = mkroot(scratch, "t10-root", d, "T10")
    sub = root + "/locked"
    register(d, "T10", "dir", sub)
    os.mkdir(sub, 0o700)
    with open(sub + "/f", "w") as f:
        f.write("x")
    os.chmod(sub, 0o500)
    m = fake_manifest(root)
    observed = None
    try:
        W.cleanup(m, root + "/no-claim.json")
        observed = "cleaned"
    except W.Fail as e:
        observed = str(e)[:80]
    os.chmod(sub, 0o700)
    W.run(["/bin/rm", "-rf", "--", root], env=W.TOOL_ENV)
    return verdict(d, "T10", "FAIL-CLEANUP", observed, observed.startswith("FAIL-CLEANUP"))


def t11(d, scratch):
    root = mkroot(scratch, "t11-root", d, "T11")
    sentinel = mkroot(scratch, "t11-sentinel", d, "T11")
    with open(sentinel + "/keep", "w") as f:
        f.write("keep")
    register(d, "T11", "symlink", root + "/escape")
    os.symlink(sentinel, root + "/escape")
    before = (W.lstat_rec(sentinel)["ino"], sorted(os.listdir(sentinel)))
    m = fake_manifest(root)
    try:
        W.inventory(m)
        inv = "no-failure"
    except W.Fail as e:
        inv = str(e)[:40]
    W.cleanup(m, root + "/no-claim.json")
    after = (W.lstat_rec(sentinel)["ino"], sorted(os.listdir(sentinel)))
    W.run(["/bin/rm", "-rf", "--", sentinel], env=W.TOOL_ENV)
    ok = inv.startswith("FAIL-SYMLINK") and before == after and not os.path.lexists(root)
    return verdict(d, "T11", "FAIL-SYMLINK", {"inventory": inv, "sentinel_intact": before == after}, ok)


def t12(d, scratch):
    root = mkroot(scratch, "t12-root", d, "T12")
    sink = root + "/.devenv/state/process-compose/process-compose.log"
    register(d, "T12", "file", sink)
    os.makedirs(os.path.dirname(sink), 0o700)
    with open(sink, "w") as f:
        f.write("x")
    os.chmod(sink, 0)
    m = fake_manifest(root)
    try:
        W.inventory(m)
        obs = "no-failure"
    except W.Fail as e:
        obs = str(e)[:40]
    os.chmod(sink, 0o600)
    W.run(["/bin/rm", "-rf", "--", root], env=W.TOOL_ENV)
    return verdict(d, "T12", "FAIL-UNREADABLE", obs, obs.startswith("FAIL-UNREADABLE"))


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
time.sleep(30)
"""


def t15d(d, scratch):
    root = mkroot(scratch, "t15d", d, "T15d")
    kq = select.kqueue()
    cases = {"d1": ("no-source-traced-drain", signal.SIGTERM, False, False),
             "d2": ("source-traced-graceful-exit0", signal.SIGTERM, True, True),
             "d3": ("no-source-traced-drain", signal.SIGKILL, False, False),
             "d4": ("no-source-traced-drain", signal.SIGTERM, False, False)}
    notes, ok = {}, True
    for name, (binding, sig, want_eligible, want_b) in sorted(cases.items()):
        path = root + "/" + name + ".out"
        p = subprocess.Popen([PY, "-I", "-c", PRODUCER, path, name], stdout=subprocess.PIPE,
                             close_fds=True)
        register(d, "T15d", "proc", p.pid)
        p.stdout.readline()
        kq_register(kq, p.pid)
        os.kill(p.pid, sig)
        st = kq_exit(kq, p.pid)
        p.wait()
        content = open(path).read()
        eligible = W.producer_exit_eligible(binding, st)
        notes[name] = {"status": st, "eligible": eligible, "has_A": "A" in content,
                       "has_B": "B" in content}
        ok &= eligible == want_eligible and ("A" in content) and (("B" in content) == want_b)
    W.run(["/bin/rm", "-rf", "--", root], env=W.TOOL_ENV)
    return verdict(d, "T15d", "INCOMPLETE", notes, ok)


# ---------------------------------------------------------------- synthetic epoch facts
def synthetic_singletons(t_before, t_stop):
    """Graceful singleton facts so that classify_epoch judges only the injected defect."""
    def ent(pid, role, parent, code=0, sig=None, dt=0.0):
        st = {"kind": "signaled", "signal": sig, "t": t_stop + 1 + dt} if sig else \
            {"kind": "exited", "code": code, "t": t_stop + 1 + dt}
        return {"pid": pid, "role": role, "parent": parent, "admitted": t_before, "exit": st,
                "birth_us": pid}
    return [ent(1001, "launcher", None, dt=3), ent(1002, "process-compose", 1001, dt=2),
            ent(1003, "wrapper", 1004, sig=signal.SIGTERM, dt=0.1),
            ent(1005, "postmaster-final", 1003, dt=0.2), ent(1006, "pg-logger", 1005, dt=0.3),
            ent(1004, "devenv-tasks", 1002, sig=signal.SIGINT, dt=1)]


def classify_synthetic(dead, events, snaps, lock, barrier_ok, history_clean=True):
    t_stop = snaps["SNAP-pre"]["t"] + 0.5
    state = {"live": [], "dead": dead, "events": events, "violations": [], "gaps": [],
             "marks": {"stop_begin": t_stop}, "harness_signals": [], "launcher_pid": 1001,
             "api_client_history_clean": history_clean}
    return W.classify_epoch(state, snaps, lock, barrier_ok)


def snap_now(name, files, sockets):
    return {"name": name, "t": W.now(), "files": files, "sockets": sockets, "violations": []}


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


# ---------------------------------------------------------------- T17a / T17b
FORKER = """
import os, sys, time
cap = sys.argv[1]; mode = sys.argv[2]
sys.stdin.readline()
c1 = os.fork()
if c1 == 0:
    time.sleep(3); os._exit(0)
c2 = os.fork()
if c2 == 0:
    if mode == "a":
        with open(cap, "r+") as f:
            f.truncate(0); f.write("Z" * 4096)
    else:
        with open(cap, "r+") as f:
            f.seek(0, 2); n = f.tell(); f.truncate(n - 8); f.write("YYYYYYYY")
    os._exit(0)
os.waitpid(c2, 0); os.waitpid(c1, 0)
"""


def t17(d, scratch, variant):
    tid = "T17" + variant
    root = mkroot(scratch, "t17" + variant, d, tid)
    cap = root + "/capture.log"
    register(d, tid, "file", cap)
    with open(cap, "w") as f:
        f.write("original-bytes\n" * 8)
    w = bare_watch(root)
    f = subprocess.Popen([PY, "-I", "-c", FORKER, cap, variant], stdin=subprocess.PIPE,
                         close_fds=True)
    register(d, tid, "proc", f.pid)
    cur = W.bsdinfo(f.pid)
    w.register(f.pid)
    w.entries[f.pid] = {"pid": f.pid, "birth_us": cur["birth_us"], "lineage": True,
                        "role": "fixture-writer", "exit": None, "parent": None,
                        "admitted": W.now()}
    snap0 = snap_now("SNAP-0", {cap: capture_meta(cap)}, {})
    if variant == "b":
        with open(cap, "a") as fh:
            fh.write("appended-after-snap0\n")
    snappre = snap_now("SNAP-pre", {cap: capture_meta(cap)}, {})
    f.stdin.write(b"go\n")
    f.stdin.flush()
    deadline = time.time() + 10
    while f.poll() is None and time.time() < deadline:
        w.drain(0.1)
    w.drain(0.2)
    v, post_meta = prefix_violations(snappre, cap)
    snappost = snap_now("SNAP-post", {cap: post_meta}, {})
    snappost["violations"] = v
    t = snap0["t"]
    events = [dict(ev) for ev in w.events if ev["ev"] == "fork-note"]
    for ev in events:
        ev["t"] = max(ev["t"], t + 0.01)
    dead = synthetic_singletons(t - 1, snappre["t"] + 0.5)
    fw = dict(w.entries.get(f.pid) or next(x for x in w.dead if x["pid"] == f.pid))
    fw["exit"] = {"kind": "exited", "code": 0, "t": snappre["t"] + 0.6}
    dead.append(fw)
    lock = None
    complete, reasons = classify_synthetic(dead, events, {"SNAP-0": snap0, "SNAP-pre": snappre,
                                                          "SNAP-post": snappost}, lock, True)
    notes = {"fork_notes": len(events), "identified_children": sorted(
        e["pid"] for e in w.dead + list(w.entries.values()) if e.get("parent") == f.pid),
        "coverage": "possible-gap" if events else "no-notifications",
        "prefix_violation": bool(v), "complete": complete, "reasons": reasons}
    W.run(["/bin/rm", "-rf", "--", root], env=W.TOOL_ENV)
    ok = (not complete) and notes["coverage"] == "possible-gap" and (
        bool(v) if variant == "a" else any("without source-gated" in r for r in reasons))
    return verdict(d, tid, "INCOMPLETE", notes, ok)


# ---------------------------------------------------------------- T18 accept-and-spawn server
SERVER = """
import os, signal, socket, sys, threading, time
path, cap, accept_delay, handler_delay = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
mode = sys.argv[5]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8)
def bye(*_):
    try: os.unlink(path)
    finally: os._exit(0)
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
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
"""


def t18(d, scratch, variant):
    tid = "T18" + variant
    root = mkroot(scratch, "t18" + variant, d, tid)
    # short socket path (sun_path limit): a registered private dir under /tmp
    import tempfile
    sdir = tempfile.mkdtemp(prefix="sk18", dir="/tmp")
    register(d, tid, "dir", sdir)
    sock = sdir + "/native.sock"
    cap = root + "/capture.log"
    with open(cap, "w") as f:
        f.write("original-bytes\n" * 8)
    params = {"a": ("1.5", "0", "plain"), "b": ("0", "0", "plain"), "c": ("0", "1.5", "plain"),
              "d": ("0", "0", "plain"), "d-vanish": ("0.8", "0", "vanish"),
              "d-rebind": ("0.8", "0", "rebind")}[variant]
    srv = subprocess.Popen([PY, "-I", "-c", SERVER, sock, cap] + list(params),
                           stdout=subprocess.PIPE, close_fds=True)
    register(d, tid, "proc", srv.pid)
    srv.stdout.readline()
    history_clean = True
    cl = None
    if variant == "a":          # queued before the lock, accepted after it
        cl = socket.socket(socket.AF_UNIX)
        cl.connect(sock)
        cl.sendall(b"restart")
        history_clean = False
    elif variant == "b":        # accepted persistent; request after the lock
        cl = socket.socket(socket.AF_UNIX)
        cl.connect(sock)
        history_clean = False
        time.sleep(0.3)
    elif variant == "c":        # dispatched before the lock, acted on after it
        cl = socket.socket(socket.AF_UNIX)
        cl.connect(sock)
        cl.sendall(b"restart")
        time.sleep(0.3)
        cl.close()
        cl = None
        history_clean = False
    r = W.socket_rec(sock)
    os.chmod(sock, 0)
    lr = W.socket_rec(sock)
    lock = {"t": W.now(), "sockets": {sock: lr}}
    eacces = W.check_eacces(sock)
    snap0 = snap_now("SNAP-0", {cap: capture_meta(cap)}, {sock: W.socket_rec(sock)})
    if variant == "b":
        cl.sendall(b"restart")
    time.sleep(2.5)
    if cl is not None:
        cl.close()
    snappre = snap_now("SNAP-pre", {cap: capture_meta(cap)}, {sock: W.socket_rec(sock)})
    v0, _ = prefix_violations(snap0, cap)
    snappre["violations"] = v0
    srv.send_signal(signal.SIGTERM)  # graceful: the fixture unlinks its socket and exits 0
    srv.wait()
    v1, post_meta = prefix_violations(snappre, cap) if not v0 else ([], capture_meta(cap))
    snappost = snap_now("SNAP-post", {cap: post_meta}, {sock: W.socket_rec(sock)})
    snappost["violations"] = v1
    dead = synthetic_singletons(snap0["t"] - 1, snappre["t"] + 0.5)
    complete, reasons = classify_synthetic(dead, [], {"SNAP-0": snap0, "SNAP-pre": snappre,
                                                      "SNAP-post": snappost}, lock, True,
                                           history_clean=history_clean)
    notes = {"eacces_after_lock": eacces, "complete": complete, "reasons": reasons,
             "socket_post": "present" if W.socket_rec(sock)["present"] else "unlinked",
             "pre_lock_type": r.get("type")}
    W.run(["/bin/rm", "-rf", "--", root, sdir], env=W.TOOL_ENV)
    if variant == "d":
        ok = complete and eacces == "errno-13" and notes["socket_post"] == "unlinked"
        return verdict(d, tid, "PASS", notes, ok)
    ok = (not complete) and (eacces == "errno-13" or variant.startswith("d-"))
    return verdict(d, tid, "INCOMPLETE", notes, ok)


# ---------------------------------------------------------------- injections (T15a-c)
def inject(kind, path, pid=None):
    """Deliberate fixture defects after the stop began and before SNAP-post (r4 2.6)."""
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
        raise W.Hold("unknown injection")
    return {"injected": kind, "path": path}


def summary(d, head, ids):
    missing, bad, recs = [], [], {}
    for tid in ids:
        p = "%s/%s.json" % (d, tid)
        if not os.path.exists(p):
            missing.append(tid)
            continue
        r = W.jload(p)
        recs[tid] = r["verdict"]
        if r["verdict"] not in ("PASS", "EXPECTED-REFUSAL") or r["unregistered"]:
            bad.append(tid)
    out = {"head": head, "pass": not missing and not bad, "missing": missing, "bad": bad,
           "verdicts": recs}
    W.jdump(out, d + "/selftest-summary.json")
    return out


# ---------------------------------------------------------------- CLI
def main(argv):
    cmd, a = argv[0], W.parse_kv(argv[1:])
    try:
        if cmd == "register":
            register(a["dir"], a["test"], a["kind"], json.loads(a["what"]))
        elif cmd == "verdict":
            rec = verdict(a["dir"], a["test"], a["expected"], a.get("observed", ""),
                          a.get("ok") == "1", json.loads(a.get("notes", "{}")),
                          json.loads(a.get("retained", "[]")))
            W.jdump(rec)
            return 0 if rec["verdict"] in ("PASS", "EXPECTED-REFUSAL") else 4
        elif cmd == "fixture-tcp-decoy":
            fixture_tcp_decoy(a["addr"], a["port"], a["count_file"])
        elif cmd == "fixture-unix-listener":
            fixture_unix_listener(a["path"])
        elif cmd == "fixture-cwd-holder":
            fixture_cwd_holder(a["cwd"])
        elif cmd == "fixture-sleeper":
            fixture_sleeper(a.get("seconds", "600"))
        elif cmd == "kill-fixture":
            W.jdump({"result": kill_fixture(a["pid"], a["birth_us"])})
        elif cmd == "inject":
            W.jdump(inject(a["kind"], a["path"], a.get("pid")))
        elif cmd == "state-has-pid":
            st = W.jload(a["state"])
            pid = int(a["pid"])
            W.jdump({"admitted": any(e["pid"] == pid for e in st["live"] + st["dead"])})
        elif cmd == "summary":
            out = summary(a["dir"], a["head"], a["ids"].split(","))
            W.jdump(out)
            return 0 if out["pass"] else 4
        elif cmd == "identity":
            W.jdump(W.bsdinfo(int(a["pid"])))
        elif cmd == "synthetic":
            d, scratch, tid = a["dir"], a["scratch"], a["id"]
            fn = {"T9a": t9a, "T9b": t9b, "T10": t10, "T11": t11, "T12": t12, "T15d": t15d,
                  "T16": t16}.get(tid)
            if fn is not None:
                rec = fn(d, scratch)
            elif tid in ("T17a", "T17b"):
                rec = t17(d, scratch, tid[-1])
            elif tid in ("T18a", "T18b", "T18c", "T18d", "T18d-vanish", "T18d-rebind"):
                rec = t18(d, scratch, tid[3:])
            else:
                return 64
            W.jdump(rec)
            return 0 if rec["verdict"] in ("PASS", "EXPECTED-REFUSAL") else 4
        else:
            return 64
        return 0
    except W.Hold as h:
        sys.stderr.write("HOLD %s\n" % h)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
