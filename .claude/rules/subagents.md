---
description: Claude-specific subagent constraints
---

# Claude Subagents

Explorer agents are read-only and return relevant files, entry points, and an
implementation outline. Reviewer agents analyze changes and return
severity-ranked findings without editing. Escalate implementation or tool needs
to the main agent rather than silently widening a subagent's permissions.
