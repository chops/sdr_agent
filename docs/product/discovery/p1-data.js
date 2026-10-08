// Content for docs/product/discovery/p1-review.html. The Markdown files in
// docs/product/ (brief.md, story-map.md, first-slice.md) are the canonical
// text; this file presents the same items with the same IDs for review.
// Bump meta.revision whenever the content changes, so owner notes stay bound
// to the revision they were written against.
window.P1 = {
  meta: {
    title: "Discovery packet (P1)",
    revision: "2026-10-08.1",
    gate: "G1 Brief approved",
    sources: ["docs/product/brief.md", "docs/product/story-map.md", "docs/product/first-slice.md", "docs/product/discovery/answers.md", "docs/product/discovery/review.md"]
  },

  oneLiner: "SDR Agent is a first-touch copilot that lets a solo founder turn a short list of target companies into researched, evidence-backed first emails they have personally approved, with a full record of how each one was made.",

  who: [
    { k: "User", v: "A solo founder or operator doing their own outbound. No team. Today that is you; on Nov 6, the workshop's solo founders, each running their own local copy." },
    { k: "Situation", v: "They have a product, an idea of who should buy it, a handful of target companies, and limited hours for outreach that must sound like them and be accurate." },
    { k: "Job", v: "\"When I sit down to do outbound, help me go from a list of companies to first emails I would actually send, quickly, without inventing facts or losing control of what goes out.\"" }
  ],

  outcomes: [
    { id: "OUT-1", t: "Prepared faster", d: "A reviewed first email for each target company in less time than by hand.", o: "Time from importing N companies to N approved drafts, compared with the founder's manual baseline (pending interview notes)." },
    { id: "OUT-2", t: "Credible", d: "Every factual claim in a draft points to evidence the founder can open.", o: "Share of draft sentences with citations; unsupported claims flagged before review." },
    { id: "OUT-3", t: "In control", d: "Nothing is captured for delivery without the founder approving that exact draft for that exact recipient.", o: "Approval binding enforced in the domain; refused stale approvals visible. Already true in the prototype." },
    { id: "OUT-4", t: "Sounds like them", d: "Drafts follow the campaign's brand guidelines and the founder's writing samples.", o: "Approval rate and size of the founder's edits per draft; tone and brand checks." },
    { id: "OUT-5", t: "Knows what happened", d: "The founder sees what the agent did, what it cost and what failed, and can recover without guessing.", o: "Home shows action queue, real or fake model, budget and unknown outcomes; every failure has a next step." },
    { id: "OUT-6", t: "Handles \"interested\"", d: "A positive reply produces a drafted response with the founder's booking link, for approval.", o: "A draft within one run; it never asserts specific free times." },
    { id: "OUT-7", t: "Runs privately", d: "Everything works on the founder's own machine, with their own model login and data.", o: "A fresh install reaches a first approved draft on fake data, then a real-model run on the founder's login." }
  ],

  nonGoals: [
    { id: "NG-1", t: "Sending real email, including to your own inbox", why: "Captured delivery only (your decision, Oct 8)." },
    { id: "NG-2", t: "Finding leads from an ICP", why: "An ICP gives no contact data or consent; needs a lawful source." },
    { id: "NG-3", t: "Bulk approval", why: "Needs per-draft binding, risk exclusion and partial-failure design." },
    { id: "NG-4", t: "Learning automatically from edits", why: "Must become proposed, accepted, versioned style changes." },
    { id: "NG-5", t: "AI suggestions while editing", why: "Later convenience; not core to trust." },
    { id: "NG-6", t: "Phone channel (call scripts and tasks)", why: "Email first." },
    { id: "NG-7", t: "Slack, Telegram, email-digest or desktop alerts", why: "Need a separate decision; alerts stay in the app." },
    { id: "NG-8", t: "Phone review and remote access", why: "Desktop only (your decision, Oct 8)." },
    { id: "NG-9", t: "Built-in scheduling or calendar access", why: "Booking link only." },
    { id: "NG-10", t: "Reply, meeting or pipeline metrics", why: "Not observable with captured delivery." },
    { id: "NG-11", t: "Real prospects' personal data", why: "Waits for HubSpot plus privacy, erasure and outreach-law decisions." },
    { id: "NG-12", t: "Multi-customer hosting", why: "Local personal app; design stays tenancy-ready." },
    { id: "NG-13", t: "Per-campaign model cost tiers and personalization depth settings", why: "One sensible default for the workshop." }
  ],

  assumptions: [
    { id: "AS-1", t: "A solo founder starts from a short list (5 to 20 companies), not a large database.", check: "Founder notes; your task walkthrough" },
    { id: "AS-2", t: "Evidence they can open builds more trust than a confident score.", check: "Prototype task test: are citations opened before approving?" },
    { id: "AS-3", t: "Reviewing one draft at a time is fine for 10 to 20 drafts.", check: "Prototype timing with you" },
    { id: "AS-4", t: "Brand guidelines plus pasted writing samples are enough to set the voice.", check: "Approval rate and edit size on your own campaign" },
    { id: "AS-5", t: "CSV and manual entry cover the workshop founders' lead sources.", check: "Founder notes; ask at the workshop" },
    { id: "AS-6", t: "Founders will bring their own Claude login and accept a local install.", check: "Install guide dry run; sign-up questions" },
    { id: "AS-7", t: "Captured (not sent) emails still make a convincing demo.", check: "Your judgment at G8; workshop feedback" }
  ],

  // status: built | partial | new | design (HubSpot design only)
  journey: [
    { id: "J-1", t: "Set up", tasks: [["Install, create the admin, sign in", "built"], ["Install guide", "new"], ["Check the model (real or fake)", "partial"], ["Booking link, sender, working hours", "new"], ["Paste writing samples", "new"]] },
    { id: "J-2", t: "Bring in leads", tasks: [["Upload a CSV with preview and checks", "new"], ["Add one lead by hand", "partial"], ["Show duplicates and suppressed contacts", "partial"], ["HubSpot import (optional add-on)", "design"]] },
    { id: "J-3", t: "Define the campaign", tasks: [["ICP criteria", "partial"], ["Brand guidelines and voice", "new"], ["Enroll leads", "partial"]] },
    { id: "J-4", t: "Research", tasks: [["Run research on a lead (fixture data)", "built"], ["Live web research, safe fetching, citations", "new"], ["Watch progress, cost and model", "built"]] },
    { id: "J-5", t: "Draft", tasks: [["Evidence-backed draft with citations and risk flags", "built"], ["Voice from guidelines and samples", "new"]] },
    { id: "J-6", t: "Review and approve", tasks: [["Review queue", "built"], ["One draft: recipient, revision, citations, risks", "built"], ["Edit (new revision)", "built"], ["Approve, bound to recipient and revision", "built"], ["Reject with a reason", "built"], ["Keyboard-driven queue", "new"]] },
    { id: "J-7", t: "Captured send", tasks: [["Quiet hours, quota and suppression checks", "built"], ["Captured message and outcome visible", "built"], ["Unknown outcomes with a safe next step", "partial"]] },
    { id: "J-8", t: "Replies", tasks: [["Reply classified", "built"], ["Interested reply handed to you", "built"], ["Drafted response with booking link", "new"]] },
    { id: "J-9", t: "Results", tasks: [["Counts: leads, drafts, approvals, captures", "built"], ["Time saved, approval rate, edit size, cost per draft", "new"]] }
  ],
  acrossJourney: [["Home and action queue", "partial"], ["Recover from failures", "built"], ["Audit trail and exports (Auditor)", "built"]],

  failures: [
    { id: "F-1", t: "CSV has bad rows or missing columns", where: "J-2", see: "Row-level errors before anything is created; fix and retry." },
    { id: "F-2", t: "A contact is a duplicate or suppressed", where: "J-2, J-7", see: "Shown and explained; never silently dropped or sent." },
    { id: "F-3", t: "Research finds too little evidence", where: "J-4, J-5", see: "\"Not enough evidence\" instead of a confident draft." },
    { id: "F-4", t: "Model budget runs out mid-batch", where: "J-4, J-5", see: "Clear stop: what finished, what did not, how to raise the budget." },
    { id: "F-5", t: "A model call fails or its outcome is unknown", where: "J-4, J-5", see: "Marked unknown, never retried blindly; a safe retry action." },
    { id: "F-6", t: "The draft changed while you were reviewing it", where: "J-6", see: "Approval refused, with what changed and a prompt to review again." },
    { id: "F-7", t: "You reject the same lead's draft twice", where: "J-6", see: "Option to stop drafting for this lead, reasons kept." },
    { id: "F-8", t: "Quiet hours or the daily quota defer a capture", where: "J-7", see: "Shown as deferred, with the time it will go." },
    { id: "F-9", t: "Capture outcome unknown after a crash", where: "J-7", see: "Unknown state with a safe resolve path; never a duplicate." },
    { id: "F-10", t: "A reply cannot be classified confidently", where: "J-8", see: "Handed to you as \"needs a look\", not guessed." },
    { id: "F-11", t: "A web page tries to instruct the model", where: "J-4", see: "Treated as untrusted text and flagged; the agent gains nothing." },
    { id: "F-12", t: "A research URL is unsafe or unreachable", where: "J-4", see: "Skipped with a reason; research continues." }
  ],

  slices: [
    { id: "A", t: "Operator shell and home", rec: true,
      what: "The new app frame (layout, navigation, the visual direction from the design days) and a home screen: what needs you now, what the agent is doing, real or fake model, budget and unknown outcomes.",
      under: "No domain change. Reads existing public functions as the signed-in person: Outreach.list_review_queue/1, Outreach.list_handoff_queue/1, Operations.list_attention/1, Agents.list_runs/1, AI.ModelProvider.Runtime.status/0.",
      value: "Every later screen lives in this frame, and home answers \"what do I do now?\".",
      risk: "Low for the domain. If the visual direction is not settled by Friday, the frame ships with provisional design tokens." },
    { id: "B", t: "Review workspace", rec: false,
      what: "A keyboard-driven queue and one draft at a time with its exact recipient, revision, cited evidence and risk flags; edit, reject with a reason, approve for capture.",
      under: "Screens only, over the existing edit_draft, approve/3 and reject/3 with their recipient and revision binding. Maybe one new read for next and previous draft.",
      value: "The trust moment of the product (OUT-2, OUT-3).",
      risk: "Medium. The security-sensitive screen: approval must stay bound to what is visible, and stale approvals must be refused clearly. More review rounds." },
    { id: "C", t: "CSV import", rec: false,
      what: "Upload, preview, validate, check duplicates and suppressed contacts, then create accounts, contacts and leads.",
      under: "A new way for data to enter: import action, row validation, row origin, duplicate rules, personal data in uploaded files.",
      value: "Needed for the workshop: founders must bring their own lists.",
      risk: "Higher. Needs an entity delta with independent PASS, a threat model and import tests. Too much to close by Friday night alongside the design days." }
  ],

  questions: [
    { id: "PQ-1", q: "Does the one-sentence promise say what you want founders to hear on Nov 6?" },
    { id: "PQ-2", q: "Which outcome matters most to you? Should any be cut or added?" },
    { id: "PQ-3", q: "Are any of the non-goals things you are not willing to leave out of the workshop?" },
    { id: "PQ-4", q: "For the home screen: what is the single most important thing it must show when you open the app?" },
    { id: "PQ-5", q: "If the visual direction is not settled by Friday night, may slice A ship with provisional design tokens?" }
  ]
};
