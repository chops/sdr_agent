// A fragment never reaches HTTP. Remove it before handing its bearer to the
// existing CSRF-protected form; only an explicit user submit sends that form.
export function prepareHostedEnrollment(window) {
  if (window.location.pathname !== "/hosted-enrollment") return

  const fragment = window.location.hash.slice(1)
  try {
    window.history.replaceState(window.history.state, "", "/hosted-enrollment")
  } catch {
    // If the URL cannot be scrubbed, leave the form closed and empty.
    return
  }

  const form = window.document.querySelector("#hosted-enrollment-form")
  if (!form) return
  const input = form.querySelector("input[name=enrollment_token]")
  const submit = form.querySelector("button[type=submit]")
  if (!input || !submit) return

  input.value = ""
  submit.disabled = true
  const entries = [...new URLSearchParams(fragment)]
  if (entries.length !== 1 || entries[0][0] !== "enrollment_token") return
  const token = entries[0][1]
  if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) return

  input.value = token
  submit.disabled = false
}
