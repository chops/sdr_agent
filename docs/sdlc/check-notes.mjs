// Falsifiable checks for owner-note handling on the SDLC map.
// Run from the repository root: node docs/sdlc/check-notes.mjs
// No dependencies. Exits non-zero on the first failed check.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const read = (f) => readFileSync(join(here, f), "utf8");

function load() {
  const window = {};
  const ctx = vm.createContext({ window, globalThis: window, JSON, Math, Object, String });
  vm.runInContext(read("sdlc-data.js"), ctx, { filename: "sdlc-data.js" });
  vm.runInContext(read("notes.js"), ctx, { filename: "notes.js" });
  return { D: window.SDLC, N: window.SDLCNotes };
}

// A Map-backed storage; failWrites makes setItem throw after the probe.
function memoryStorage({ failWrites = false } = {}) {
  const m = new Map();
  let probed = false;
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    removeItem: (k) => m.delete(k),
    setItem: (k, v) => {
      if (failWrites && probed) throw new Error("QuotaExceededError");
      if (k === "__sdlc_probe__") probed = true;
      m.set(k, String(v));
    }
  };
}

const { D, N } = load();
const KEY = "sdlc-map-notes-v1";
const checks = [];
const check = (name, fn) => checks.push([name, fn]);

check("data has a revision that exports carry", () => {
  assert.match(D.meta.revision, /^\d{4}-\d{2}-\d{2}\.\d+$/);
});

check("working storage keeps notes across a reload, with no warning", () => {
  const storage = memoryStorage();
  const a = N.createStore(() => storage, KEY);
  assert.equal(a.available, true);
  assert.equal(a.set("phase:P0", "keep this"), true);
  assert.equal(N.storageWarning(a), "");
  const b = N.createStore(() => storage, KEY);
  assert.equal(b.get("phase:P0"), "keep this");
});

check("denied storage warns, reports unsaved writes, and still exports", () => {
  const denied = () => { throw new Error("SecurityError"); };
  const s = N.createStore(denied, KEY);
  assert.equal(s.available, false);
  assert.equal(s.set("q:Q1", "weekdays only"), false);
  assert.match(N.storageWarning(s), /not saving notes/);
  const text = N.exportText(D, s.all(), N.fingerprint(D));
  assert.match(text, /weekdays only/);
  assert.ok(text.includes("Data revision " + D.meta.revision));
  assert.match(text, /not approvals/);
  const reloaded = N.createStore(denied, KEY);
  assert.equal(reloaded.get("q:Q1"), "", "a reload loses notes, which is why the page warns");
});

check("a write that fails after the page loads switches to the warning", () => {
  const s = N.createStore(() => memoryStorage({ failWrites: true }), KEY);
  assert.equal(s.available, true);
  assert.equal(s.set("phase:P1", "late failure"), false);
  assert.equal(s.available, false);
  assert.match(N.storageWarning(s), /could not be saved/);
  assert.equal(s.get("phase:P1"), "late failure", "the note stays in memory for export");
});

check("the fingerprint changes when the process data changes", () => {
  const before = N.fingerprint(D);
  const changed = JSON.parse(JSON.stringify(D));
  changed.phases[0].goal += ".";
  assert.notEqual(N.fingerprint(changed), before);
  assert.match(before, /^[0-9a-f]{8}$/);
});

check("the page wires the warning, the save state and the exports", () => {
  const html = read("index.html");
  for (const id of ['id="storage-warning"', 'id="save-state"', 'id="copy"', 'id="download"', 'src="notes.js"']) {
    assert.ok(html.includes(id), "index.html is missing " + id);
  }
  const inline = html.split("<script>")[1].split("</script>")[0];
  new vm.Script(inline, { filename: "index.html inline script" });
  assert.ok(inline.includes("N.storageWarning(store)"));
  assert.ok(!/catch \(e\) \{\}\s*\}\s*$/.test(inline.split("function renderSaveState")[0]), "note writes must not swallow failures");
});

let failed = 0;
for (const [name, fn] of checks) {
  try { fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message); }
}
console.log(`${checks.length - failed}/${checks.length} checks passed`);
process.exit(failed ? 1 : 0);
