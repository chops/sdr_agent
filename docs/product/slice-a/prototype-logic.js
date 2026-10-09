// Rendering logic for the slice A prototype (prototype.html). Kept in its own
// file, with no DOM access, so docs/product/slice-a/check-prototype.mjs can
// run it in node: the delivery buckets, the clock-derived counts and every
// link the home renders are tested there.
//
// Links never carry data in an HTML attribute. Each rendered link registers
// its destination in a per-render list and the markup holds only its index
// (data-page-ref="3"), so titles with apostrophes, quotes, ampersands or
// angle brackets cannot break a link.
(function (root) {
  "use strict";

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // Times are minutes after midnight, Mountain Daylight Time, for the example
  // only. The product shows real timestamps with their time zone.
  function hhmm(min) {
    var h = Math.floor(min / 60) % 24, m = min % 60;
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m;
  }

  // EXAMPLE DATA. Invented companies and people; no real records.
  var EX = {
    asOf: 7 * 60 + 58, // data read at 07:58 (seconds shown as :12)
    drafts: [
      { id: "d1", subject: "Your Q3 hiring post and onboarding time", to: "Avery Lin, Quillmark (example)", age: "2 days" },
      { id: "d2", subject: "Kestrel's new EU region", to: "Sam Ortiz, Kestrel Labs (example)", age: "1 day" },
      { id: "d3", subject: "Northgate's support backlog", to: "Riya Patel, Northgate (example)", age: "5 hours" },
      { id: "d4", subject: "Re: <Q4> \"pricing\" & Ops' plan", to: "Jo Brandt, Tallow & Finch (example)", age: "4 hours" },
      { id: "d5", subject: "Brightpath's onboarding checklist", to: "Mina Cho, Brightpath (example)", age: "3 hours" },
      { id: "d6", subject: "A shorter close for Ferngrove", to: "Lee Okafor, Ferngrove (example)", age: "2 hours" },
      { id: "d7", subject: "Cobalt Works and the new warehouse", to: "Dana Ruiz, Cobalt Works (example)", age: "1 hour" }
    ],
    replies: [
      { id: "l7", company: "Brightpath (example)", label: "interested", when: "40 minutes ago" },
      { id: "l11", company: "Harbor Lane (example)", label: "unknown", when: "1 hour ago" },
      { id: "l9", company: "Cobalt Works (example)", label: null, when: "3 hours ago" },
      { id: "l12", company: null, label: null, when: null }
    ],
    problems: [
      { id: "f1", severity: "critical", cls: "Delivery outcome unknown", msg: "Capture for Ferngrove (example) did not confirm after a restart.", when: "07:41", subject: "/drafts/d6", subjectTitle: "Draft for Ferngrove (example)" },
      { id: "f2", severity: "warning", cls: "Agent run failed", msg: "Research for an archived lead stopped early.", when: "07:12", subject: null, subjectTitle: null }
    ],
    runs: [
      { id: "r12", lead: "Quillmark (example)", status: "running", note: "drafting", finishedAt: null },
      { id: "r11", lead: "Ferngrove (example)", status: "budget_exhausted", note: "Stopped: daily model budget reached", finishedAt: 7 * 60 + 30 },
      { id: "r10", lead: "Kestrel Labs (example)", status: "succeeded", note: "draft proposed", finishedAt: 7 * 60 + 5 },
      // Finished 24 h + 2 min before 08:00: inside the window at 07:58, outside at 08:05.
      { id: "r9", lead: "Northgate (example)", status: "failed", note: "Stopped: research source unreachable", finishedAt: 8 * 60 + 1 - 24 * 60 }
    ],
    // Delivery operations. notBefore in minutes; null means not deferred.
    deliveries: [
      { state: "accepted", notBefore: null }, { state: "accepted", notBefore: null }, { state: "accepted", notBefore: null },
      { state: "delivered", notBefore: null },
      { state: "pending", notBefore: 8 * 60 }, { state: "pending", notBefore: 8 * 60 },
      { state: "failed_retryable", notBefore: 8 * 60 },
      { state: "pending", notBefore: 9 * 60 + 30 },
      { state: "pending", notBefore: null },
      { state: "unknown", notBefore: null },
      { state: "cancelled", notBefore: null }
    ],
    pipeline: [
      { label: "New", n: 6 }, { label: "Researching", n: 2 }, { label: "Qualified", n: 3 },
      { label: "In outreach", n: 5 }, { label: "Replied", n: 4 }, { label: "Closed", n: 1 }, { label: "Blocked", n: 1 }
    ],
    budget: { reserved: 37, limit: 200, sendCap: 25 }
  };

  // REQ-A-7: one bucket per delivery, decided by state and not_before at the
  // evaluation time `now`. The buckets are disjoint and cover every state.
  var BUCKETS = [
    { key: "captured", label: "Captured (accepted or delivered)" },
    { key: "deferred", label: "Deferred (waiting for a set time)" },
    { key: "queued", label: "Queued (due, waiting for the send gate)" },
    { key: "retry_due", label: "Retry due (waiting for the send gate)" },
    { key: "attempting", label: "Capturing now" },
    { key: "unknown", label: "Outcome unknown" },
    { key: "failed", label: "Failed permanently" },
    { key: "bounced", label: "Bounced" },
    { key: "cancelled", label: "Cancelled (refused, revoked or suppressed)" }
  ];
  function bucketOf(d, now) {
    var deferred = d.notBefore !== null && d.notBefore !== undefined && d.notBefore > now;
    switch (d.state) {
      case "accepted": case "delivered": return "captured";
      case "pending": return deferred ? "deferred" : "queued";
      case "failed_retryable": return deferred ? "deferred" : "retry_due";
      case "attempting": return "attempting";
      case "unknown": return "unknown";
      case "failed_permanent": return "failed";
      case "bounced": return "bounced";
      case "cancelled": return "cancelled";
      default: throw new Error("unknown delivery state " + d.state);
    }
  }
  function deliveryBuckets(rows, now) {
    var out = { counts: {}, total: rows.length, nextDue: null, lastDue: null };
    BUCKETS.forEach(function (b) { out.counts[b.key] = 0; });
    rows.forEach(function (d) {
      var k = bucketOf(d, now);
      out.counts[k] += 1;
      if (k === "deferred") {
        if (out.nextDue === null || d.notBefore < out.nextDue) out.nextDue = d.notBefore;
        if (out.lastDue === null || d.notBefore > out.lastDue) out.lastDue = d.notBefore;
      }
    });
    return out;
  }

  // REQ-A-6: runs that ended failed or budget_exhausted with finished_at in
  // the 24 hours before `now`. Runs without finished_at are not counted.
  function stoppedIn24h(runs, now) {
    return runs.filter(function (r) {
      return (r.status === "failed" || r.status === "budget_exhausted") &&
        r.finishedAt !== null && r.finishedAt > now - 24 * 60 && r.finishedAt <= now;
    }).length;
  }
  function activeRuns(runs) {
    return runs.filter(function (r) { return r.status === "queued" || r.status === "running"; }).length;
  }

  var PAGES = {
    home: ["Home", "/"], leads: ["Leads", "/leads"], review: ["Review queue", "/review"],
    operations: ["Runs & operations", "/operations"], audit: ["Audit", "/audit"], admin: ["Admin", "/admin"],
    draft: ["Draft", "/drafts/:id"], lead: ["Lead", "/leads/:id"], run: ["Run", "/runs/:id"],
    subject: ["Failure subject", "subject path"]
  };
  var PLACEHOLDER = {
    admin: "Admin is read-only. It shows the model provider, the daily budget and send cap, integrations and operators. It has no settings, approve or retry controls. The model provider and budget are set in the app's reviewed launch configuration, which only you change, outside the app.",
    operations: "Runs & operations is where failures are acknowledged and resolved and unknown outcomes are reconciled, under that page's own rules.",
    draft: "The draft page is where review, edit and approval already live, under their own rules.",
    review: "The review queue lists every draft waiting for a verdict.",
    audit: "The audit timeline is read-only, and an auditor's view of it is recorded.",
    lead: "The lead page shows the lead, its replies and the agent's runs.",
    run: "The run page shows the agent's decisions and model calls for one run.",
    leads: "The leads list.",
    subject: "The page for this failure's subject."
  };

  function card(title, req, body, id) {
    return '<section class="card"' + (id ? ' id="' + id + '"' : "") + '><div class="card-head"><h3>' + title +
      '</h3><span class="req">' + req + "</span></div>" + body + "</section>";
  }

  // Renders the home for `state` = { role, view, provider, now }. Returns the
  // markup and the destinations its links point at.
  function renderHome(state) {
    var refs = [];
    function ref(page) { refs.push(page); return ' data-page-ref="' + (refs.length - 1) + '"'; }
    function item(page, main, sub) { return "<li><button type=\"button\"" + ref(page) + "><b>" + main + "</b><span>" + sub + "</span></button></li>"; }
    var now = state.now, empty = state.view === "empty";
    var drafts = empty ? [] : EX.drafts, replies = empty ? [] : EX.replies, problems = empty ? [] : EX.problems;
    var runs = empty ? [] : EX.runs, deliveries = empty ? [] : EX.deliveries;
    var h = "";
    if (state.view === "stale") h += '<p class="stale" role="status">Connection lost: numbers may be out of date. Reconnecting…</p>';
    h += '<div class="card-head"><div><div class="eyebrow">Home</div><h2>What needs you now</h2></div><span class="updated">Data as of ' +
      hhmm(EX.asOf) + ":12 MDT · times checked at " + hhmm(now) + (state.view === "stale" ? " · stale" : "") + "</span></div>";

    var b = deliveryBuckets(deliveries, now);
    if (!drafts.length && !replies.length && !problems.length && !b.counts.unknown) {
      h += '<p class="allclear">Nothing needs you right now.</p>';
    } else {
      h += '<div class="summary">' +
        '<button class="sum" type="button"' + ref({ key: "review" }) + "><b>" + drafts.length + "</b><span>drafts to review</span></button>" +
        '<button class="sum" type="button" data-jump="sec-replies"><b>' + replies.length + "</b><span>replies to handle</span></button>" +
        '<button class="sum" type="button" data-jump="sec-problems"><b>' + problems.length + "</b><span>open problems</span></button></div>";
    }

    var shown = drafts.slice(0, 5);
    var dl = shown.length ? '<ul class="list">' + shown.map(function (d) {
      return item({ key: "draft", id: d.id, title: d.subject }, esc(d.subject), "to " + esc(d.to) + " · waiting " + esc(d.age));
    }).join("") + "</ul><button class=\"linkbtn\" type=\"button\"" + ref({ key: "review" }) + ">See all " + drafts.length + " in the review queue</button>" :
      '<p class="empty">Nothing waiting. Every proposed draft has a verdict.</p>';

    var rl = replies.length ? '<ul class="list">' + replies.slice(0, 5).map(function (r) {
      var lab = r.label === null ? '<span class="tag warn">not assessed yet</span>' :
        r.label === "unknown" ? '<span class="tag unk">unclear: needs a look</span>' : '<span class="tag ok">' + esc(r.label) + "</span>";
      var name = r.company || "Lead " + r.id + " (no company name)";
      return item({ key: "lead", id: r.id, title: name }, lab + esc(name), r.when ? "replied " + esc(r.when) : "reply time unknown");
    }).join("") + "</ul>" : '<p class="empty">No replies to handle.</p>';

    var pl = problems.length ? '<ul class="list">' + problems.slice(0, 5).map(function (f) {
      var page = f.subject ? { key: "subject", id: f.id, title: f.subjectTitle } : { key: "operations", title: "failure " + f.id };
      var where = f.subject ? "open subject" : "no page for its subject: open Runs & operations";
      var sev = f.severity === "critical" ? '<span class="tag crit">critical</span>' : '<span class="tag warn">warning</span>';
      return item(page, sev + esc(f.cls), esc(f.msg) + " · " + esc(f.when) + " · " + where);
    }).join("") + "</ul><button class=\"linkbtn\" type=\"button\"" + ref({ key: "operations" }) + ">Acknowledge and resolve on Runs &amp; operations</button>" :
      '<p class="empty">No open problems.</p>';

    h += '<div class="grid2">' + card("Drafts awaiting review", "REQ-A-3", dl) + card("Replies to handle", "REQ-A-4", rl, "sec-replies") + "</div>";
    h += card("Problems", "REQ-A-5", pl, "sec-problems");

    var rs = runs.length ? '<dl class="kv"><dt>Queued or running</dt><dd>' + activeRuns(runs) + "</dd><dt>Stopped in the 24 hours before " + hhmm(now) +
      "</dt><dd>" + stoppedIn24h(runs, now) + '</dd></dl><ul class="list">' + runs.slice(0, 5).map(function (r) {
        var t = r.status === "succeeded" ? "ok" : r.status === "running" ? "unk" : "warn";
        return item({ key: "run", id: r.id, title: r.lead }, '<span class="tag ' + t + '">' + esc(r.status.replace("_", " ")) + "</span>" + esc(r.lead), esc(r.note));
      }).join("") + "</ul>" : '<p class="empty">No runs yet.</p>';

    var sends;
    if (!deliveries.length) {
      sends = '<p class="empty">No captured sends yet.</p>';
    } else {
      sends = '<dl class="kv">' + BUCKETS.map(function (bk) {
        var n = b.counts[bk.key];
        var label = bk.key === "deferred" && n ? "Deferred: next due " + hhmm(b.nextDue) + (b.lastDue !== b.nextDue ? ", last " + hhmm(b.lastDue) : "") : bk.label;
        return "<dt>" + label + "</dt><dd" + (bk.key === "unknown" ? ' class="unknown"' : "") + ">" + n + "</dd>";
      }).join("") + "<dt>Total</dt><dd>" + b.total + "</dd></dl>";
      if (b.counts.unknown) sends += "<button class=\"linkbtn\" type=\"button\"" + ref({ key: "operations", title: "unknown delivery outcomes" }) + ">Reconcile " + b.counts.unknown + " unknown outcome" + (b.counts.unknown === 1 ? "" : "s") + " on Runs &amp; operations</button>";
      sends += '<p class="note">A deferral that reaches its time is due, not sent: it still has to pass the send gate, which can defer it again or cancel it.</p>';
    }
    sends += '<p class="note">Local capture only: nothing is sent to a real inbox. Unknown outcomes are reconciled, never re-sent blindly.</p>';
    h += '<div class="grid2">' + card("Agent activity", "REQ-A-6", rs) + card("Captured sends", "REQ-A-7", sends) + "</div>";

    if (state.role === "admin") {
      var prov = state.provider === "fake" ? '<span class="tag ok">fake</span>Configured: fake model. In effect: fake model. No AI calls leave this machine.' :
        state.provider === "real" ? '<span class="tag warn">real</span>Configured: Claude CLI. In effect: Claude CLI on your login. Draft content goes to the model provider.' :
        '<span class="tag crit">refusing</span>Configured: Claude CLI. In effect: none. Calls are refused because earlier CLI work is not confirmed stopped. No model call was made.';
      var m = "<p>" + prov + '</p><dl class="kv"><dt>Model calls reserved today (UTC day, resets 18:00 MDT)</dt><dd>' + (empty ? 0 : EX.budget.reserved) + " of " + EX.budget.limit +
        "</dd><dt>Daily send cap</dt><dd>" + EX.budget.sendCap + "</dd></dl><button class=\"linkbtn\" type=\"button\"" + ref({ key: "admin" }) +
        ">See the full status on Admin</button><p class=\"note\">Admins only. Status only: nothing here or on Admin changes the model or the budget. They are set in the app's launch configuration, which only you change.</p>";
      h += card("Model and budget", "REQ-A-8", m);
    }

    var total = EX.pipeline.reduce(function (a, p) { return a + p.n; }, 0);
    var colors = ["var(--line)", "var(--accent)", "var(--ok)", "var(--owner)", "var(--warn)", "var(--muted)", "var(--bad)"];
    var pipe = empty ? '<p class="empty">No leads yet. Bring some in from the intake (a later slice) or the demo seed.</p>' :
      '<div class="pipe" aria-hidden="true">' + EX.pipeline.map(function (p, i) { return p.n ? '<i style="width:' + (p.n * 100 / total) + "%;background:" + colors[i] + '"></i>' : ""; }).join("") +
      '</div><div class="legend">' + EX.pipeline.map(function (p) { return "<span>" + esc(p.label) + " <b>" + p.n + "</b></span>"; }).join("") + '</div><p class="note">Fictional demo accounts.</p>';
    h += card("Lead pipeline", "REQ-A-9", pipe);
    return { html: h, refs: refs };
  }

  // The withheld state (REQ-A-10): nothing from an earlier load stays on screen.
  function renderWithheld(state) {
    var refs = [];
    function ref(page) { refs.push(page); return ' data-page-ref="' + (refs.length - 1) + '"'; }
    var html = '<div class="withheld" role="alert"><h2>This view could not be served</h2><p>' +
      (state.view === "refused" ? "A refresh was refused after the page had loaded. Everything shown before has been removed rather than left out of date." :
        "You are not allowed to see some of this data, or it could not be read. Nothing is shown rather than an incomplete picture.") +
      '</p><p><button class="linkbtn" type="button"' + ref({ key: "home" }) + '>Try again</button> · <button class="linkbtn" type="button"' + ref({ key: "operations" }) +
      ">Open Runs &amp; operations</button> (it applies its own access rules)</p></div>";
    return { html: html, refs: refs };
  }

  function renderPlaceholder(p) {
    var refs = [{ key: "home" }];
    var meta = PAGES[p.key];
    var html = '<div class="placeholder"><div class="eyebrow">Existing page · unchanged in slice A</div><h2>' + esc(meta[0]) + (p.title ? ": " + esc(p.title) : "") +
      '</h2><p class="muted">In the real app this opens <span class="mono">' + esc(meta[1]) + "</span>, which already exists. " + esc(PLACEHOLDER[p.key] || "") +
      ' Slice A adds no actions to it.</p><p><button class="linkbtn" type="button" data-page-ref="0">Back to Home</button></p></div>';
    return { html: html, refs: refs };
  }

  root.SliceAProto = {
    EX: EX, BUCKETS: BUCKETS, PAGES: PAGES, esc: esc, hhmm: hhmm,
    bucketOf: bucketOf, deliveryBuckets: deliveryBuckets, stoppedIn24h: stoppedIn24h, activeRuns: activeRuns,
    renderHome: renderHome, renderWithheld: renderWithheld, renderPlaceholder: renderPlaceholder
  };
})(typeof window !== "undefined" ? window : globalThis);
