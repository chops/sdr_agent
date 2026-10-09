// Falsifiable checks for the slice A prototype.
// Run from the repository root: node docs/product/slice-a/check-prototype.mjs
// No dependencies. Exits non-zero if any check fails.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const read = (f) => readFileSync(join(here, f), "utf8");

function load() {
  const window = {};
  const ctx = vm.createContext({ window, globalThis: window, JSON, Math, Object, String, Number, Error });
  vm.runInContext(read("prototype-logic.js"), ctx, { filename: "prototype-logic.js" });
  return window.SliceAProto;
}
const P = load();
const at = (h, m) => h * 60 + m;

// A small HTML attribute reader that follows the browser's rules for quoted
// values (a value ends at its matching quote; there is no escaping inside),
// so it breaks exactly where a browser would.
function decode(v) {
  return v.replace(/&(#39|quot|amp|lt|gt);/g, (_, e) => ({ "#39": "'", quot: '"', amp: "&", lt: "<", gt: ">" })[e]);
}
function buttons(html) {
  const out = [];
  const re = /<button\b/g;
  let m;
  while ((m = re.exec(html))) {
    let i = m.index + 7;
    const attrs = {};
    while (i < html.length && html[i] !== ">") {
      while (/\s/.test(html[i])) i++;
      if (html[i] === ">") break;
      let name = "";
      while (i < html.length && !/[\s=>]/.test(html[i])) name += html[i++];
      let value = "";
      if (html[i] === "=") {
        i++;
        const q = html[i];
        if (q === '"' || q === "'") {
          const end = html.indexOf(q, i + 1);
          value = html.slice(i + 1, end);
          i = end + 1;
        } else {
          while (i < html.length && !/[\s>]/.test(html[i])) value += html[i++];
        }
      }
      if (name) attrs[name.toLowerCase()] = decode(value);
    }
    const close = html.indexOf("</button>", i);
    out.push({ attrs, text: html.slice(i + 1, close).replace(/<[^>]+>/g, "") });
  }
  return out;
}
// What clicking a rendered button would open: data-page-ref indexes the
// render's list of destinations; a legacy data-page holds JSON.
function destination(btn, refs) {
  if ("data-page-ref" in btn.attrs) {
    const page = refs[Number(btn.attrs["data-page-ref"])];
    if (!page) throw new Error("data-page-ref " + btn.attrs["data-page-ref"] + " has no destination");
    return page;
  }
  if ("data-page" in btn.attrs) return JSON.parse(btn.attrs["data-page"]);
  return null;
}

const STATES = [];
for (const role of ["admin", "reviewer", "auditor"])
  for (const view of ["normal", "empty", "stale"])
    for (const provider of ["fake", "real", "refusing"])
      for (const now of [at(7, 58), at(8, 5)]) STATES.push({ role, view, provider, now });

const checks = [];
const check = (name, fn) => checks.push([name, fn]);

check("every link on home, withheld and placeholder pages opens a known page", () => {
  const renders = STATES.map((s) => P.renderHome(s))
    .concat([P.renderWithheld({ view: "error" }), P.renderWithheld({ view: "refused" })])
    .concat(Object.keys(P.PAGES).map((key) => P.renderPlaceholder({ key, title: "Kestrel's \"EU\" <region> & co" })));
  let n = 0;
  for (const r of renders) {
    for (const b of buttons(r.html)) {
      if ("data-jump" in b.attrs) continue;
      const page = destination(b, r.refs);
      assert.ok(page && P.PAGES[page.key], "unknown destination for button '" + b.text + "'");
      n++;
    }
  }
  assert.ok(n > 100, "expected many links, found " + n);
});

check("drafts with apostrophes and markup-shaped titles open their own draft page", () => {
  const r = P.renderHome({ role: "admin", view: "normal", provider: "fake", now: at(7, 58) });
  const want = { d2: "Kestrel's new EU region", d3: "Northgate's support backlog", d4: "Re: <Q4> \"pricing\" & Ops' plan" };
  const opened = {};
  for (const b of buttons(r.html)) {
    const page = destination(b, r.refs);
    if (page && page.key === "draft") opened[page.id] = { page, text: b.text };
  }
  for (const [id, title] of Object.entries(want)) {
    assert.ok(opened[id], "no working link for draft " + id);
    assert.equal(opened[id].page.title, title);
    assert.ok(decode(opened[id].text).includes(title), "visible text for " + id + " is not its subject");
  }
  assert.ok(!r.html.includes("<Q4>"), "a subject's angle brackets must be escaped in the markup");
});

check("home shows at most 5 drafts and links the review queue with the full count", () => {
  const r = P.renderHome({ role: "admin", view: "normal", provider: "fake", now: at(7, 58) });
  const drafts = buttons(r.html).map((b) => destination(b, r.refs)).filter((p) => p && p.key === "draft");
  assert.equal(drafts.length, 5);
  assert.match(r.html, /See all 7 in the review queue/);
});

check("delivery buckets are disjoint, cover every state, and never call an expired deferral sent", () => {
  const all = ["pending", "attempting", "accepted", "unknown", "failed_retryable", "failed_permanent", "delivered", "bounced", "cancelled"];
  for (const state of all) for (const nb of [null, at(7, 0), at(9, 0)]) {
    const k = P.bucketOf({ state, notBefore: nb }, at(8, 0));
    assert.ok(P.BUCKETS.some((b) => b.key === k), state + " has no bucket");
  }
  const rows = P.EX.deliveries;
  const before = P.deliveryBuckets(rows, at(7, 58));
  const after = P.deliveryBuckets(rows, at(8, 5));
  const sum = (b) => Object.values(b.counts).reduce((a, n) => a + n, 0);
  assert.equal(sum(before), rows.length);
  assert.equal(sum(after), rows.length);
  assert.deepEqual([before.counts.deferred, before.nextDue, before.lastDue], [4, at(8, 0), at(9, 30)]);
  assert.equal(before.counts.queued, 1, "pending with no not_before is due now");
  assert.equal(after.counts.deferred, 1, "only the 09:30 deferral is still waiting at 08:05");
  assert.equal(after.counts.queued, 3, "expired pending deferrals become queued, not sent");
  assert.equal(after.counts.retry_due, 1, "an expired failed_retryable deferral becomes retry due");
  assert.equal(after.counts.captured, before.counts.captured, "time passing never adds captured sends");
  assert.equal(after.counts.unknown, 1);
  assert.equal(after.counts.cancelled, 1);
});

check("the 24-hour stopped-run window follows finished_at and the clock", () => {
  assert.equal(P.stoppedIn24h(P.EX.runs, at(7, 58)), 2, "07:30 budget stop and the 08:01-yesterday failure");
  assert.equal(P.stoppedIn24h(P.EX.runs, at(8, 5)), 1, "the 08:01-yesterday failure has left the window");
  assert.equal(P.activeRuns(P.EX.runs), 1);
});

check("unknown outcomes link to Runs & operations; a failure without a subject page falls back there", () => {
  const r = P.renderHome({ role: "reviewer", view: "normal", provider: "fake", now: at(8, 5) });
  const pages = buttons(r.html).map((b) => [b.text, destination(b, r.refs)]);
  assert.ok(pages.some(([t, p]) => p && p.key === "operations" && /Reconcile 1 unknown outcome/.test(t)));
  assert.ok(pages.some(([t, p]) => p && p.key === "operations" && /no page for its subject/.test(t)));
  assert.ok(pages.some(([, p]) => p && p.key === "subject"));
});

check("the model card is admin-only and never claims Admin changes settings", () => {
  for (const role of ["reviewer", "auditor"]) {
    const r = P.renderHome({ role, view: "normal", provider: "real", now: at(7, 58) });
    assert.ok(!/Model and budget/.test(r.html), role + " must not see the model card");
  }
  const a = P.renderHome({ role: "admin", view: "normal", provider: "refusing", now: at(7, 58) });
  assert.match(a.html, /Model calls reserved today \(UTC day/);
  assert.match(a.html, /Configured: Claude CLI\. In effect: none/);
  assert.ok(!/(Changing|change) the model or budget happens on Admin/.test(a.html));
  const admin = P.renderPlaceholder({ key: "admin" }).html;
  assert.match(admin, /Admin is read-only/);
  assert.ok(!/\(approve, resolve, retry\)/.test(admin));
});

check("every scenario keeps the example, capture-only and fake labels", () => {
  for (const s of STATES) {
    const html = P.renderHome(s).html;
    assert.match(html, /Local capture only/);
    if (s.role === "admin" && s.provider === "fake") assert.match(html, /fake model/i);
    if (s.view !== "empty") assert.match(html, /\(example\)/);
  }
});

check("slice-a notes.js logic matches docs/sdlc/notes.js", () => {
  const strip = (t) => t.split("\n").slice(3).join("\n");
  const original = readFileSync(join(here, "..", "..", "sdlc", "notes.js"), "utf8");
  assert.equal(strip(read("notes.js")), original);
});

check("the page wires the logic, notes and controls", () => {
  const html = read("prototype.html");
  for (const s of ['src="prototype-logic.js"', 'src="notes.js"', 'id="ctl-clock"', '"refused"', "data-page-ref", "prefers-reduced-motion: reduce)\").matches", "--on-owner"]) {
    assert.ok(html.includes(s), "prototype.html is missing " + s);
  }
  assert.ok(!/data-page='/.test(html), "no JSON in single-quoted data-page attributes");
  const inline = html.split("<script>")[1].split("</script>")[0];
  new vm.Script(inline, { filename: "prototype.html inline script" });
});

let failed = 0;
for (const [name, fn] of checks) {
  try { fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message); }
}
console.log(`${checks.length - failed}/${checks.length} checks passed`);
process.exit(failed ? 1 : 0);
