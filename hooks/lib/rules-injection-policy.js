"use strict";

// SSOT for the rules-injection scope policy (declaration only — no logic, no I/O). Rationale and full contract:
// docs/architecture/claude-code/rules-injection.md. Claude Code injects every `rules/**/*.md` file with no conditional
// `paths:` frontmatter into every session; a rule that should only be read on demand disables that auto-injection with
// a single reserved glob that can never match a real path, plus a marker comment so a reader knows it is deliberate.
//
// Consumers (never the other way round — this file requires nothing): hooks/instructions-loaded-audit.js and
// bin/check-on-demand-rules.sh. Both parse this file AS DATA and never require() it, so keep every declaration below a
// plain one-line literal: no computed values, no concatenation, no module-body side effects.

// The reserved `paths:` value. It contains a directory segment that cannot
// exist, so the loader's glob matcher never selects the file.
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";

// The body marker that must accompany the reserved glob.
// Boundary note: `(?!-?\w)` — NOT `\b`. With `\b` the near-miss
// `on-demand-only-ish` would still match, because the position between `y`
// and `-` is a word boundary.
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;

// Each on-demand-only rule, paired with the SKILL.md files that MUST carry an explicit Read step
// for it: "rules/<x>.md|skills/<a>/SKILL.md,skills/<b>/SKILL.md" (a flat array of pipe-separated
// one-line string literals — the text parser's contract, no objects/nesting). Every entry must
// carry BOTH the reserved glob (as its single `paths:` element) and the marker. The rule name is
// written here and nowhere else; the flat list of on-demand rules is DERIVED from this key column
// by the agents-owned reader (hooks/lib/rules-policy-reader.js). A reader set follows what the rule
// GOVERNS, not who edits files — e.g. every skill that authors outbound text reads rules/coding.md.
// rules/ops.md is narrower: its destructive-operation guidance is enforced by hooks/enforce-system-ops.js
// and the settings.json deny list session-wide regardless of reads, so its reader list only needs the
// skills that consult its non-hook-backed content (worktree recovery, key/secret generation).
const ON_DEMAND_READERS = [
  // commit-push/worktree-end are excluded here: branch.md's How-to-Finish section only points at them, it carries no decision they act on.
  "rules/branch.md|skills/make-detail-plan/SKILL.md,skills/worktree-start/SKILL.md",
  "rules/coding.md|skills/write-code/SKILL.md,skills/issue-create/SKILL.md,skills/commit-push/SKILL.md,skills/update-docs/SKILL.md,skills/worktree-end/SKILL.md,skills/issue-close-stage/SKILL.md,skills/issue-close-finalize/SKILL.md,skills/write-tests/SKILL.md",
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
