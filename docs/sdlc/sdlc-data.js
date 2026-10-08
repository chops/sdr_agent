// Source data for docs/sdlc/index.html (the interactive SDLC map).
// This file is the detailed, versioned record of the process: phases, gates,
// packets, roles and status. Claude updates it as work moves; every change is
// reviewed and committed like code. Bump meta.revision on every change: owner
// notes exported from the map carry it, plus a fingerprint of this data.
// Status values:
//   phases:  done | active | next | planned
//   packets: done | draft | review | todo
// People ids: owner, claude, codex, outside.
window.SDLC = {
  meta: {
    product: "SDR Agent",
    version: "v1.0 (G0 passed)",
    revision: "2026-10-08.4",
    updated: "2026-10-08",
    workdays: "Seven days a week (your answer to Q1 and Q5). Dates are calendar days and targets, not commitments.",
    milestones: [
      { id: "code-complete", label: "Release candidate target, dog-fooding starts", date: "2026-10-30" },
      { id: "workshop", label: "Solo-founder workshop", date: "2026-11-06" }
    ]
  },

  people: {
    owner: { name: "Charles", label: "You (owner)", blurb: "Founder, product owner, design lead and customer zero. Approves every gate and is accountable for security, architecture, data, release and anything run on your machine." },
    claude: { name: "Claude", label: "Claude", blurb: "Product manager, designer, tech lead and delivery manager. Drafts most packets, coordinates the build, reviews anything Codex authors." },
    codex: { name: "Codex", label: "Codex", blurb: "Architect, security, QA and compliance reviewer. Reviews everything Claude authors and builds the slices it is assigned." },
    outside: { name: "Outside help", label: "Outside help", blurb: "People we do not have yet: solo founders as design partners, and legal counsel before any real prospect." }
  },

  // How every packet and pull request moves through the process.
  flow: [
    { step: "Draft", who: ["claude", "codex"], text: "The author writes it in the repo on its own branch. Usually Claude; Codex authors the slices and reports it is assigned." },
    { step: "Independent review", who: ["codex", "claude"], text: "The other agent reviews in writing and returns a verdict with severity-ranked findings. Codex reviews Claude's work; Claude reviews Codex's." },
    { step: "Revise and re-review", who: ["claude", "codex"], text: "The author addresses every finding. Any material change goes back to the same reviewer until no blocking finding is left. Only typo or formatting fixes skip re-review, and the gate record says so." },
    { step: "Owner review", who: ["owner"], text: "You read or click through it and leave notes in chat or on the interactive page. A note that changes substance sends it back to step 3." },
    { step: "Approve and record", who: ["owner", "claude"], text: "You approve in chat. Claude writes the gate record (exact commits, evidence, findings and how each was settled, your approval with its time) and the PR merges on green CI for that exact commit." }
  ],

  // A gate passes only when its record is committed in docs/sdlc/gates/.
  gateRecord: {
    path: "docs/sdlc/gates/",
    fields: [
      "Gate id and status: open, passed, passed with exceptions, or failed.",
      "Exact artifact revisions: commit SHA and file paths reviewed.",
      "Evidence: CI run for that exact commit, test, eval and review reports.",
      "Reviewer, verdict, and what happened to each finding: fixed, deferred with a reason, or decided by you.",
      "Thresholds the gate binds: metric targets, bug severities, budget limits.",
      "Your approval: your words, the time with time zone, and where you gave it.",
      "Exceptions granted, each with its scope and an expiry.",
      "The next scope this gate authorizes, and nothing more."
    ],
    rules: [
      "A date never passes a gate. Only a committed gate record with your approval does.",
      "Drafting may start from unapproved inputs, but a phase cannot be approved until its inputs are. If an input changes later, the work built on it is revised and reviewed again.",
      "You decide disagreements between Claude and Codex. Your decision does not waive an unresolved security blocker: that needs a fix, or a written exception with scope and expiry backed by a recorded, independent security review of the exception and its mitigation, with a written disposition of the finding. If that review still finds it blocking, the gate stays blocked. Constraints that cannot be waived cannot be excepted at all.",
      "G0 passed on Oct 8: you accepted the product-phase charter (ADR-0014), which now governs product-phase work in place of the unattended-build charter (ADR-0001).",
      "A gate can pass for a named scope, such as the first build slice. Later scope passes the same gate again with its own record.",
      "Only explicit approval of G5 lifts the feature freeze.",
      "Process and hardening work may continue during the freeze, but it grants no new authority: no deployments, credentials, real model calls or changes to your machine."
    ]
  },

  // In force until the owner accepts an ADR that amends them.
  constraints: [
    "Captured delivery only. No code path may reach a real recipient or a real inbox.",
    "Every approval is bound to the exact recipient and draft revision shown to the reviewer.",
    "Suppression is checked before every delivery and cannot be bypassed.",
    "No secret in git, logs, chat, process arguments or environment dumps. OAuth tokens are never copied.",
    "The real model runs only through the locked-down Claude CLI on your own login, for personal local use, with no tools and a per-call check.",
    "The audit trail is append-only and is never edited or bypassed.",
    "Synthetic or owner-provided test data only. No real prospect data in this release."
  ],

  severities: [
    { id: "P0", text: "Breaks a constraint above, loses or corrupts data, or blocks the core journey with no workaround." },
    { id: "P1", text: "Breaks the core journey but a workaround exists, or shows the operator a wrong result." },
    { id: "P2", text: "Degrades something outside the core journey." },
    { id: "P3", text: "Cosmetic." }
  ],

  // Stable IDs link each requirement to its design, slice, test and evidence.
  traceability: [
    { id: "REQ-nn", name: "Requirement", where: "K3" },
    { id: "J-nn / S-nn", name: "Journey step and screen", where: "K4" },
    { id: "SL-nn", name: "Build slice", where: "K6" },
    { id: "T-nn / EV-nn", name: "Test or eval", where: "K5, K7" },
    { id: "EVD-nn", name: "Release evidence", where: "K7" }
  ],

  schedule: {
    assumptions: [
      "Dates are calendar days, seven days a week (your answers to Q1 and Q5). Every date is a target; only a gate record passes a gate.",
      "Oct 8 and 9 are design days. Building starts Saturday Oct 10 with one narrow first slice, once G1 to G5 have passed for that slice. The rest of the must-list is planned in parallel, and each later slice passes its own gates.",
      "The build window, Oct 10 to 28, has 19 calendar days. That is available time, not capacity: review, CI, rework and rest come out of it.",
      "Oct 30 is a target until G5 approves a plan that reaches it. Oct 29 and 30 are planned verification days (P7), not buffer. The Oct 22 scope-cut checkpoint is the protection.",
      "Your review time and Codex's serial review queue are the critical path, not drafting."
    ],
    controls: [
      { name: "Work in progress", text: "One deep Codex review at a time. At most two build slices in flight." },
      { name: "Rework", text: "Plan for two review rounds per packet, and two to four for slices touching security, data or transactions." },
      { name: "Owner review windows", text: "On the design days, Oct 8 and 9, you review in short rounds every couple of hours. Claude brings one set of decisions at a time, with options side by side. During the build, you review the same day." },
      { name: "Response time", text: "Codex reviews in gate order, one deep review at a time. Nobody counts the number of drafting agents as review capacity." },
      { name: "Rest and stop-work", text: "Seven-day weeks do not mean continuous work. Anyone can call a stop for fatigue, a failed gate, a missing decision or a spent budget. The plan slips rather than a gate being skipped." },
      { name: "Scope-cut trigger", text: "If fewer than half of the must slices are merged by Oct 22, or the critical path passes Oct 28, we cut to the minimum core journey listed at G2. No silent slips." },
      { name: "Workshop fallback", text: "Run the workshop on the last approved release tag with the fake model and synthetic data, with a rehearsed walkthrough as backup. Decided before Nov 5, so no last-minute live patch is ever needed." }
    ]
  },

  changeControl: [
    "Request: anyone can raise one after G2, in chat or as a note.",
    "Impact: Claude writes what it changes in the experience, data, authority, budget and schedule.",
    "Review: the other agent reviews the impact.",
    "Decision: you accept, defer or reject. A request never silently reopens a locked gate or widens captured-only, synthetic-data or local-only scope.",
    "Update: affected packets, tests and gate records are revised and reviewed again."
  ],

  publication: [
    "The repository is public. Committing or pushing is publishing, and deleting later does not take it back.",
    "Never in git: credentials, keys, tokens, prospect or contact data, private interview notes, raw chat transcripts.",
    "You consented to quoting your own words: the original prompt and its slogan, your discovery answers and chat messages (D-013, D-018). That consent does not cover anything written by others, such as a founder's notes, or raw transcripts.",
    "Design-partner notes need their consent, stay private, and only sanitized findings go in git.",
    "Session handoffs and agent working reports stay private unless sanitized for publication.",
    "When unsure, keep it private and ask."
  ],

  // Who would do this on a traditional product team, and who does it here.
  roles: [
    { role: "Founder / product owner", does: "Sets the vision, owns priorities, accepts or rejects every gate.", playedBy: ["owner"], accountable: "owner" },
    { role: "Product manager", does: "Runs discovery, writes the brief and requirements, keeps scope honest.", playedBy: ["claude", "owner"], accountable: "owner", note: "Claude drafts; you decide." },
    { role: "UX researcher", does: "Plans and runs interviews and usability tests with real users.", playedBy: ["claude", "outside"], accountable: "owner", gap: true, note: "Claude writes the test scripts. Without design partners, validation is owner-only and recorded as limited." },
    { role: "Product designer", does: "Journeys, wireframes, visual design, design system, prototype.", playedBy: ["claude", "owner", "codex"], accountable: "owner", note: "Claude drafts, you set the visual direction, Codex critiques states and accessibility." },
    { role: "Tech lead / architect", does: "Technical design, ADRs, sequencing, code quality.", playedBy: ["claude", "codex"], accountable: "owner", note: "You accept every ADR." },
    { role: "Software engineers", does: "Build and test the slices.", playedBy: ["claude", "codex"], accountable: "owner", note: "Each slice is reviewed by the agent that did not write it." },
    { role: "AI / evaluation engineer", does: "Agent behaviour spec, prompts, evals, red-teaming.", playedBy: ["claude", "codex"], accountable: "owner", note: "Real model calls need a budget you approve. The current budget is zero." },
    { role: "Eval dataset steward", does: "Curates the golden and adversarial eval sets and keeps them synthetic.", playedBy: ["claude", "codex"], accountable: "owner", note: "Claude curates the golden set, Codex the adversarial set. Any real data needs your approval first." },
    { role: "QA engineer", does: "Test strategy, acceptance tests, exploratory testing, bug triage.", playedBy: ["codex", "owner"], accountable: "owner", note: "Codex leads test strategy; you do exploratory testing while dog-fooding." },
    { role: "Security engineer", does: "Threat model, security review, exceptions.", playedBy: ["codex", "claude"], accountable: "owner", note: "Codex reviews Claude's work; Claude reviews Codex's. Only you grant an exception." },
    { role: "Data, privacy and publication owner", does: "Decides what data the product may hold and what may be published.", playedBy: ["owner", "claude"], accountable: "owner", note: "Claude keeps the publication policy and redacts; you decide." },
    { role: "Privacy and legal counsel", does: "Outreach law (CAN-SPAM, CASL), privacy, vendor terms.", playedBy: ["outside"], accountable: "owner", gap: true, note: "No counsel yet. Agents flag risk but give no legal advice. No real prospect is contacted until you consult counsel or accept the risk in writing." },
    { role: "Release and configuration manager", does: "Versions, tags, configuration, release notes.", playedBy: ["claude"], accountable: "owner", note: "Claude prepares; you approve every release and run any step on your machine." },
    { role: "DevOps / SRE", does: "Environments, observability, runbooks.", playedBy: ["claude", "codex"], accountable: "owner", note: "Local only. Agents have no unattended sudo or deployment authority." },
    { role: "Backup and restore", does: "Backup procedure, tested restore.", playedBy: ["claude", "owner"], accountable: "owner", note: "Claude writes and tests the procedure; you run it on your machine." },
    { role: "Support and incident triage", does: "Takes bug reports, triages, follows up.", playedBy: ["claude", "codex", "owner"], accountable: "owner", note: "During dog-fooding and after the workshop, Claude triages within two working days and Codex reviews fixes." },
    { role: "Delivery manager", does: "Plan, cadence, status, risks, gate records.", playedBy: ["claude"], accountable: "owner" },
    { role: "Technical writer / DevRel", does: "README, install guide, workshop material, open-source files.", playedBy: ["claude", "owner"], accountable: "owner", note: "You present at the workshop." },
    { role: "Customers / design partners", does: "Use the product and tell us what is wrong with it.", playedBy: ["owner", "outside"], accountable: "owner", gap: true, note: "You are customer zero. Workshop founders are the first real users." }
  ],

  phases: [
    {
      id: "P0", name: "Prototype and inception", start: "2026-10-06", end: "2026-10-08", status: "done",
      goal: "Take stock of what the one-shot build produced and agree how we will work from here.",
      traditional: "A team inheriting a hackathon prototype holds a kickoff: what is real, what is demo-only, who decides what, and how work will flow. The output is a charter and a process everyone signs.",
      ownerTime: "About 1 hour: read the playbook and this map, answer the open questions, accept or reject the charter.",
      activities: [
        { text: "Unattended MVP build from the pasted architecture prompt (done Oct 6 to 7).", who: ["claude", "codex"] },
        { text: "Meetup demo and post-demo hardening (done Oct 7).", who: ["owner", "claude", "codex"] },
        { text: "Map the traditional SDLC onto one founder and two agents.", who: ["claude"] },
        { text: "Review the process; changes requested and made (v0.2).", who: ["codex", "claude"] },
        { text: "Prototype assessment: verified, reported and proposed capabilities, and known debt.", who: ["claude"] },
        { text: "Product-phase charter (ADR-0014) that would supersede the unattended-build mandate.", who: ["claude", "codex"] },
        { text: "Accept the process and the charter (done Oct 8: G0 passed).", who: ["owner"] }
      ],
      packet: {
        id: "K1", name: "Charter and process", path: "docs/sdlc/, docs/adr/0014-product-phase-charter.md", status: "done", author: "claude", reviewer: "codex",
        contents: ["Playbook and this map", "Gate-record template", "Decision log", "Journal", "Prototype assessment (not done at G0; folded into the K5 gap analysis)", "ADR-0014 product-phase charter (accepted)", "G0 gate record"]
      },
      gate: {
        id: "G0", name: "Process agreed", approver: "owner",
        criteria: [
          "You explicitly accept ADR-0014, or the old charter stays in force.",
          "Codex has re-reviewed this revision and no blocking finding is open.",
          "Open questions on schedule, design partners, review channel and publication are answered.",
          "The G0 gate record is committed."
        ]
      }
    },
    {
      id: "P1", name: "Discovery", start: "2026-10-08", end: "2026-10-09", status: "active",
      goal: "Agree who the product is for, what problem it solves for them, and what success at the workshop means.",
      traditional: "The PM and a researcher interview target users, study competitors and write a short product brief. Nobody designs or builds until the brief is signed.",
      ownerTime: "Short review rounds on the design days. Share your founder-conversation notes; the questionnaire is already done.",
      activities: [
        { text: "Discovery questionnaire answered (done Oct 7).", who: ["owner"] },
        { text: "Joint review of the answers; four scope decisions taken (done Oct 8).", who: ["claude", "codex", "owner"] },
        { text: "Method step 1, outcomes and today's workflow: the job a solo founder hires this for, the benefit, and how they do outbound today, drawn from your answers and your notes from one founder conversation.", who: ["claude", "owner"] },
        { text: "Method step 2, story map: the core tasks in order, the smallest complete slice (the candidate first build slice), later paths, and failure cases.", who: ["claude"] },
        { text: "Alternatives scan, timeboxed to two hours: only what the first-touch journey needs from Apollo, Outreach and HubSpot.", who: ["claude"] },
        { text: "Assumptions and risks: what must be true, and how we would find out.", who: ["claude", "codex"] },
        { text: "Brief: promise, user, problem, observable workshop success, non-goals.", who: ["claude"] },
        { text: "Review the packet for overclaiming and missing risks.", who: ["codex"] },
        { text: "Approve the brief.", who: ["owner"] }
      ],
      packet: {
        id: "K2", name: "Brief and discovery", path: "docs/product/discovery/, docs/product/brief.md", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Questionnaire and your answers (you consented to quoting them, D-018)", "Joint answer review", "Founder-conversation evidence, sanitized and labelled by type", "Outcome brief: job, benefit, today's workflow", "Story map with the first-slice candidate", "Alternatives scan", "Assumptions and risks", "Observable success measures and non-goals"]
      },
      gate: {
        id: "G1", name: "Brief approved", approver: "owner",
        criteria: [
          "The workshop promise fits in one sentence and you agree with it.",
          "Success measures can actually be observed by Nov 6.",
          "Non-goals are written down.",
          "Independent review has no open blocking finding, and the gate record is committed."
        ]
      }
    },
    {
      id: "P2", name: "Definition", start: "2026-10-09", end: "2026-10-12", status: "planned",
      goal: "Turn the brief into requirements precise enough to design, build and test against.",
      traditional: "The PM writes requirements with acceptance criteria; engineering adds non-functional requirements; an ML team writes the behaviour spec and eval plan; legal reviews data handling.",
      ownerTime: "Short rounds on Oct 9 for the first slice, then about 2 hours for the rest of the must-list.",
      activities: [
        { text: "Method step 3, service blueprint and light event storming: swimlanes for you, the agent, the system and outside services, with events, rules and who decides.", who: ["claude", "owner", "codex"] },
        { text: "Method step 4 (draft), screen, action and state matrix, so requirements are concrete.", who: ["claude"] },
        { text: "Requirements with stable REQ ids, ranked must, should and later, each must with acceptance criteria. The first slice's requirements are settled first (Oct 9).", who: ["claude"] },
        { text: "Non-functional requirements, with security and accessibility starting here, not at the end.", who: ["claude", "codex"] },
        { text: "Agent behaviour spec: hard limits, voice, evidence rules, failure and recovery behaviour.", who: ["claude"] },
        { text: "Eval plan and synthetic eval sets: golden leads, rubric, prompt-injection set.", who: ["claude", "codex"] },
        { text: "Compliance desk review: CAN-SPAM, CASL, privacy, vendor terms. Flags, not legal advice.", who: ["codex"] },
        { text: "Minimum core journey: the cut list used if the scope-cut trigger fires.", who: ["claude", "owner"] },
        { text: "Approve requirements; this locks the workshop scope and starts change control.", who: ["owner"] }
      ],
      packet: {
        id: "K3", name: "Requirements, behaviour and evals", path: "docs/product/requirements/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Requirements (REQ ids) with acceptance criteria", "Non-functional requirements", "Agent behaviour spec", "Eval plan and synthetic eval sets", "Compliance flags and how each is handled", "Minimum core journey (cut list)"]
      },
      gate: {
        id: "G2", name: "Scope locked", approver: "owner",
        criteria: [
          "Every must has acceptance criteria a stranger could test.",
          "Eval thresholds are written into the gate record.",
          "Every compliance flag is resolved, deferred with a reason, or accepted by you. Constraints above cannot be accepted away.",
          "The minimum core journey is agreed.",
          "Independent review has no open blocking finding."
        ]
      }
    },
    {
      id: "P3", name: "UX design", start: "2026-10-08", end: "2026-10-13", status: "planned",
      goal: "Decide what the SDR control plane looks like and how an operator moves through it, then prove it with one prototype.",
      traditional: "A designer maps journeys, sketches wireframes, holds critiques, sets the visual language, builds a clickable prototype and tests it with real users before engineering starts.",
      ownerTime: "The design days, Oct 8 and 9, plus about 1 hour for each later prototype test.",
      activities: [
        { text: "Method step 4 (final), screen, action and state matrix with J and S ids, revised once G2 passes for that scope.", who: ["claude"] },
        { text: "Every screen's empty, loading, error and unknown-outcome states.", who: ["claude"] },
        { text: "Critique: missing states, accessibility, safety of approval actions.", who: ["codex", "owner"] },
        { text: "Method step 5, low-fidelity clickable prototype of the core journey, tested on real tasks.", who: ["claude", "owner"] },
        { text: "Design days (Oct 8 and 9): your colours and fonts, two or three directions, pick one.", who: ["owner", "claude"] },
        { text: "Usability: your task walkthrough, plus what your one founder conversation shows. You chose not to recruit more testers; findings record that limit.", who: ["owner", "claude"] },
        { text: "Approve the prototype.", who: ["owner"] }
      ],
      packet: {
        id: "K4", name: "UX prototype and state map", path: "docs/product/design/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Journey and state map (J and S ids)", "One clickable prototype", "Appendix: visual direction from the design day", "Appendix: design tokens", "Usability and accessibility findings"]
      },
      gate: {
        id: "G3", name: "Prototype approved", approver: "owner",
        criteria: [
          "You can complete the core journey in the prototype without help.",
          "Every screen has its empty, loading, error and unknown states designed.",
          "Approval screens show the exact recipient, revision and evidence being approved.",
          "Usability findings are fixed or logged with a decision, and their limits are recorded."
        ]
      }
    },
    {
      id: "P4", name: "Technical design", start: "2026-10-09", end: "2026-10-13", status: "planned",
      goal: "Work out how to change the existing system to deliver the approved requirements and design safely.",
      traditional: "Engineering writes a design doc against the requirements, records architecture decisions, threat-models new surfaces, and agrees a test strategy before sprint planning.",
      ownerTime: "About 1 hour: accept or reject ADRs and any exception.",
      activities: [
        { text: "Method step 6, technical fit: map each action and event to its owner in the existing stack, with feasibility notes from step 3 onward.", who: ["claude", "codex"] },
        { text: "Gap analysis: what exists, what changes, what is new, per REQ id.", who: ["claude"] },
        { text: "Technical plan with the entity-model delta inline; separate ADRs only where warranted.", who: ["claude"] },
        { text: "Threat model for new surfaces: live web research, CSV import, optional HubSpot.", who: ["codex"] },
        { text: "Test traceability: every REQ maps to a T or EV id.", who: ["codex", "claude"] },
        { text: "Independent review of the plan and an independent PASS on the entity delta.", who: ["codex", "claude"] },
        { text: "Accept ADRs and exceptions.", who: ["owner"] }
      ],
      packet: {
        id: "K5", name: "Technical plan", path: "docs/product/tech/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Gap analysis", "Technical plan with inline entity delta", "Threat model", "Test and eval traceability", "ADRs where warranted"]
      },
      gate: {
        id: "G4", name: "Design reviewed", approver: "owner",
        criteria: [
          "Every must REQ has a design and a planned test.",
          "Every new external surface has a threat and a mitigation.",
          "The entity delta has a PASS from an independent reviewer (Codex for Claude's work, Claude for Codex's).",
          "No ADR is pending your decision."
        ]
      }
    },
    {
      id: "P5", name: "Release planning", start: "2026-10-09", end: "2026-10-13", status: "planned",
      goal: "Sequence the work into slices that fit the time we really have, and define release readiness before building.",
      traditional: "Sprint zero: break the work into stories, estimate, map dependencies, set milestones, write the definition of done and the release criteria.",
      ownerTime: "About 1 hour per scope: approve the plan for the first slice by Oct 9, then for the rest. Only this approval lifts the feature freeze, and only for the approved scope.",
      activities: [
        { text: "Slices with SL ids traced to REQ ids, estimates including review rounds, and dependencies.", who: ["claude", "codex"] },
        { text: "Method step 7, traceability walkthrough: every must traced from requirement to screen, action, boundary, test and evidence.", who: ["claude", "codex"] },
        { text: "Capacity plan using calendar days, the WIP limit, the review queue and rest.", who: ["claude"] },
        { text: "Risk register with owners and triggers.", who: ["claude", "codex"] },
        { text: "Release criteria and readiness checks (see G5).", who: ["codex", "claude"] },
        { text: "Approve the plan and lift the feature freeze for the approved scope.", who: ["owner"] }
      ],
      packet: {
        id: "K6", name: "Release plan", path: "docs/product/plan/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Slice board (SL ids)", "Capacity and critical path", "Risk register", "Change-control log", "Release criteria and readiness checks", "Gate records"]
      },
      gate: {
        id: "G5", name: "Build approved", approver: "owner",
        criteria: [
          "The build critical path (review, CI, fixes and acceptance of every must slice) ends by Oct 28, leaving Oct 29 and 30 for the planned P7 verification and release candidate. If it does not fit, you choose at G5: a smaller must-list or a later release candidate.",
          "Release criteria name the supported OS and tool versions and a fake-model-first install from a clean clone.",
          "Readiness checks are defined: synthetic data only, no-send negative tests, credential, proxy and tool isolation, backup and restore, unknown-outcome recovery, cost and budget limits.",
          "Any real-model evaluation budget is approved separately by you, or is zero.",
          "The workshop fallback is defined and has an owner."
        ]
      }
    },
    {
      id: "P6", name: "Build", start: "2026-10-10", end: "2026-10-28", status: "planned",
      goal: "Build the approved scope slice by slice, starting with one narrow first slice, in short iterations you can see and steer.",
      traditional: "Sprints with planning, daily stand-ups, code review, a demo to stakeholders and a retrospective. Here, short iterations of about four days, seven days a week, because review is the bottleneck.",
      ownerTime: "About 30 minutes a day for status and decisions, plus a 30-minute live demo at the end of each iteration.",
      activities: [
        { text: "Per slice: entity check, failing test first, implementation, independent review, merge on exact-head CI.", who: ["claude", "codex"] },
        { text: "First slice from Oct 10, after G1 to G5 pass for it. Later slices start only when their own gates pass.", who: ["claude", "codex"] },
        { text: "Eval harness and no-send negative tests built in an early iteration, not at the end.", who: ["claude", "codex"] },
        { text: "Daily status: what moved, what is blocked, what needs you.", who: ["claude"] },
        { text: "Iteration demos about every four days, live in the app.", who: ["claude", "owner"] },
        { text: "Scope-cut check on Oct 22.", who: ["claude", "owner"] },
        { text: "Three-line retrospective per iteration.", who: ["claude", "codex", "owner"] }
      ],
      packet: {
        id: "PRs", name: "Slice pull requests and evidence", path: "GitHub PRs, notes/features/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["One PR per slice with its review verdict and exact-head CI", "Slice notes", "Iteration demo notes and retrospectives in the journal"]
      },
      gate: {
        id: "G6", name: "Feature complete", approver: "owner",
        criteria: [
          "Every must SL is merged with its acceptance test passing on the merged commit.",
          "No open blocking review finding.",
          "You have seen each must working in an iteration demo."
        ]
      }
    },
    {
      id: "P7", name: "Verify and harden", start: "2026-10-29", end: "2026-10-30", status: "planned",
      goal: "Final integrated check of the release candidate. Most problems should already have been found earlier.",
      traditional: "QA runs the full acceptance suite, security does a final review, the team holds a bug bash, and a release candidate is cut.",
      ownerTime: "About 2 hours: bug bash and release-candidate sign-off.",
      activities: [
        { text: "Full acceptance and eval run against the G2 thresholds.", who: ["codex", "claude"] },
        { text: "Final security and accessibility review.", who: ["codex", "claude"] },
        { text: "Backup and restore run end to end.", who: ["claude", "owner"] },
        { text: "Bug bash, triaged with the severity scale.", who: ["owner", "claude", "codex"] },
        { text: "Cut the release candidate.", who: ["claude", "owner"] }
      ],
      packet: {
        id: "K7", name: "Release and learning (part 1: verification)", path: "docs/product/release/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Acceptance results", "Eval report", "Security and accessibility review", "Restore test result"]
      },
      gate: {
        id: "G7", name: "Release candidate", approver: "owner",
        criteria: [
          "Acceptance and eval thresholds met.",
          "No open P0 or P1 bug.",
          "Restore from backup works.",
          "Security review has no open blocking finding."
        ]
      }
    },
    {
      id: "P8", name: "Dog-food and release", start: "2026-10-30", end: "2026-11-05", status: "planned",
      goal: "Use the product for real work on synthetic data, fix only what blocks release, and get it ready for other founders to install.",
      traditional: "Internal beta: the company uses its own product, triages bugs daily and only fixes release blockers. Docs and release notes are finished in parallel.",
      ownerTime: "Daily use, plus about 30 minutes a day for triage.",
      activities: [
        { text: "You use it daily on synthetic data and the HubSpot test portal.", who: ["owner"] },
        { text: "Daily triage; only P0 and P1 are fixed, through the normal review path.", who: ["claude", "codex", "owner"] },
        { text: "Install and restore guide, workshop runbook, limitations list, release notes.", who: ["claude"] },
        { text: "Fallback rehearsal.", who: ["owner", "claude"] },
        { text: "Go / no-go on Nov 5.", who: ["owner"] }
      ],
      packet: {
        id: "K7", name: "Release and learning (part 2: release)", path: "docs/product/release/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Dog-food log", "Install and restore guide", "Workshop runbook and fallback", "Known limitations", "Release notes and tag"]
      },
      gate: {
        id: "G8", name: "Go / no-go", approver: "owner",
        criteria: [
          "The release tag and commit are bound to the evidence in the gate record.",
          "A fresh install from the guide works on a clean machine with the fake model.",
          "The open-issues and limitations list is published with the release.",
          "You approve every claim the workshop will make about the product.",
          "The fallback is rehearsed. Nothing in the release is an unreviewed patch."
        ]
      }
    },
    {
      id: "P9", name: "Workshop and learn", start: "2026-11-06", end: "2026-11-09", status: "planned",
      goal: "Put it in front of founders, learn from them, and decide what production readiness requires.",
      traditional: "Launch, collect feedback, hold a retrospective, and update the roadmap from what real users did.",
      ownerTime: "The workshop itself, plus about 1 hour for the retrospective.",
      activities: [
        { text: "Run the workshop.", who: ["owner"] },
        { text: "Feedback and defect triage: Claude triages within two working days, Codex reviews fixes, you decide priorities.", who: ["claude", "codex", "owner"] },
        { text: "Retrospective across the whole project.", who: ["owner", "claude", "codex"] },
        { text: "Roadmap to production: real companies, then real contacts, then real sending, each with its own gate.", who: ["claude", "codex", "owner"] },
        { text: "Case study for founders, within the publication policy.", who: ["claude", "owner"] }
      ],
      packet: {
        id: "K7", name: "Release and learning (part 3: learning)", path: "docs/product/learn/, docs/sdlc/", status: "todo", author: "claude", reviewer: "codex",
        contents: ["Feedback synthesis with a decision per item", "Retrospective", "Production readiness roadmap", "Founder case study"]
      },
      gate: {
        id: "G9", name: "Next horizon agreed", approver: "owner",
        criteria: [
          "Every feedback item has a decision and an owner.",
          "The roadmap names what must be true before any real prospect is contacted, including legal review."
        ]
      }
    }
  ],

  rituals: [
    { name: "Daily status", when: "Each working morning in chat", who: ["claude"], text: "What moved, what is blocked, decisions waiting on you. Short." },
    { name: "Gate review", when: "End of each phase", who: ["owner", "claude", "codex"], text: "You review the packet and its gate record, then approve or send it back." },
    { name: "Iteration demo", when: "End of each build iteration", who: ["claude", "owner"], text: "Merged work shown live in the app. No slides." },
    { name: "Design critique", when: "During UX design", who: ["owner", "claude", "codex"], text: "The prototype reviewed against the requirements and the state map." },
    { name: "Retrospective", when: "End of each phase", who: ["owner", "claude", "codex"], text: "Three lines: what worked, what did not, what we change. Recorded in the journal." }
  ],

  agreements: [
    "Author and reviewer are never the same agent. Codex reviews Claude's work; Claude reviews Codex's.",
    "Only you approve a gate, an ADR, an exception or a real-model budget. Agents never infer approval, and notes on the interactive pages are feedback, not approval.",
    "A gate passes only with a committed gate record. Dates never pass gates.",
    "Material changes after review go back to the reviewer. Pull requests merge only on green CI for their exact commit.",
    "The feature freeze holds until you explicitly approve G5. Process and hardening work continue, with no new authority.",
    "The constraints listed on this page stay in force unless you accept an ADR that amends them.",
    "Disagreements between Claude and Codex come to you with both positions. Your decision does not waive an unresolved security blocker.",
    "Durable records go in git within the publication policy. Private material stays private."
  ],

  history: [
    { date: "2026-10-06", title: "One-shot prompt and scaffold", text: "You pasted an architecture design for an SDR agent built on one rule: \"Jido decides. Ash governs. Oban executes durably. Postgres remembers. OTP keeps it alive. Phoenix lets humans operate it.\" Then you asked for a project scaffold." },
    { date: "2026-10-06", title: "Unattended build charter", text: "You delegated decisions to Claude and Codex under a written mandate with bounded authority and stop conditions (ADR-0001)." },
    { date: "2026-10-07", title: "Provider pivot", text: "The planned real model, Codex app-server on your existing Codex login, could not have its built-in tool surface fully disabled and verified, so it stays disabled. You approved the Claude CLI on your own login instead, locked down to no tools and checked on every call." },
    { date: "2026-10-07", title: "MVP slices merged", text: "Fourteen slices: audit ledger, domain model, agent, outreach, replies, operator UI, signed audit anchors, and a wire witness that can match supported model calls to what crossed the network." },
    { date: "2026-10-07", title: "Meetup demo", text: "Demoed live with real AI. The real-model wiring and risk flags ran on an unreviewed local patch, which was reverted afterwards and rebuilt through review." },
    { date: "2026-10-07", title: "Quality push and HubSpot test portal", text: "Real model wired into the app, child-process secret scrub, wire witness switched on for one exact reviewed configuration. A free HubSpot developer portal was filled with synthetic companies." },
    { date: "2026-10-07", title: "Build-first plan rejected", text: "You stopped the next build plan: features, functionality and the operator experience had to be defined first. Feature freeze." },
    { date: "2026-10-08", title: "Discovery answered, scope decided", text: "You answered the discovery questionnaire. Claude and Codex reviewed it; you chose a first-touch copilot, desktop only, captured sends, HubSpot optional." },
    { date: "2026-10-08", title: "SDLC process proposed", text: "You asked for a traditional product process, worked through together, with durable artifacts in git. Codex requested changes twice, then approved the third revision." },
    { date: "2026-10-08", title: "Gate G0 passed", text: "You answered the five open questions, accepted the product-phase charter (ADR-0014) and the seven-step shaping method, and chose to start building on Saturday Oct 10 with a narrow first slice." }
  ],

  answeredQuestions: [
    { id: "Q1", q: "Do we work weekends? Which day is your design day?", answer: "Yes. The design day starts today (Oct 8) and ends tomorrow (Oct 9); work begins Saturday, Oct 10.", decision: "D-014, D-015" },
    { id: "Q2", q: "Can you recruit two or three solo founders for a prototype test?", answer: "You have already talked to one other solo founder and have notes. That is enough for this process.", decision: "D-016" },
    { id: "Q3", q: "How do you want to review?", answer: "Notes on this page, or another dedicated page, pasted into chat.", decision: "D-017" },
    { id: "Q4", q: "May we quote your original prompt, discovery answers or other chat messages in git?", answer: "Yes.", decision: "D-018" },
    { id: "Q5", q: "Weekend work, or a smaller must-list?", answer: "We are building seven days a week.", decision: "D-014" }
  ],

  openQuestions: [
    { id: "Q6", q: "Please share your notes from the founder conversation. Was it an interview about how they do outbound today, a reaction to a demo, or watching them use the product?", why: "The notes are evidence for the outcome brief, and we label them by what they can show. They are the founder's material, so only sanitized findings go in git unless the founder agrees otherwise." },
    { id: "Q7", q: "For planning pages, is the product workbook in git enough, or do you also want a design tool such as Figma or Penpot?", why: "Decision B on the shaping page is still open. Both Claude and Codex recommend the workbook alone for now." }
  ]
};
