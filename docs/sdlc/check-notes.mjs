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
const ORIGIN = { revision: D.meta.revision, fingerprint: N.fingerprint(D) };
const checks = [];
const check = (name, fn) => checks.push([name, fn]);

check("data has a revision that exports carry", () => {
  assert.match(D.meta.revision, /^\d{4}-\d{2}-\d{2}\.\d+$/);
});

check("working storage keeps notes across a reload, with no warning", () => {
  const storage = memoryStorage();
  const a = N.createStore(() => storage, KEY, ORIGIN);
  assert.equal(a.available, true);
  assert.equal(a.set("phase:P0", "keep this"), true);
  assert.equal(N.storageWarning(a), "");
  const b = N.createStore(() => storage, KEY, ORIGIN);
  assert.equal(b.get("phase:P0"), "keep this");
});

check("denied storage warns, reports unsaved writes, and still exports", () => {
  const denied = () => { throw new Error("SecurityError"); };
  const s = N.createStore(denied, KEY, ORIGIN);
  assert.equal(s.available, false);
  assert.equal(s.set("q:Q1", "weekdays only"), false);
  assert.match(N.storageWarning(s), /not saving notes/);
  const text = N.exportText(D, s.all(), N.fingerprint(D));
  assert.match(text, /weekdays only/);
  assert.ok(text.includes("data revision " + D.meta.revision), "the export names the revision it came from");
  assert.match(text, /not approvals/);
  const reloaded = N.createStore(denied, KEY, ORIGIN);
  assert.equal(reloaded.get("q:Q1"), "", "a reload loses notes, which is why the page warns");
});

check("a write that fails after the page loads switches to the warning", () => {
  const s = N.createStore(() => memoryStorage({ failWrites: true }), KEY, ORIGIN);
  assert.equal(s.available, true);
  assert.equal(s.set("phase:P1", "late failure"), false);
  assert.equal(s.available, false);
  assert.match(N.storageWarning(s), /not saving new notes/);
  assert.equal(s.get("phase:P1"), "late failure", "the note stays in memory for export");
});

check("the fingerprint changes when the process data changes", () => {
  const before = N.fingerprint(D);
  const changed = JSON.parse(JSON.stringify(D));
  changed.phases[0].goal += ".";
  assert.notEqual(N.fingerprint(changed), before);
  assert.match(before, /^[0-9a-f]{8}$/);
});

check("full storage still shows and exports notes saved earlier", () => {
  const existing = JSON.stringify({ version: 2, notes: { "phase:P0": { text: "saved before the quota filled", revision: D.meta.revision, fingerprint: ORIGIN.fingerprint, context: "P0" } } });
  const storage = { getItem: () => existing, setItem: () => { throw new Error("QuotaExceededError"); }, removeItem: () => {} };
  const s = N.createStore(() => storage, KEY, ORIGIN);
  assert.equal(s.available, false);
  assert.equal(s.problem, "write_failed");
  assert.match(N.storageWarning(s), /Notes saved earlier are still shown/);
  assert.equal(s.get("phase:P0"), "saved before the quota filled");
  assert.match(N.exportText(D, s.all(), ORIGIN.fingerprint), /saved before the quota filled/);
  assert.equal(storage.getItem(KEY), existing, "the saved bytes are untouched");
});

check("notes from an older revision keep their origin and are not exported as current", () => {
  const storage = memoryStorage();
  const old = JSON.parse(JSON.stringify(D));
  old.meta.revision = "2026-10-08.1";
  const oq = old.openQuestions[0];
  const key = "q:" + oq.id;
  oq.q = "Accept the old twelve-calendar-day plan?";
  const oldOrigin = { revision: old.meta.revision, fingerprint: N.fingerprint(old) };
  const before = N.createStore(() => storage, KEY, oldOrigin);
  before.set(key, "Yes to the old twelve-day proposal", oq.id + ". " + oq.q);
  const after = N.createStore(() => storage, KEY, ORIGIN);
  assert.equal(after.isStale(key), true);
  const text = N.exportText(D, after.all(), ORIGIN.fingerprint);
  const [currentPart, olderPart] = text.split("Older notes, not confirmed for revision " + D.meta.revision);
  assert.ok(olderPart, "older notes are listed in their own section");
  assert.ok(!currentPart.includes("twelve-day"), "old feedback is not listed as current");
  assert.ok(olderPart.includes("written against revision 2026-10-08.1"));
  assert.ok(olderPart.includes("Accept the old twelve-calendar-day plan?"), "the wording it answered is kept");
  after.set(key, after.get(key), oq.id + ". current");
  assert.equal(after.isStale(key), false, "keeping it for this revision re-stamps it");
});

check("notes in the old v1 format stay as notes of unknown revision", () => {
  const storage = memoryStorage();
  storage.setItem(KEY, JSON.stringify({ "phase:P1": "legacy note" }));
  const s = N.createStore(() => storage, KEY, ORIGIN);
  assert.equal(s.get("phase:P1"), "legacy note");
  assert.equal(s.isStale("phase:P1"), true);
  assert.match(N.exportText(D, s.all(), ORIGIN.fingerprint), /unknown revision[\s\S]*legacy note/);
});

check("unreadable saved data is kept, never overwritten, and exported raw", () => {
  const storage = memoryStorage();
  storage.setItem(KEY, "{not json");
  const s = N.createStore(() => storage, KEY, ORIGIN);
  assert.equal(s.problem, "corrupt");
  assert.equal(s.available, false);
  assert.equal(s.set("q:Q1", "new note"), false);
  assert.equal(storage.getItem(KEY), "{not json", "the original bytes survive");
  const text = N.exportText(D, s.all(), ORIGIN.fingerprint, s.unreadable);
  assert.match(text, /could not read \(raw\)/);
  assert.match(text, /\{not json/);
  assert.match(text, /new note/);
});

check("the page wires the warning, the save state and the exports", () => {
  const html = read("index.html");
  for (const id of ['id="storage-warning"', 'id="save-state"', 'id="copy"', 'id="download"', 'src="notes.js"']) {
    assert.ok(html.includes(id), "index.html is missing " + id);
  }
  const inline = html.split("<script>")[1].split("</script>")[0];
  new vm.Script(inline, { filename: "index.html inline script" });
  assert.ok(inline.includes("N.storageWarning(store)"));
  assert.ok(inline.includes("revision: D.meta.revision"), "the store must know which revision the page shows");
  assert.ok(inline.includes("store.unreadable"), "exports must include unreadable saved data");
  assert.ok(!/catch \(e\) \{\}\s*\}\s*$/.test(inline.split("function renderSaveState")[0]), "note writes must not swallow failures");
});

let failed = 0;
for (const [name, fn] of checks) {
  try { fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message); }
}
console.log(`${checks.length - failed}/${checks.length} checks passed`);
process.exit(failed ? 1 : 0);
