// S-B5 fragment handoff contract. Node's built-in runner; no browser/network.
import test from "node:test"
import assert from "node:assert/strict"
import {existsSync, readFileSync} from "node:fs"

const moduleURL = new URL("../../assets/js/hosted_enrollment.mjs", import.meta.url)
const token = "eyJsynthetic.header.signature"

async function prepare() {
  assert.ok(existsSync(moduleURL), "missing bundled hosted enrollment handoff module")
  const module = await import(moduleURL)
  assert.equal(typeof module.prepareHostedEnrollment, "function")
  return module.prepareHostedEnrollment
}

function page(hash = `#enrollment_token=${token}`) {
  const events = []
  const input = {value: ""}
  const submit = {disabled: true}
  const form = {
    querySelector: selector => selector === "input[name=enrollment_token]" ? input : submit,
    submit: () => assert.fail("handoff must not submit automatically"),
    requestSubmit: () => assert.fail("handoff must not submit automatically"),
  }
  return {
    events, input, submit,
    location: {pathname: "/hosted-enrollment", search: "", hash},
    history: {state: null, replaceState: (_state, _title, url) => events.push(["strip", url])},
    document: {querySelector: selector => {
      assert.ok(events.length > 0, "remove fragment before inspecting or populating the form")
      return selector === "#hosted-enrollment-form" ? form : null
    }},
  }
}

test("strips the fragment first, fills the CSRF form and enables explicit submission", async () => {
  const run = await prepare()
  const window = page()
  run(window)
  assert.deepEqual(window.events, [["strip", "/hosted-enrollment"]])
  assert.equal(window.input.value, token)
  assert.equal(window.submit.disabled, false)
})

test("a missing or malformed fragment stays closed and is removed", async () => {
  const run = await prepare()
  for (const hash of ["", "#wrong=value", "#enrollment_token=", "#enrollment_token=%E0%A4%A"]) {
    const window = page(hash)
    run(window)
    assert.deepEqual(window.events, [["strip", "/hosted-enrollment"]])
    assert.equal(window.input.value, "")
    assert.equal(window.submit.disabled, true)
  }
})

test("ambiguous or extra fragment parameters stay closed", async () => {
  const run = await prepare()
  for (const hash of [`#enrollment_token=${token}&enrollment_token=other`, `#enrollment_token=${token}&extra=x`]) {
    const window = page(hash)
    run(window)
    assert.equal(window.input.value, "")
    assert.equal(window.submit.disabled, true)
  }
})

test("a history failure never exposes the token in the form", async () => {
  const run = await prepare()
  const window = page()
  window.history.replaceState = () => {throw new Error("synthetic history failure")}
  assert.doesNotThrow(() => run(window))
  assert.equal(window.input.value, "")
  assert.equal(window.submit.disabled, true)
})

test("non-enrollment pages are untouched", async () => {
  const run = await prepare()
  const window = page()
  window.location.pathname = "/leads"
  run(window)
  assert.deepEqual(window.events, [])
  assert.equal(window.input.value, "")
})

test("the entry point imports and invokes the bundled handoff", async () => {
  await prepare()
  const app = readFileSync(new URL("../../assets/js/app.js", import.meta.url), "utf8")
  assert.match(app, /import\s*\{\s*prepareHostedEnrollment\s*\}\s*from\s*["']\.\/hosted_enrollment\.mjs["']/)
  assert.match(app, /prepareHostedEnrollment\(window\)/)
})
