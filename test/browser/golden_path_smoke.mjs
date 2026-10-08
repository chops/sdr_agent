#!/usr/bin/env node
// S13 browser smoke of the golden path — a scripted, headless real-browser
// check (no npm dependency; Node >= 22 for its built-in WebSocket, and a
// local Google Chrome / Chromium). It is NOT part of `mix test`/CI: CI cannot
// run a browser in its loopback-only namespace. Run it against the
// throw-away smoke server, never the dev server:
//
//   bin/demo --test reset --yes && bin/demo --test seed
//   bin/demo --test serve &                       # http://127.0.0.1:4122
//   node test/browser/golden_path_smoke.mjs [base-url] [screenshot-dir]
//
// Before any browser starts or anything is sent it proves the target is the
// throw-away smoke server (review #25): it refuses the dev port 4120 and any
// non-loopback URL, reads the launcher's attestation file
// (tmp/smoke/attestation-<port>.json, written by `mix sdr.demo.serve`) and
// requires GET /__smoke/attestation to return the same nonce and database,
// a `sdr_agent_test*_demo` one (exit 3 otherwise). The dev server has no
// such endpoint, so it can never be driven.
//
// It then signs in as the demo reviewer (password read from the project's
// own fixture file, never printed), assigns lead 01 and waits — without a
// reload — for the agent's draft to appear (LiveView socket + live refresh),
// approves the displayed revision and recipient, waits for the capture and
// opens the captured message — or, inside the campaign's quiet hours
// (18:00–08:00 America/Denver), requires the send gate's recorded
// `defer_quiet_hours` outcome, a future not-before time and no capture (a
// merely pending delivery is not enough). Exits non-zero on the first
// failed step.

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const base = process.argv[2] ?? "http://127.0.0.1:4122";
const shots = process.argv[3] ?? null;
const chrome =
  process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(base)) {
  console.error(`refusing: ${base} is not a loopback URL`);
  process.exit(2);
}
const basePort = Number(new URL(base).port);
if (basePort === 4120) {
  console.error("refusing: 4120 is the dev server's port; the smoke runs only against bin/demo --test serve");
  process.exit(2);
}

function refuse(reason) {
  console.error(`refusing: ${reason}`);
  process.exit(3);
}

// The launcher-owned handshake (SdrAgentWeb.SmokeAttestation).
async function attest() {
  let file;
  try {
    file = JSON.parse(readFileSync(new URL(`../../tmp/smoke/attestation-${basePort}.json`, import.meta.url), "utf8"));
  } catch {
    refuse(`no smoke attestation for port ${basePort}; start the server with bin/demo --test serve`);
  }
  let server;
  try {
    const response = await fetch(`${base}/__smoke/attestation`, { redirect: "error" });
    if (response.status !== 200) refuse(`${base} is not an attested smoke server (HTTP ${response.status})`);
    server = await response.json();
  } catch (error) {
    refuse(`${base} did not attest (${error.message})`);
  }
  if (typeof file.nonce !== "string" || file.nonce.length < 32 || server.nonce !== file.nonce)
    refuse("the server's attestation does not match the launcher's");
  if (file.port !== basePort || server.env !== "test" || server.database !== file.database)
    refuse("the attestation names another instance");
  if (!/^sdr_agent_test\w*_demo$/.test(server.database))
    refuse(`database ${server.database} is not a throw-away _demo database`);
  console.log(`ok   attested smoke server (database ${server.database})`);
}

const fixtures = readFileSync(new URL("../../lib/sdr_agent/demo/fixtures.ex", import.meta.url), "utf8");
const reviewer = /email: "(reviewer@example\.test)"[\s\S]*?password: "([^"]+)"/.exec(fixtures);
const lead01 = /\{"01", "[^"]+", "[^"]+",\s*"([0-9a-f-]{36})"/.exec(fixtures);
if (!reviewer || !lead01) throw new Error("demo fixtures not found");

let profile = null;
let browser = null;
const port = 9300 + Math.floor(Math.random() * 400);

function startBrowser() {
  profile = mkdtempSync(join(tmpdir(), "sdr-smoke-chrome-"));
  browser = spawn(chrome, [
    "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
    "--no-first-run", "--no-default-browser-check", "--disable-extensions", "about:blank",
  ], { stdio: "ignore" });
  browser.on("error", (error) => { console.error(`FAIL cannot start Chrome (${error.message})`); process.exit(1); });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, seq = 0;
const pending = new Map();

function send(method, params = {}) {
  const id = ++seq;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
  const { result, exceptionDetails } = await send("Runtime.evaluate", {
    expression, awaitPromise: true, returnByValue: true,
  });
  if (exceptionDetails) throw new Error(exceptionDetails.text);
  return result.value;
}

async function until(label, expression, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(`Boolean(${expression})`)) { console.log(`ok   ${label}`); return; }
    await sleep(250);
  }
  const where = await evaluate("location.pathname + ' | ' + document.body.innerText.slice(0, 200).replace(/\\s+/g, ' ')");
  throw new Error(`timed out: ${label} (at ${where})`);
}

async function shot(name) {
  if (!shots) return;
  mkdirSync(shots, { recursive: true });
  const { data } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(shots, `${name}.png`), Buffer.from(data, "base64"));
}

async function goto(path) {
  await send("Page.navigate", { url: base + path });
  await sleep(500);
}

const connected = "document.querySelector('[data-phx-main].phx-connected')";

// Inside the demo campaign's quiet hours (18:00–08:00 America/Denver)?
function quietHours(now = new Date()) {
  const hour = Number(new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Denver", hour: "numeric", hourCycle: "h23",
  }).format(now));
  return hour >= 18 || hour < 8;
}

async function main() {
  await attest();
  startBrowser();
  let target;
  for (let i = 0; i < 40 && !target; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      target = list.find((t) => t.type === "page");
    } catch { await sleep(250); }
  }
  if (!target) throw new Error("headless Chrome did not start");

  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));
  ws.addEventListener("message", (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
    }
  });
  await send("Page.enable");
  await send("Runtime.enable");

  // Sign in (the password is set into the field, never logged).
  await goto("/sign-in");
  await until("sign-in page rendered", "document.querySelector('input[type=password]')");
  await evaluate(`(() => {
    const set = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); };
    set(document.querySelector('input[type=email], input[name*=email]'), ${JSON.stringify(reviewer[1])});
    set(document.querySelector('input[type=password]'), ${JSON.stringify(reviewer[2])});
  })()`);
  await sleep(750); // let the form's phx-change round-trip settle
  await evaluate("document.querySelector('input[type=password]').form.querySelector('button[type=submit], button:not([type])').click()");
  await until("signed in: console connected", `location.pathname === '/' && ${connected}`);
  await until("signed in as the reviewer", "document.querySelector('#current-role')?.textContent.includes('reviewer')");
  await shot("01-dashboard");

  // Assign lead 01 and watch the agent's draft appear without a reload.
  await goto(`/leads/${lead01[1]}`);
  await until("lead page connected", `${connected} && document.querySelector('#assign-lead')`);
  await evaluate("document.querySelector('#assign-lead').click()");
  await until("agent run listed (live)", "document.querySelector('#lead-runs a[href^=\"/runs/\"]')");
  await until("draft appeared (live refresh)", "document.querySelector('#lead-drafts a[href^=\"/drafts/\"]')", 60000);
  await shot("02-lead-drafted");
  const draftPath = await evaluate("document.querySelector('#lead-drafts a[href^=\"/drafts/\"]').getAttribute('href')");

  // Approve exactly what is displayed.
  await goto(draftPath);
  await until("draft page connected", `${connected} && document.querySelector('#approve-form')`);
  await until("recipient displayed", "document.querySelector('#binding-recipient')?.textContent.includes('@')");
  await evaluate("document.querySelector('#approve-form').requestSubmit()");
  await until("draft queued or sent", "document.querySelector('#draft-header [data-status=\"queued\"], #draft-header [data-status=\"sent\"]')");
  if (quietHours()) {
    // The campaign's send gate defers inside 18:00–08:00 America/Denver.
    // Pending alone proves nothing (the worker may not have run): require the
    // gate's recorded outcome, a future not-before and no capture.
    await until("send gate recorded defer_quiet_hours (live)", "document.querySelector('[id^=\"delivery-gate-\"][data-outcome=\"defer_quiet_hours\"]')", 60000);
    await until("not-before is in the future", "Date.parse(document.querySelector('[id^=\"delivery-not-before-\"]')?.dataset.at) > Date.now()");
    await until("still pending, nothing captured", "document.querySelector('[id^=\"delivery-\"] [data-state=\"pending\"]') && !document.querySelector('[id^=\"show-message-\"], [id^=\"receipt-\"]')");
    await shot("03-delivery-deferred");
    console.log("golden path browser smoke: PASS (quiet hours: the send gate deferred the delivery)");
    return;
  }
  await until("captured (live)", "document.querySelector('[id^=\"show-message-\"]')", 60000);
  await evaluate("document.querySelector('[id^=\"show-message-\"]').click()");
  await until("captured message shown", "document.body.innerText.includes('List-Unsubscribe')");
  await shot("03-captured-message");
  console.log("golden path browser smoke: PASS");
}

main()
  .then(() => 0, (error) => { console.error(`FAIL ${error.message}`); return 1; })
  .then(async (code) => {
    try { ws?.close(); } catch {}
    if (browser) {
      const exited = new Promise((r) => browser.once("exit", r));
      browser.kill();
      await Promise.race([exited, sleep(5000)]);
    }
    if (profile) { try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }); } catch {} }
    process.exit(code);
  });
