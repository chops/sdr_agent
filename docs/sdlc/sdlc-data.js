// Source data for docs/sdlc/index.html (the interactive SDLC map).
// This file is the detailed, versioned record of the process: phases, gates,
// artifacts, roles and status. Claude updates it as work moves; every change
// is reviewed and committed like code. Status values:
//   phases:    done | active | next | planned
//   artifacts: done | draft | review | todo
// People ids: owner, claude, codex, outside.
window.SDLC = {
  meta: {
    product: "SDR Agent",
    version: "v0.1 (proposed, awaiting gate G0)",
    updated: "2026-10-08",
    milestones: [
      { id: "code-complete", label: "Code complete, dog-fooding starts", date: "2026-10-30" },
      { id: "workshop", label: "Solo-founder workshop", date: "2026-11-06" }
    ]
  },

  people: {
    owner: { name: "Charles", label: "You (owner)", blurb: "Founder, product owner, design lead and customer zero. Approves every gate." },
    claude: { name: "Claude", label: "Claude", blurb: "Product manager, designer, tech lead and delivery manager. Drafts most artifacts and coordinates the build." },
    codex: { name: "Codex", label: "Codex", blurb: "Architect, security, QA and compliance reviewer. Reviews everything Claude drafts and builds assigned slices." },
    outside: { name: "Outside help", label: "Outside help", blurb: "People we do not have yet: solo founders as design partners, and legal counsel before real prospects." }
  },

  // How every artifact moves through the process.
  flow: [
    { step: "Draft", who: ["claude"], text: "The author writes the artifact in the repo on its own branch. Usually Claude; Codex authors the slices it is assigned." },
    { step: "Peer review", who: ["codex"], text: "The other agent reviews it in writing and returns a verdict with severity-ranked findings. Author and reviewer are never the same." },
    { step: "Owner review", who: ["owner"], text: "You read it (or click through it), leave notes on the interactive page or in chat, and say approve or change." },
    { step: "Revise", who: ["claude", "codex"], text: "The author addresses every note. Disagreements go back to you with both positions stated." },
    { step: "Approve and commit", who: ["owner", "claude"], text: "You approve, the PR merges, and the decision log records what was decided, by whom and why." }
  ],

  // Who would do this on a traditional product team, and who does it here.
  roles: [
    { role: "Founder / product owner", does: "Sets the vision, owns priorities, accepts or rejects every gate.", playedBy: ["owner"] },
    { role: "Product manager", does: "Runs discovery, writes the brief and requirements, keeps scope honest.", playedBy: ["claude", "owner"], note: "Claude drafts; you decide." },
    { role: "UX researcher", does: "Plans and runs interviews and usability tests with real users.", playedBy: ["claude", "outside"], gap: true, note: "Claude writes the test scripts. We need two or three solo founders to test the prototype." },
    { role: "Product designer", does: "Journeys, wireframes, visual design, design system, prototype.", playedBy: ["claude", "owner", "codex"], note: "Claude drafts, you set the visual direction, Codex critiques states and accessibility." },
    { role: "Tech lead / architect", does: "Technical design, ADRs, sequencing, code quality.", playedBy: ["claude", "codex"], note: "ADRs still need your acceptance." },
    { role: "Software engineers", does: "Build and test the slices.", playedBy: ["claude", "codex"], note: "Claude subagents and Codex, each slice reviewed by the other agent." },
    { role: "AI / evaluation engineer", does: "Agent behaviour spec, prompts, eval sets, red-teaming.", playedBy: ["claude", "codex"], note: "Real model calls need your budget approval." },
    { role: "QA engineer", does: "Test strategy, acceptance tests, exploratory testing, bug triage.", playedBy: ["codex", "owner"], note: "Codex leads test strategy; you do exploratory testing while dog-fooding." },
    { role: "Security engineer", does: "Threat model, security review, exceptions.", playedBy: ["codex"], note: "You approve any exception." },
    { role: "Privacy and legal counsel", does: "Outreach law (CAN-SPAM, CASL), privacy, terms of service.", playedBy: ["outside"], gap: true, note: "No counsel yet. Agents do desk research and flag risk; nothing touches real prospects until you either consult counsel or accept the risk in writing." },
    { role: "DevOps / SRE", does: "Environments, deployment, observability, backups, runbooks.", playedBy: ["claude", "codex"], note: "Local-only for the MVP, so this is install, backup and the Grafana stack." },
    { role: "Delivery manager", does: "Plan, cadence, status, risks, keeping gates on schedule.", playedBy: ["claude"] },
    { role: "Technical writer / DevRel", does: "README, install guide, workshop material, open-source readiness.", playedBy: ["claude", "owner"], note: "You present at the workshop." },
    { role: "Customers / design partners", does: "Use the product and tell us what is wrong with it.", playedBy: ["owner", "outside"], gap: true, note: "You are customer zero. Workshop founders are the first real users." }
  ],

  phases: [
    {
      id: "P0", name: "Prototype and inception", start: "2026-10-06", end: "2026-10-08", status: "active",
      goal: "Take stock of what the one-shot build produced and agree how we will work from here.",
      traditional: "A team inheriting a hackathon prototype holds a kickoff: what is real, what is demo-only, who decides what, and how work will flow. The output is a charter and a process everyone signs.",
      ownerTime: "About 1 hour: read the playbook and this map, answer the open questions, approve G0.",
      activities: [
        { text: "Unattended MVP build from the pasted architecture prompt (done Oct 6 to 7).", who: ["claude", "codex"] },
        { text: "Meetup demo and post-demo hardening (done Oct 7).", who: ["owner", "claude", "codex"] },
        { text: "Prototype assessment: what is production-grade, what is demo-only, known debt.", who: ["claude"] },
        { text: "Map the traditional SDLC onto a team of one founder and two agents.", who: ["claude"] },
        { text: "Review the process for missing roles, steps and unrealistic dates.", who: ["codex"] },
        { text: "Product-phase charter: replaces the unattended-build mandate with this collaborative one.", who: ["claude", "codex"] },
        { text: "Approve the process, the charter and the schedule.", who: ["owner"] }
      ],
      artifacts: [
        { name: "SDLC playbook", path: "docs/sdlc/README.md", status: "review", by: "claude" },
        { name: "Interactive SDLC map (this page)", path: "docs/sdlc/index.html", status: "review", by: "claude" },
        { name: "Project journal: how we got here", path: "docs/sdlc/journal.md", status: "review", by: "claude" },
        { name: "Decision log", path: "docs/sdlc/decisions.md", status: "review", by: "claude" },
        { name: "Prototype assessment", path: "docs/sdlc/prototype-assessment.md", status: "todo", by: "claude" },
        { name: "Product-phase charter (ADR-0014)", path: "docs/adr/0014-product-phase-charter.md", status: "todo", by: "claude" }
      ],
      gate: {
        id: "G0", name: "Process agreed", approver: "owner",
        criteria: [
          "You agree with the phases, gates and who does what.",
          "Codex has reviewed the process and its findings are resolved or put to you.",
          "Open questions on schedule, design partners and review style are answered.",
          "The charter states what the agents may decide alone and what needs you."
        ]
      }
    },
    {
      id: "P1", name: "Discovery", start: "2026-10-07", end: "2026-10-09", status: "next",
      goal: "Agree who the product is for, what problem it solves for them, and what success means.",
      traditional: "The PM and a researcher interview target users, study competitors and write a short product brief. Nobody designs or builds until the brief is signed.",
      ownerTime: "About 1 to 2 hours: review the brief and the personas; the questionnaire is already done.",
      activities: [
        { text: "Discovery questionnaire answered (done Oct 7).", who: ["owner"] },
        { text: "Joint review of the answers; scope decisions taken (done Oct 8).", who: ["claude", "codex", "owner"] },
        { text: "Persona and jobs-to-be-done for the solo founder doing their own outbound.", who: ["claude"] },
        { text: "Competitive scan: Apollo, Outreach, HubSpot sequences and Breeze. What we copy, what we refuse.", who: ["claude"] },
        { text: "Assumptions and risks map: what must be true for this to work, and how we would find out.", who: ["claude", "codex"] },
        { text: "One-page product brief: promise, user, problem, success measures, non-goals.", who: ["claude"] },
        { text: "Review the brief for overclaiming and missing risks.", who: ["codex"] },
        { text: "Approve the brief.", who: ["owner"] }
      ],
      artifacts: [
        { name: "Discovery questionnaire and your answers", path: "docs/product/discovery/", status: "todo", by: "claude" },
        { name: "Answer review (Claude and Codex)", path: "docs/product/discovery/review.md", status: "todo", by: "claude" },
        { name: "Persona and jobs-to-be-done", path: "docs/product/persona.md", status: "todo", by: "claude" },
        { name: "Competitive scan", path: "docs/product/competitive-scan.md", status: "todo", by: "claude" },
        { name: "Assumptions and risks map", path: "docs/product/assumptions.md", status: "todo", by: "claude" },
        { name: "Product brief", path: "docs/product/brief.md", status: "todo", by: "claude" }
      ],
      gate: {
        id: "G1", name: "Brief approved", approver: "owner",
        criteria: [
          "The workshop promise fits in one sentence and you agree with it.",
          "Success measures are things we can actually observe by Nov 6.",
          "Non-goals are written down, so later scope arguments have an answer.",
          "Codex review has no open blocking finding."
        ]
      }
    },
    {
      id: "P2", name: "Definition", start: "2026-10-09", end: "2026-10-11", status: "planned",
      goal: "Turn the brief into requirements precise enough to design, build and test against.",
      traditional: "The PM writes a requirements document with user stories and acceptance criteria; engineering adds non-functional requirements; an ML team writes the model behaviour spec and eval plan; legal reviews data handling.",
      ownerTime: "About 2 hours: priorities, acceptance criteria and the agent behaviour spec.",
      activities: [
        { text: "Requirements: user stories per journey, ranked must, should and later.", who: ["claude"] },
        { text: "Acceptance criteria for every must, written as Given / When / Then.", who: ["claude"] },
        { text: "Non-functional requirements: security, privacy, reliability, accessibility, cost.", who: ["claude", "codex"] },
        { text: "Agent behaviour spec: what the agent may and must never do, voice, evidence rules, failure behaviour.", who: ["claude"] },
        { text: "Eval plan: golden leads, scoring rubric, prompt-injection set, pass thresholds.", who: ["claude", "codex"] },
        { text: "Compliance desk review: CAN-SPAM, CASL, privacy, HubSpot terms. Flags only, not legal advice.", who: ["codex"] },
        { text: "Adversarial review of the requirements and specs.", who: ["codex"] },
        { text: "Approve requirements; this sets the workshop scope.", who: ["owner"] }
      ],
      artifacts: [
        { name: "Requirements with acceptance criteria", path: "docs/product/requirements.md", status: "todo", by: "claude" },
        { name: "Non-functional requirements", path: "docs/product/nfr.md", status: "todo", by: "claude" },
        { name: "Agent behaviour spec", path: "docs/product/agent-behaviour.md", status: "todo", by: "claude" },
        { name: "Eval plan", path: "docs/product/eval-plan.md", status: "todo", by: "claude" },
        { name: "Compliance desk review", path: "docs/product/compliance-review.md", status: "todo", by: "codex" }
      ],
      gate: {
        id: "G2", name: "Scope locked", approver: "owner",
        criteria: [
          "Every must has acceptance criteria someone could test without asking us.",
          "The agent behaviour spec names its hard limits and how each is enforced.",
          "Compliance flags are resolved, deferred with a reason, or accepted by you.",
          "Musts fit the build window with a buffer; anything that does not moves to should."
        ]
      }
    },
    {
      id: "P3", name: "UX design", start: "2026-10-10", end: "2026-10-14", status: "planned",
      goal: "Decide what the SDR control plane looks like and how an operator moves through it, then prove it with a prototype.",
      traditional: "A designer maps journeys, sketches wireframes, holds critiques, sets the visual language, builds a clickable prototype and tests it with five or so real users before engineering starts.",
      ownerTime: "One full design day, plus about 1 hour each for the wireframe review and the prototype test.",
      activities: [
        { text: "Information architecture and screen inventory.", who: ["claude"] },
        { text: "Operator journey and state map: every screen's empty, loading, error and unknown-outcome states.", who: ["claude"] },
        { text: "Low-fidelity clickable wireframes.", who: ["claude"] },
        { text: "Wireframe critique: missing states, accessibility, safety of approval actions.", who: ["codex", "owner"] },
        { text: "Design day: your colours and fonts, two or three visual directions, pick one.", who: ["owner", "claude"] },
        { text: "Design tokens and key screens at full fidelity.", who: ["claude"] },
        { text: "Clickable prototype of the core journey.", who: ["claude"] },
        { text: "Usability test: you, then two or three solo founders, with a task script.", who: ["owner", "outside", "claude"] },
        { text: "Approve the prototype.", who: ["owner"] }
      ],
      artifacts: [
        { name: "Screen inventory and information architecture", path: "docs/product/design/ia.md", status: "todo", by: "claude" },
        { name: "Operator journey and state map (interactive)", path: "docs/product/design/journey.html", status: "todo", by: "claude" },
        { name: "Wireframes (interactive)", path: "docs/product/design/wireframes.html", status: "todo", by: "claude" },
        { name: "Visual directions from the design day", path: "docs/product/design/directions.html", status: "todo", by: "claude" },
        { name: "Design tokens", path: "docs/product/design/tokens.md", status: "todo", by: "claude" },
        { name: "Clickable prototype", path: "docs/product/design/prototype.html", status: "todo", by: "claude" },
        { name: "Usability test script and findings", path: "docs/product/design/usability.md", status: "todo", by: "claude" }
      ],
      gate: {
        id: "G3", name: "Prototype approved", approver: "owner",
        criteria: [
          "You can complete the core journey in the prototype without help.",
          "Every screen has its empty, loading, error and unknown states designed.",
          "Approval screens show the exact recipient, revision and evidence being approved.",
          "Usability findings are fixed or logged with a decision."
        ]
      }
    },
    {
      id: "P4", name: "Technical design", start: "2026-10-12", end: "2026-10-15", status: "planned",
      goal: "Work out how to change the existing system to deliver the approved requirements and design safely.",
      traditional: "Engineering writes a design doc against the requirements, records architecture decisions, threat-models new surfaces, and agrees a test strategy before sprint planning.",
      ownerTime: "About 1 hour: accept or reject ADRs and any security exceptions.",
      activities: [
        { text: "Gap analysis: what exists, what changes, what is new, for every requirement.", who: ["claude"] },
        { text: "Technical design doc and ADRs for new technology or boundaries.", who: ["claude", "codex"] },
        { text: "Entity-model delta for changed data, with independent Codex sign-off.", who: ["claude", "codex"] },
        { text: "Threat model for new surfaces: live web research, CSV import, HubSpot.", who: ["codex"] },
        { text: "Test strategy: unit, property, LiveView, browser end-to-end, evals; each requirement mapped to a test.", who: ["codex", "claude"] },
        { text: "Accept ADRs and exceptions.", who: ["owner"] }
      ],
      artifacts: [
        { name: "Gap analysis", path: "docs/product/tech/gap-analysis.md", status: "todo", by: "claude" },
        { name: "Technical design", path: "docs/product/tech/design.md", status: "todo", by: "claude" },
        { name: "New ADRs", path: "docs/adr/", status: "todo", by: "claude" },
        { name: "Threat model", path: "docs/product/tech/threat-model.md", status: "todo", by: "codex" },
        { name: "Test strategy and requirement-to-test map", path: "docs/product/tech/test-strategy.md", status: "todo", by: "codex" }
      ],
      gate: {
        id: "G4", name: "Design reviewed", approver: "owner",
        criteria: [
          "Every must requirement has a design and a planned test.",
          "Every new external surface has a threat model entry and a mitigation.",
          "Entity-model delta has a Codex PASS.",
          "No ADR is pending your decision."
        ]
      }
    },
    {
      id: "P5", name: "Release planning", start: "2026-10-15", end: "2026-10-15", status: "planned",
      goal: "Sequence the work into slices that fit the time we have, and agree what done means.",
      traditional: "Sprint zero: the team breaks the work into stories, estimates them, maps dependencies, sets milestones and writes the definition of done and the release criteria.",
      ownerTime: "About 1 hour: approve the plan; this lifts the feature freeze.",
      activities: [
        { text: "Break the design into slices with estimates and dependencies.", who: ["claude", "codex"] },
        { text: "Milestones, iteration plan and critical path, including review time.", who: ["claude"] },
        { text: "Risk register with owners and triggers.", who: ["claude", "codex"] },
        { text: "Definition of ready, definition of done, release criteria.", who: ["claude", "codex"] },
        { text: "Approve the plan and lift the feature freeze.", who: ["owner"] }
      ],
      artifacts: [
        { name: "Release plan (interactive board)", path: "docs/product/plan/index.html", status: "todo", by: "claude" },
        { name: "Risk register", path: "docs/product/plan/risks.md", status: "todo", by: "claude" },
        { name: "Definition of ready and done", path: "docs/product/plan/definitions.md", status: "todo", by: "claude" },
        { name: "Release criteria (go / no-go checklist)", path: "docs/product/plan/release-criteria.md", status: "todo", by: "codex" }
      ],
      gate: {
        id: "G5", name: "Build approved", approver: "owner",
        criteria: [
          "The critical path ends before Oct 30 with at least two days of buffer.",
          "Every slice traces back to a requirement.",
          "Release criteria are written before the build starts."
        ]
      }
    },
    {
      id: "P6", name: "Build", start: "2026-10-16", end: "2026-10-27", status: "planned",
      goal: "Build the approved scope in short iterations you can see and steer.",
      traditional: "Two-week sprints with planning, daily stand-ups, code review, a sprint demo to stakeholders and a retrospective. Here, iterations are about four days because the agents are fast and review is the bottleneck.",
      ownerTime: "About 30 minutes a day for status and decisions, plus a 30-minute demo at the end of each iteration.",
      activities: [
        { text: "Per slice: entity check, failing test first, implementation, peer review, merge.", who: ["claude", "codex"] },
        { text: "Daily status: what moved, what is blocked, what needs you.", who: ["claude"] },
        { text: "Iteration demo of merged work, live in the app.", who: ["claude", "owner"] },
        { text: "Backlog refinement and a three-line retrospective per iteration.", who: ["claude", "codex", "owner"] }
      ],
      artifacts: [
        { name: "Slice notes", path: "notes/features/", status: "todo", by: "claude" },
        { name: "Pull requests with review verdicts", path: "GitHub PRs", status: "todo", by: "claude" },
        { name: "Iteration demo notes and retros", path: "docs/sdlc/journal.md", status: "todo", by: "claude" }
      ],
      gate: {
        id: "G6", name: "Feature complete", approver: "owner",
        criteria: [
          "Every must is merged with its acceptance test passing.",
          "No open blocking review finding.",
          "You have seen each must working in an iteration demo."
        ]
      }
    },
    {
      id: "P7", name: "Verify and harden", start: "2026-10-28", end: "2026-10-30", status: "planned",
      goal: "Prove the release candidate meets the requirements, then fix what that uncovers.",
      traditional: "QA runs the full acceptance suite, security does a final review, the team holds a bug bash, and a release candidate is cut.",
      ownerTime: "About 2 hours: bug bash and release-candidate sign-off.",
      activities: [
        { text: "Full acceptance run against the requirements.", who: ["codex", "claude"] },
        { text: "Eval run against the thresholds from the eval plan.", who: ["claude", "codex"] },
        { text: "Final security and accessibility review.", who: ["codex"] },
        { text: "Bug bash.", who: ["owner", "claude", "codex"] },
        { text: "Cut the release candidate.", who: ["claude", "owner"] }
      ],
      artifacts: [
        { name: "Acceptance test report", path: "docs/product/verify/acceptance.md", status: "todo", by: "codex" },
        { name: "Eval report", path: "docs/product/verify/evals.md", status: "todo", by: "claude" },
        { name: "Security and accessibility review", path: "docs/product/verify/security.md", status: "todo", by: "codex" }
      ],
      gate: {
        id: "G7", name: "Release candidate", approver: "owner",
        criteria: [
          "Acceptance and eval thresholds met.",
          "No open P0 or P1 bug.",
          "Security review has no open blocking finding."
        ]
      }
    },
    {
      id: "P8", name: "Dog-food and release", start: "2026-10-30", end: "2026-11-05", status: "planned",
      goal: "Use the product for real work, fix what hurts, and get it ready for other founders to install.",
      traditional: "Internal beta: the company uses its own product, triages bugs daily and only fixes what blocks release. Docs, release notes and launch material are finished in parallel.",
      ownerTime: "Daily use of the product, plus about 30 minutes a day for triage.",
      activities: [
        { text: "You use it daily on test data and the HubSpot test portal.", who: ["owner"] },
        { text: "Daily bug triage; only blocking bugs are fixed.", who: ["claude", "codex", "owner"] },
        { text: "Install guide, workshop runbook and open-source files (contributing, security policy).", who: ["claude"] },
        { text: "Release notes and version tag.", who: ["claude"] },
        { text: "Go / no-go decision on Nov 5.", who: ["owner"] }
      ],
      artifacts: [
        { name: "Dog-food log and triage", path: "docs/product/release/dogfood.md", status: "todo", by: "claude" },
        { name: "Install guide", path: "docs/install.md", status: "todo", by: "claude" },
        { name: "Workshop runbook", path: "docs/product/release/workshop.md", status: "todo", by: "claude" },
        { name: "Release notes v0.1.0", path: "CHANGELOG.md", status: "todo", by: "claude" }
      ],
      gate: {
        id: "G8", name: "Go / no-go", approver: "owner",
        criteria: [
          "Release criteria met.",
          "A fresh install works from the guide on a clean machine.",
          "You are willing to show it to a room of founders."
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
        { text: "Collect and synthesise feedback.", who: ["owner", "claude"] },
        { text: "Retrospective across the whole project.", who: ["owner", "claude", "codex"] },
        { text: "Roadmap to production: real companies, then real contacts, then real sending.", who: ["claude", "codex", "owner"] },
        { text: "Case study for founders: from one-shot demo to product.", who: ["claude", "owner"] }
      ],
      artifacts: [
        { name: "Feedback synthesis", path: "docs/product/learn/feedback.md", status: "todo", by: "claude" },
        { name: "Project retrospective", path: "docs/sdlc/retrospective.md", status: "todo", by: "claude" },
        { name: "Production readiness roadmap", path: "docs/product/learn/roadmap.md", status: "todo", by: "claude" },
        { name: "Founder case study", path: "docs/sdlc/case-study.md", status: "todo", by: "claude" }
      ],
      gate: {
        id: "G9", name: "Next horizon agreed", approver: "owner",
        criteria: [
          "Feedback is captured and every item has a decision.",
          "The production roadmap names what must be true before any real prospect is contacted."
        ]
      }
    }
  ],

  rituals: [
    { name: "Daily status", when: "Each morning in chat", who: ["claude"], text: "What moved, what is blocked, decisions waiting on you. Short." },
    { name: "Gate review", when: "End of each phase", who: ["owner", "claude", "codex"], text: "You review the phase artifacts and approve, or send them back with notes." },
    { name: "Iteration demo", when: "About every 4 days during build", who: ["claude", "owner"], text: "Merged work shown live in the app. No slides." },
    { name: "Design critique", when: "During UX design", who: ["owner", "claude", "codex"], text: "Wireframes and prototype reviewed against the requirements and the state map." },
    { name: "Retrospective", when: "End of each phase", who: ["owner", "claude", "codex"], text: "Three lines: what worked, what did not, what we change. Recorded in the journal." }
  ],

  agreements: [
    "Author and reviewer are never the same agent.",
    "Only you approve a gate, an ADR, an exception or a real-model budget. Agents never infer approval.",
    "Everything durable lives in git: artifacts, decisions, feedback and retrospectives.",
    "The feature freeze holds until gate G5. Hardening and process work may continue.",
    "Disagreements between Claude and Codex come to you with both positions, not a merged compromise.",
    "Nothing touches a real prospect, a real inbox or a real send path in this release."
  ],

  history: [
    { date: "2026-10-06", title: "One-shot prompt and scaffold", text: "You pasted an architecture design for an SDR agent (Jido decides, Ash governs, Oban executes durably, Postgres remembers, OTP keeps it alive, Phoenix lets humans operate it) and asked for a project scaffold." },
    { date: "2026-10-06", title: "Unattended build charter", text: "You delegated decisions to Claude and Codex under a written mandate (ADR-0001) with stop conditions, then left them to build." },
    { date: "2026-10-06", title: "Provider pivot", text: "The planned model login was unavailable, so the real model became the Claude CLI on your own subscription, locked down to no tools." },
    { date: "2026-10-07", title: "MVP slices merged", text: "Fourteen slices: audit ledger, domain model, agent, outreach, replies, operator UI, signed audit anchors and a wire witness for every model call." },
    { date: "2026-10-07", title: "Meetup demo", text: "Demoed live with real AI. The real-model wiring and risk flags ran on an unreviewed local patch, which was reverted afterwards and rebuilt properly." },
    { date: "2026-10-07", title: "Quality push and HubSpot test portal", text: "Real model wired into the app, child-process secret scrub, wire witness enabled. A free HubSpot developer portal was filled with synthetic companies." },
    { date: "2026-10-07", title: "Build-first plan rejected", text: "You stopped the next build plan: features, functionality and the operator experience had to be defined before more production work. Feature freeze." },
    { date: "2026-10-08", title: "Discovery answered, scope locked", text: "You answered the discovery questionnaire. Claude and Codex reviewed it; you chose a first-touch copilot, desktop only, captured sends, HubSpot optional." },
    { date: "2026-10-08", title: "SDLC process started", text: "You asked for a traditional product process, worked through together, with every artifact in git for other founders to follow." }
  ],

  openQuestions: [
    { id: "Q1", q: "Do we work weekends? Which day is your design day?", why: "The schedule assumes calendar days. Your review time is the critical path." },
    { id: "Q2", q: "Can you recruit two or three solo founders for a 30-minute prototype test around Oct 13 to 14?", why: "Without real users the design is only checked by you and two agents." },
    { id: "Q3", q: "How do you want to review: notes on this page pasted into chat, comments on a Claude Doc, or GitHub PR comments?", why: "We should use whatever you will actually use." },
    { id: "Q4", q: "May we quote your original prompt, your discovery answers and your chat messages verbatim in git?", why: "Founders will want to see the real starting point. The draft journal already quotes one message; we will remove it if you say no." },
    { id: "Q5", q: "Is building only about 12 days acceptable, given the must-list may shrink at gate G2?", why: "Planning takes about a week. Every planning day comes out of the build." }
  ]
};
