"use strict";

// SSOT for the rules-injection scope policy (declaration only — no logic, no I/O). Claude Code injects every
// `rules/**/*.md` file that carries no conditional `paths:` frontmatter into every session unconditionally. A rule that
// should only be read on demand disables that auto-injection by declaring a single reserved glob that can never match
// any real path, and by carrying a marker comment in its body so a human reader knows the omission is deliberate.
//
// Consumers (never the other way round — this file requires nothing): hooks/instructions-loaded-audit.js (runtime
// verdicts); bin/check-on-demand-rules.sh (static pre-commit invariants; parses this file AS DATA, never require()s
// it). Because the static checker reads this file with a text parser, keep every declaration below a plain literal on
// one line: no computed values, no concatenation, no module-body side effects.

// The reserved `paths:` value. It contains a directory segment that cannot
// exist, so the loader's glob matcher never selects the file.
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";

// The body marker that must accompany the reserved glob.
// Boundary note: `(?!-?\w)` — NOT `\b`. With `\b` the near-miss
// `on-demand-only-ish` would still match, because the position between `y`
// and `-` is a word boundary.
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;

// Each on-demand-only rule, paired with the SKILL.md files that MUST carry an
// explicit Read step for it: "rules/<x>.md|skills/<a>/SKILL.md,skills/<b>/SKILL.md".
// Every entry must carry BOTH the reserved glob (as its single `paths:` element)
// and the marker.

// A multi-field declaration stays a flat array of pipe-separated one-line string
// literals — object literals and nested arrays are out of contract for the text
// parser. The rule name is written here and nowhere else; the flat list of
// on-demand rules is DERIVED from this key column by the agents-owned reader
// (hooks/lib/rules-policy-reader.js), which is the only place allowed to derive.
// skills/commit-push and skills/worktree-end are NOT required readers of rules/branch.md: its
// "How to Finish" section only points at those skills and carries no decision they act on.

// A reader set follows what the rule GOVERNS, not who edits files: rules/coding.md carries the
// Public GitHub Rules, so every skill that authors outbound text (issue body, PR body, commit
// message, docs) reads it; rules/ops.md is read wherever a destructive or system-state operation
// can arise, not only at worktree teardown.
const ON_DEMAND_READERS = [
  "rules/branch.md|skills/make-detail-plan/SKILL.md,skills/worktree-start/SKILL.md",
  "rules/coding.md|skills/write-code/SKILL.md,skills/issue-create/SKILL.md,skills/commit-push/SKILL.md,skills/update-docs/SKILL.md,skills/worktree-end/SKILL.md,skills/issue-close-stage/SKILL.md,skills/issue-close-finalize/SKILL.md",
  "rules/docs.md|skills/update-docs/SKILL.md",
  "rules/github-issues.md|skills/issue-create/SKILL.md,skills/issue-close-stage/SKILL.md,skills/issue-close-finalize/SKILL.md,skills/issue-reconcile/SKILL.md,skills/issue-close-migrated/SKILL.md,skills/clarify-intent/SKILL.md,skills/commit-push/SKILL.md,skills/worktree-end/SKILL.md,skills/workflow-init/SKILL.md,skills/sweep-issues/SKILL.md,skills/issue-setup/SKILL.md",
  "rules/mid-workflow-findings.md|skills/issue-create/SKILL.md,skills/worktree-end/SKILL.md",
  "rules/ops.md|skills/worktree-end/SKILL.md,skills/write-code/SKILL.md,skills/worktree-start/SKILL.md",
  "rules/test.md|skills/write-tests/SKILL.md,skills/review-tests/SKILL.md,skills/run-tests/SKILL.md",
  "rules/worktree.md|skills/make-detail-plan/SKILL.md,skills/worktree-start/SKILL.md",
];

// Repo-relative paths of the rules that are deliberately injected
// unconditionally, i.e. that carry no `paths:` frontmatter at all.
const EXPECTED_UNCONDITIONAL = [
  "rules/core-principles.md",
  "rules/git.md",
  "rules/shell-commands.md",
  "rules/stop-guard-exemptions.md",
  "rules/supervisor-reporting.md",
  "rules/user-escalation.md",
  "rules/workflow-off.md",
];

// Escape hatches: a rule that says how to get unstuck must never require the machinery
// the session is stuck in, so these stay unconditional and are MINIMIZED instead —
// trigger conditions only, procedure moved to the pointer named after the pipe.
// "rules/<x>.md|<repo-relative pointer path>". Subset of EXPECTED_UNCONDITIONAL,
// disjoint from ON_DEMAND_READERS.
const MINIMIZED_UNCONDITIONAL = [
  "rules/stop-guard-exemptions.md|hooks/lib/stop-exemption-policy.js",
  "rules/supervisor-reporting.md|skills/supervisor-report/SKILL.md",
  "rules/workflow-off.md|skills/enforce-workflow-off/SKILL.md",
];

// Size ceiling in BYTES for every MINIMIZED_UNCONDITIONAL rule. A string literal
// because the text parser reads strings only; consumers Number() it and fail closed
// when the result is not a positive safe integer.
const MINIMIZED_MAX_BYTES = "1500";

module.exports = {
  ON_DEMAND_TOKEN,
  ON_DEMAND_MARKER_RE,
  ON_DEMAND_READERS,
  EXPECTED_UNCONDITIONAL,
  MINIMIZED_UNCONDITIONAL,
  MINIMIZED_MAX_BYTES,
};
