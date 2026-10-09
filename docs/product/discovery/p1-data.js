// Content for docs/product/discovery/p1-review.html. The Markdown files in
// docs/product/ (brief.md, story-map.md, first-slice.md) are the canonical
// text; this file presents the same items with the same IDs for review.
// Bump meta.revision whenever the content changes, so owner notes stay bound
// to the revision they were written against.
window.P1 = {
  meta: {
    title: "Discovery packet (P1)",
    revision: "2026-10-08.3",
    decisionPage: "https://claude.ai/artifact/CFjkoAnWbjncPksPRVmPe1",
    gate: "G1 Brief approved",
    sources: ["docs/product/brief.md", "docs/product/story-map.md", "docs/product/first-slice.md", "docs/product/discovery/answers.md", "docs/product/discovery/review.md"]
  },

  oneLiner: "SDR Agent is a first-touch copilot that lets a solo founder turn a short list of target companies into researched, evidence-backed first emails they have personally approved, with a full record of how each one was made.",

  who: [
    { k: "User", v: "A solo founder or operator doing their own outbound. No team. Today that is you." },
    { k: "Workshop", v: "On Nov 6 you give a live demo, then walk founders through the documented process of building it, missteps included. Attendees do not install or run it for the workshop (NG-16). The open-source repository and its build record are what they take away (OUT-8)." },
    { k: "Situation", v: "They have a product, an idea of who should buy it, a handful of target companies, and limited hours for outreach that must sound like them and be accurate." },
    { k: "Job", v: "\"When I sit down to do outbound, help me go from a list of companies to first emails I would actually send, quickly, without inventing facts or losing control of what goes out.\"" }
  ],

  outcomes: [
    { id: "OUT-1", t: "Prepared faster", d: "A reviewed first email for each target company with less of the founder's own time than by hand.", o: "Active founder time (not model or queue time) from loading N companies to N approved drafts, on matched tasks, against a measured manual baseline. A hypothesis until that baseline exists (pending your walkthrough or founder notes)." },
    { id: "OUT-2", t: "Credible", d: "Every factual claim in a draft points to evidence the founder can open.", o: "Factual-claim coverage: share of factual claims (not greetings or calls to action) with a citation, plus a sampled check that each source supports its claim in context. Unsupported claims flagged before review." },
    { id: "OUT-3", t: "In control", d: "Nothing is captured for delivery without the founder approving that exact draft for that exact recipient.", o: "Approval binding enforced in the domain; refused stale approvals visible. Already true in the prototype." },
    { id: "OUT-4", t: "Sounds like them", d: "Drafts follow the campaign's brand guidelines and the founder's writing samples.", o: "A tone and grounding rubric on sampled drafts plus observed review tasks. Approval rate and edit size are indicators only: they fall with better drafts but also with careless review, and rise for legitimate corrections." },
    { id: "OUT-5", t: "Knows what happened", d: "The founder sees what the agent did, what it used and what failed, and can recover without guessing.", o: "Home shows action queue, real or fake model, budget and unknown outcomes; every failure has a next step. Usage means recorded model calls and tokens, not dollars." },
    { id: "OUT-6", t: "Handles \"interested\"", d: "An interested reply produces a drafted response with the founder's booking link, for approval.", o: "In acceptance, a simulated, signed test reply classified as interested gets a draft within one run that never asserts specific free times. New work: today the prototype classifies and hands off only." },
    { id: "OUT-7", t: "Runs locally, described honestly", d: "The app and its data live on the founder's machine. With real inference on, permitted draft content goes to an external model provider through the proxy: local does not mean no data leaves.", o: "A fresh install from the repository guide, on a clean machine, reaches a first approved draft in fake-model mode on synthetic data. This is for readers of the open-source repository, not a workshop step (NG-16). A real-model run on anyone else's login is not a release criterion (NG-15)." },
    { id: "OUT-8", t: "The build story is documented", d: "Founders can follow how the product went from a one-shot demo to a working release, including what went wrong.", o: "The public repository holds, for every phase up to demo day, the journal with a retrospective per phase, the decision log, a gate record per gate, review findings and how each was handled, and an honest list of missteps. Checked at G8; nothing rewritten after the fact." }
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
    { id: "NG-11", t: "Real prospects' personal data", why: "Needs lawful-source, privacy, retention, erasure and outreach-law decisions. An optional HubSpot import does not by itself authorize real data." },
    { id: "NG-12", t: "Multi-customer hosting", why: "Local personal app; design stays tenancy-ready." },
    { id: "NG-13", t: "Per-campaign model cost tiers and personalization depth settings", why: "One sensible default for the workshop." },
    { id: "NG-14", t: "Attendees loading their own prospect lists", why: "Release constraint: synthetic or owner-provided test data only. Every intake path admits only reserved synthetic or owner test contacts." },
    { id: "NG-15", t: "Attendees using a real model on their own login, as a release promise", why: "ADR-0004 covers only your personal local use. Other people's use needs a reviewed provider, terms and budget decision first." },
    { id: "NG-16", t: "Attendees installing or running it for the workshop", why: "Your decision (shaping page, Oct 8): the workshop is a live demo plus the build story. An install guide still exists for readers of the open-source repository (OUT-7)." }
  ],

  assumptions: [
    { id: "AS-1", t: "A solo founder starts from a short list (5 to 20 companies), not a large database.", check: "Founder notes; your task walkthrough" },
    { id: "AS-2", t: "Evidence they can open builds more trust than a confident score.", check: "Prototype task test: are citations opened before approving?" },
    { id: "AS-3", t: "Reviewing one draft at a time is fine for 10 to 20 drafts.", check: "Prototype timing with you" },
    { id: "AS-4", t: "Brand guidelines plus pasted writing samples are enough to set the voice.", check: "Tone and grounding rubric on your own campaign, with approval rate and edit size as indicators" },
    { id: "AS-5", t: "One intake path (CSV upload or add-by-hand) plus the synthetic seed covers the workshop.", check: "Your choice at G2; founder notes" },
    { id: "AS-6", t: "Superseded Oct 8 by AS-8 (no attendee install): workshop founders are satisfied by your demo plus an optional fake-model install.", check: "Not checked; kept for history" },
    { id: "AS-7", t: "Captured (not sent) emails still make a convincing demo.", check: "Your judgment at G8; workshop feedback" },
    { id: "AS-8", t: "A live demo plus the documented build story, missteps included, is what workshop founders value most.", check: "Your judgment at G8; workshop feedback; which parts of the build record attendees open afterwards" }
  ],

  // status: built | partial | new | design (HubSpot design only)
  journey: [
    { id: "J-1", t: "Set up", tasks: [["Install, create the admin, sign in", "built"], ["Install guide", "new"], ["Check the model (real or fake)", "partial"], ["Sender, time zone, quiet hours (domain fields, no screen)", "partial"], ["Booking link", "new"], ["Paste writing samples", "new"]] },
    { id: "J-2", t: "Bring in leads", tasks: [["Synthetic seed (fallback)", "built"], ["Upload a CSV with preview and checks", "new"], ["Add one lead by hand", "new"], ["Show duplicates and suppressed contacts", "partial"], ["HubSpot import (optional add-on)", "design"]] },
    { id: "J-3", t: "Define the campaign", tasks: [["ICP criteria", "partial"], ["Brand guidelines and voice", "new"], ["Enroll leads", "partial"]] },
    { id: "J-4", t: "Research", tasks: [["Run research on a lead (fixture data)", "built"], ["Live web research, safe fetching, citations", "new"], ["Watch progress, usage (calls, tokens) and model", "built"]] },
    { id: "J-5", t: "Draft", tasks: [["Evidence-backed draft with citations and risk flags", "built"], ["Voice from guidelines and samples", "new"]] },
    { id: "J-6", t: "Review and approve", tasks: [["Review queue", "built"], ["One draft: recipient, revision, citations, risks", "built"], ["Edit (new revision)", "built"], ["Approve, bound to recipient and revision", "built"], ["Reject with a reason", "built"], ["Keyboard-driven queue", "new"]] },
    { id: "J-7", t: "Captured send", tasks: [["Quiet hours, quota and suppression checks", "built"], ["Captured message and outcome visible", "built"], ["Unknown outcomes with a safe next step", "partial"]] },
    { id: "J-8", t: "Replies", tasks: [["Reply classified", "built"], ["Interested reply handed to you", "built"], ["Drafted response with booking link (today: classify and hand off only)", "new"]] },
    { id: "J-9", t: "Results", tasks: [["Counts: leads, drafts, approvals, captures", "built"], ["Active time, approval rate, edit size, usage per draft (indicators)", "new"]] }
  ],
  acrossJourney: [["Home and action queue", "partial"], ["Recover from failures", "built"], ["Audit trail and exports (Auditor)", "built"]],

  failures: [
    { id: "F-1", t: "CSV has bad rows or missing columns", where: "J-2", see: "Row-level errors before anything is created; fix and retry." },
    { id: "F-2", t: "A contact is a duplicate or suppressed", where: "J-2, J-7", see: "Shown and explained; never silently dropped or sent." },
    { id: "F-3", t: "Research finds too little evidence", where: "J-4, J-5", see: "\"Not enough evidence\" instead of a confident draft." },
    { id: "F-4", t: "Model budget runs out mid-batch", where: "J-4, J-5", see: "Clear stop: what finished and what did not. Only you can raise the budget, within reviewed hard caps; nothing raises it automatically." },
    { id: "F-5", t: "A model call fails or is refused", where: "J-4, J-5", see: "Shown as failed or refused with the reason; a retry only where repeating is safe." },
    { id: "F-6", t: "The draft changed while you were reviewing it", where: "J-6", see: "Approval refused, with what changed and a prompt to review again." },
    { id: "F-7", t: "You reject the same lead's draft twice", where: "J-6", see: "Proposed, not in the prototype: option to stop drafting for this lead, reasons kept." },
    { id: "F-8", t: "Quiet hours or the daily quota defer a capture", where: "J-7", see: "Shown as deferred, with the time it will go." },
    { id: "F-9", t: "Capture outcome unknown after a crash", where: "J-7", see: "Unknown state with a safe resolve path; never a duplicate." },
    { id: "F-10", t: "A reply cannot be classified confidently", where: "J-8", see: "Handed to you as \"needs a look\", not guessed." },
    { id: "F-11", t: "A web page tries to instruct the model", where: "J-4", see: "Treated as untrusted text and flagged; the agent gains nothing." },
    { id: "F-12", t: "A research URL is unsafe or unreachable", where: "J-4", see: "Skipped with a reason; research continues." },
    { id: "F-13", t: "A model call's outcome is unknown", where: "J-4, J-5", see: "Shown as unknown, never as failed or succeeded; resolved by reconciliation, retried only where the contract says a repeat is safe." }
  ],

  slices: [
    { id: "A", t: "Operator shell and home (read-only triage starter)", rec: true,
      what: "The new app frame (layout, navigation, the visual direction from the design days) and a home screen: what needs you now, what the agent is doing, real or fake model, budget and unknown outcomes.",
      under: "No domain change. Reads existing public functions as the signed-in person: Outreach.list_review_queue/1, Outreach.list_handoff_queue/1, Operations.list_attention/1, Agents.list_runs/1, AI.ModelProvider.Runtime.status/0.",
      value: "Every later screen lives in this frame. Home answers \"what do I do now?\": you find the right draft or problem and reach the existing safe action. It does not deliver OUT-1 on its own.",
      risk: "Low for the domain only if it stays read-only: no new write, retry or budget actions. Provisional design tokens are your choice (PQ-5), not an automatic fallback past G3." },
    { id: "B", t: "Review workspace", rec: false,
      what: "A keyboard-driven queue and one draft at a time with its exact recipient, revision, cited evidence and risk flags; edit, reject with a reason, approve for capture.",
      under: "Screens only, over the existing edit_draft, approve/3 and reject/3 with their recipient and revision binding. A possible new read (next and previous draft) triggers an entity-delta evaluation.",
      value: "The trust moment of the product (OUT-2, OUT-3).",
      risk: "Medium. The security-sensitive screen: approval must stay bound to what is visible, and stale approvals must be refused clearly. More review rounds." },
    { id: "C", t: "CSV import (or add-by-hand, whichever intake you choose)", rec: false,
      what: "Upload, preview, validate, check duplicates and suppressed contacts, then create accounts, contacts and leads. Reserved synthetic or owner test contacts only (NG-14).",
      under: "A new way for data to enter: import action, row validation, row origin, duplicate, idempotency and partial-failure rules, bounded uploads, URL threats, what stays in the audit trail.",
      value: "The workshop core needs one intake path. This turns fixtures into a usable input → draft → review → capture journey. Not for attendees' real prospect lists.",
      risk: "Higher. Needs an entity delta with independent PASS, a threat model and import tests. Too much to close by Friday night alongside the design days." }
  ],

  // Your own feature vision is the primary input (shaping page, Oct 8); founder
  // evidence supports it. Captured on the owner decisions page, section F.
  featureVision: "You already know what the MVP should do and which premium features could follow. In your words: \"i have a pretty good idea of what i want the MVP to do, as well as what premium features we could release post-MVP.\" The must-list starts from your list on the owner decisions page; this packet is our draft to check against it.",

  // Domain-driven design: the Ash domains are the bounded contexts.
  ddd: {
    contexts: [
      { id: "BC-1", t: "Sales", d: "Who is targeted, against which profile, through which program", r: "IcpDefinition, Account, Contact, Lead, Campaign, Sequence, SequenceStep, CampaignEnrollment" },
      { id: "BC-2", t: "Research", d: "The evidence gathered about a lead and the qualification resting on it", r: "ResearchArtifact, EvidenceClaim, Qualification, QualificationEvidence" },
      { id: "BC-3", t: "Outreach", d: "What may be sent, to whom, on whose authority, and who must never be contacted", r: "Draft, DraftRevision, RevisionCitation, Approval, Suppression, DeliveryOperation, DeliveryReceipt, SendQuotaDay, Reply, ReplyAssessment" },
      { id: "BC-4", t: "Agents", d: "Agent provenance: which agent ran, its model calls and decisions", r: "AgentDefinition, AgentRun, ModelInvocation, ToolInvocation, Decision, WireWitnessLink" },
      { id: "BC-5", t: "Operations", d: "Durable background work as you see it, and failures that need a human", r: "Operation, Failure, WebhookEvent" },
      { id: "BC-6", t: "Accounts", d: "Operator identity, sign-in and roles", r: "User, Token" },
      { id: "BC-7", t: "Audit", d: "The system of record: hash-chained events, payloads, anchors, exports and audited access", r: "AuditEvent, Payload, AuditAccess, AuditAnchor, AuditExport and supporting resources" }
    ],
    glossary: [
      ["Lead", "A target contact at a target account, in the pipeline"],
      ["Campaign", "A program with an ICP, voice, sender, time zone and quiet hours"],
      ["Evidence claim", "A fact found during research, with its source"],
      ["Draft / revision", "A first email; every edit makes a new revision"],
      ["Citation", "The link from a sentence in a draft to its evidence"],
      ["Approval", "Your consent to capture one exact revision for one exact recipient"],
      ["Suppression", "A rule that a contact must never be contacted"],
      ["Delivery (outbox entry)", "One approved email on its way to capture; never sent to a real person"],
      ["Capture", "Storing the exact email the app would have sent, instead of sending it"],
      ["Handoff", "An interested or unclear reply passed to you"],
      ["Agent run", "One piece of agent work on a lead, with its model calls and decisions"],
      ["Unknown outcome", "A step whose result could not be confirmed; resolved by reconciliation, never a blind retry"],
      ["Failure", "Something that needs a human, shown on the operations screen"]
    ]
  },

  questions: [
    { id: "PQ-1", q: "Does the one-sentence promise say what you want founders to hear on Nov 6?" },
    { id: "PQ-2", q: "Which outcome matters most to you? Should any be cut or added?" },
    { id: "PQ-3", q: "Are any of the non-goals things you are not willing to leave out of the workshop?" },
    { id: "PQ-4", q: "For the home screen: what is the single most important thing it must show when you open the app?" },
    { id: "PQ-5", q: "If the visual direction is not settled by Friday night, may slice A ship with provisional design tokens?" },
    { id: "PQ-6", q: "Founder evidence: will you paste the notes and their kind, or walk through your own routine and accept the evidence limit in the brief?" },
    { id: "PQ-7", q: "For the workshop core, which intake path: CSV upload or add-by-hand? (Decided at G2; an early view helps.)" }
  ]
};
