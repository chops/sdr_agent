# Discovery answers (owner, verbatim)

- **Source:** the owner's chat message of 2026-10-07 (evening, America/Denver),
  answering [the discovery questionnaire](questionnaire.html). The owner pasted
  the answers into chat rather than saving them on the questionnaire page.
- **Publication:** the owner allowed quoting their discovery answers in git on
  2026-10-08 (SDLC map question Q4; recorded in docs/sdlc/decisions.md).
- **Format:** each line is a question, followed by the owner's picks. "Note:"
  lines are the owner's own words, reproduced unchanged apart from list
  indentation. "(no pick)" means the owner chose no option for that question.
- **What this is:** input to the outcome brief and story map. Answering the
  questionnaire approved nothing.

## Who it's for and why

- **Who is the product mainly for?**
  Me, as a solo founder or operator doing my own outbound.
  Note: the workshop i'm doing on nov 6 is for solo founders. i'm making this product for that workshop. however, in the future i may want this product to serve the others ICPs mentioned in this question
- **If teams use it, how big?**
  Just me.
  Note: the workshop i'm doing on nov 6 is for solo founders. i'm making this product for that workshop. however, in the future i may want this product to serve the others ICPs mentioned in this question
- **Which jobs should it do for the user?**
  Find and qualify leads; Research accounts; Write first-touch emails; Handle replies; Book meetings; Keep the CRM up to date; Report on results
- **How will you know it's working?**
  Meetings booked; Positive reply rate; Hours saved per rep per week; Cost per meeting; Pipeline value created; Number of accounts reached
- **What should make it different from other tools?**
  Full audit trail and transparency; A human approves every message; Every claim backed by evidence; Compliance built in; Runs privately or locally
- **Which tools have you used, or should we benchmark against?**
  Apollo; Outreach; HubSpot sequences / Breeze agents

## Scope

- **Which outreach channels are in scope?**
  Email; Phone (call scripts and tasks)
- **When a prospect replies "interested", what should happen?**
  Draft a reply with proposed times, for approval.
- **Meeting booking?**
  A calendar link inside emails.
  Note: eventually i would like this to include built-in scheduling
- **Where do leads come from?**
  HubSpot; CSV upload; Typed in by hand; The agent finds them from an ideal-customer profile
  Note: we will need to spend some time discussing how an agent can find a lead from an ICP definition
- **Long term, how much should send without a human approving?**
  Nothing: every message approved, always.
  Note: eventually i would like this process to be automated, but we need to launch it with guardrails first.
- **Anything it should explicitly NOT do?**
  (no pick)

## Operator experience

- **What does an operator's day look like?**
  Mostly hands-off; only act on alerts.
  Note: i think there should be a choice to get alerts and do batch review if that's what the operator wants.
- **What should the home screen show first?**
  Drafts waiting for approval; Replies that need action; Campaign results; What the agent is doing right now; Problems needing attention; Meetings booked today
- **How should reviewing and approving feel?**
  Edit inline with AI suggestions; Approve similar drafts in bulk; Keyboard-driven queue (j/k, a to approve); A short reason required when rejecting
- **Which roles need their own view?**
  SDR / reviewer; Admin; Auditor / compliance
  Note: we can add the others later. i think these three are probably sufficient for the MVP demo.
- **How should the app get an operator's attention?**
  Daily email digest; Slack; Telegram; Desktop notifications
  Note: also in the app
- **Devices?**
  Desktop, plus reviewing on a phone.
  Note: should the phone UI/UX be optimized differently? why or why not?
- **What should it feel like visually?**
  (no pick)
  Note: let's test different variations.

## Agent behaviour and quality

- **What voice should emails have?**
  Set per campaign from brand guidelines.
  Note: also have the option to import my email and match my own writing samples.
- **How deep should personalization go?**
  (no pick)
  Note: this should be a customizable setting
- **How should we measure draft quality?**
  Approval rate; Reply rate; Regular fact-check audits; Tone and brand checks
- **Should the agent learn from reviewers' edits?**
  Yes, adapt per campaign automatically.
- **Model cost per lead?**
  (no pick)
  Note: make this setting customizable

## Data, compliance and where it runs

- **Where should it run?**
  Multi-customer SaaS eventually.
  Note: but for the MVP we can keep it a personal local app. i just want you to make sure that the architecture can scale as needed.
- **Which regions' prospects?**
  United States; Canada; EU / UK; Other
  Note: it should be like any CRM. for the MVP we will do US and canada though. don't worry about the others.
- **How long should data be kept?**
  Per-region rules.
- **When should it hold real people's data?**
  After the HubSpot integration works.

## Business

- **What's the goal for this product?**
  An open-source project.
- **If commercial, how would it be priced?**
  (no pick)
- **Any deadline or milestone we should plan around?**
  (no pick)
  Note: nov 6 is the workshop where i'll be showing solo founders what can be done with this kind of tool. i'd prefer the tool to be finished a week before that so i can start testing it out and squashing bugs ahead of time.
- **Anything else Claude and Codex should know?**
  (no pick)
  Note: we're going to need to work on the UI/UX, color scheme, fonts, etc etc etc. i already have an idea of the color scheme (and maybe fonts) i want to use. then we'll need to determine what screens will need to be built, what actions will be taken on each of those screens, and then wireframe/design all of them. i think i want to take a day to do the design process.
