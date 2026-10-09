// Falsifiable checks for the P1 review page's notes and choices.
// Run from the repository root: node docs/product/discovery/check-p1.mjs
// No dependencies. Exits non-zero if any check fails.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const read = (f) => readFileSync(join(here, f), "utf8");
const KEY = "sdr-p1-review-v1";

// A minimal DOM: elements by id, the choice fieldsets, and captured document
// listeners so tests can dispatch the page's own input/change/click handlers.
function boot(saved) {
  const data = new Map(saved ? [[KEY, saved]] : []);
  const storage = { getItem: (k) => (data.has(k) ? data.get(k) : null), setItem: (k, v) => data.set(k, String(v)), removeItem: (k) => data.delete(k) };
  const els = new Map();
  const el = (id) => {
    if (!els.has(id)) els.set(id, {
      id, innerHTML: "", textContent: "", hidden: true, value: "", className: "", listeners: {},
      classList: { toggle() {} }, addEventListener(t, fn) { this.listeners[t] = fn; },
      insertAdjacentHTML() {}, scrollIntoView() {}, focus() {}, select() {}
    });
    return els.get(id);
  };
  const fieldset = (key, context, values) => ({
    key, radios: values.map((value) => ({ type: "radio", value, checked: false })),
    getAttribute(n) { return n === "data-choice" ? key : n === "data-context" ? context : null; },
    querySelectorAll() { return this.radios; }
  });
  const fieldsets = [
    fieldset("choice:brief", "Outcome brief verdict", ["Approve", "Approve with the changes in my notes", "Needs another round"]),
    fieldset("choice:story", "Story map verdict", ["Approve", "Approve with the changes in my notes", "Needs another round"]),
    fieldset("choice:slice", "First build slice choice", ["A. Operator shell and home", "B. Review workspace", "C. CSV import", "Something else (see note)"]),
    fieldset("founder:type", "Founder conversation: kind of evidence", ["Interview (they described their work)", "Reaction to a demo", "I watched them do the task", "A mix"])
  ];
  const docListeners = {};
  const document = {
    getElementById: el,
    addEventListener(t, fn) { docListeners[t] = fn; },
    querySelector(sel) {
      const m = sel.match(/^fieldset\[data-choice="([^"]+)"\]$/);
      return m ? fieldsets.find((f) => f.key === m[1]) || null : null;
    },
    querySelectorAll(sel) { return sel === "fieldset[data-choice]" ? fieldsets : []; }
  };
  const window = { localStorage: storage };
  window.self = window; window.top = window;
  const ctx = vm.createContext({ window, document, navigator: {}, location: { hash: "" }, Date, console, JSON, Math, Object, String, Array });
  vm.runInContext(read("p1-data.js"), ctx, { filename: "p1-data.js" });
  vm.runInContext(read("notes.js"), ctx, { filename: "notes.js" });
  const inline = read("p1-review.html").match(/<script>\s*([\s\S]*?)<\/script>/)[1];
  vm.runInContext(inline, ctx, { filename: "p1-review.html inline script" });
  const markers = () => [...els.values()].flatMap((n) => [...String(n.innerHTML).matchAll(/data-stale="([^"]+)"/g)].map((m) => m[1]));
  const exportText = () => { el("show").listeners.click(); return el("export-text").value; };
  return { data, el, fieldsets, docListeners, markers, exportText, P: window.P1 };
}

const fs = (b, key) => b.fieldsets.find((f) => f.key === key);
const checked = (b, key) => (fs(b, key).radios.find((r) => r.checked) || {}).value || null;
const older = (notes) => JSON.stringify({ version: 2, notes });
const OLD = (text, context) => ({ text, revision: "older-revision", fingerprint: "old", context });

const checks = [];
const check = (name, fn) => checks.push([name, fn]);

check("current-revision choices are shown as selected, with no stale marker", () => {
  const first = boot();
  const rev = first.P.meta.revision;
  const saved = older({ "choice:brief": { text: "Approve", revision: rev, fingerprint: "x", context: "Outcome brief verdict" } });
  const b = boot(saved);
  assert.equal(checked(b, "choice:brief"), "Approve");
  assert.ok(!b.markers().includes("choice:brief"));
});

check("older-revision verdict, slice and evidence choices are not selected and are marked stale", () => {
  const b = boot(older({
    "choice:brief": OLD("Approve", "Old brief verdict"),
    "choice:slice": OLD("A. Operator shell and home", "Old first slice"),
    "founder:type": OLD("Reaction to a demo", "Old evidence type")
  }));
  for (const k of ["choice:brief", "choice:slice", "founder:type"]) {
    assert.equal(checked(b, k), null, k + " must not look like current feedback");
    assert.ok(b.markers().includes(k), k + " needs a visible stale marker");
  }
});

check("older choices are exported apart from current feedback", () => {
  const b = boot(older({ "choice:brief": OLD("Approve", "Old brief verdict") }));
  const text = b.exportText();
  const [current, olderPart] = text.split("Older notes, not confirmed");
  assert.ok(olderPart && olderPart.includes("Approve"), "older choice is in the older section");
  assert.ok(!/Outcome brief verdict:\n\s+Approve/.test(current), "older choice is not listed as current");
});

check("keeping an older choice re-stamps it, selects it and removes the marker", () => {
  const b = boot(older({ "choice:slice": OLD("A. Operator shell and home", "Old first slice") }));
  const button = { getAttribute: (n) => (n === "data-confirm-choice" ? "choice:slice" : null) };
  b.docListeners.click({ target: { closest: (sel) => (sel === "button[data-confirm-choice]" ? button : null) } });
  assert.equal(checked(b, "choice:slice"), "A. Operator shell and home");
  assert.ok(!b.el("stale-choice:slice").innerHTML.includes("data-stale"), "marker cleared");
  const stored = JSON.parse(b.data.get(KEY)).notes["choice:slice"];
  assert.equal(stored.revision, b.P.meta.revision);
  assert.ok(!b.exportText().includes("Older notes"), "no longer exported as older");
});

check("choosing again replaces an older choice and clears its marker", () => {
  const b = boot(older({ "choice:brief": OLD("Approve", "Old brief verdict") }));
  const f = fs(b, "choice:brief");
  const radio = f.radios[2];
  radio.checked = true;
  b.docListeners.change({ target: { type: "radio", value: radio.value, closest: () => f } });
  assert.equal(checked(b, "choice:brief"), "Needs another round");
  assert.ok(!b.el("stale-choice:brief").innerHTML.includes("data-stale"));
  assert.equal(JSON.parse(b.data.get(KEY)).notes["choice:brief"].revision, b.P.meta.revision);
});

check("older free-text notes keep their origin in the export", () => {
  const b = boot(older({ "note:OUT-1": OLD("faster than by hand?", "OUT-1 Prepared faster") }));
  const text = b.exportText();
  assert.ok(text.includes("[written against revision older-revision]"));
  assert.ok(text.includes("faster than by hand?"));
});

check("notes.js is the reviewed docs/sdlc/notes.js plus a three-line header", () => {
  const copy = read("notes.js").split("\n").slice(3).join("\n");
  const original = readFileSync(join(here, "../../sdlc/notes.js"), "utf8");
  assert.equal(copy, original, "notes.js drifted from docs/sdlc/notes.js");
});

let failed = 0;
for (const [name, fn] of checks) {
  try { fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message); }
}
console.log(`${checks.length - failed}/${checks.length} checks passed`);
process.exit(failed ? 1 : 0);
