# agents Repository Development Conventions

Conventions that apply only when working **inside the agents repository itself**
(editing skills, hooks, rules, agents, bin, or docs of this repo). Not loaded
globally; consult on demand via the pointer in `CLAUDE.md`.

## Behavioral Issues Go to GitHub Issues, Not Memory

When the user reports a behavioral problem in this repo — a skill ignoring a
flag, a hook misfiring, a workflow step being skipped, a rule producing the
wrong outcome — file it as a GitHub issue via `/issue-create`. Do not save it
to `~/.claude/projects/.../memory/`.

**Rationale.** Memory and GitHub Issues serve different audiences:

- **Memory** — personal preferences and collaboration hints that shape how
  Claude behaves with this user across sessions. No tracking, no closure.
- **GitHub Issues** — actionable work items in the agents repo. Tracked,
  prioritized, closed by a PR, recorded in `history.md`.

Behavioral defects in this repo are work items. Saving them to memory leaves
them untracked and the fix deferred indefinitely; the next session inherits
the bug plus a stale memory note about it.

**Decision rule.** Is the report about repo code behavior (skill / hook /
rule / bin)? → `/issue-create`. Is it about how Claude should converse or
collaborate independent of repo code? → memory is appropriate.
