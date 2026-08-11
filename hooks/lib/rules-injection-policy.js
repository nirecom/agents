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

// Repo-relative paths of the rules that are on-demand-only. Every entry must
// carry BOTH the reserved glob (as its single `paths:` element) and the marker.
const ON_DEMAND_FILES = [
  "rules/docs.md",
  "rules/github-issues.md",
  "rules/test.md",
];

// Repo-relative paths of the rules that are deliberately injected
// unconditionally, i.e. that carry no `paths:` frontmatter at all.
const EXPECTED_UNCONDITIONAL = [
  "rules/branch.md",
  "rules/coding.md",
  "rules/core-principles.md",
  "rules/docs-only-short-circuit.md",
  "rules/git.md",
  "rules/issue-close-verified.md",
  "rules/mid-workflow-findings.md",
  "rules/ops.md",
  "rules/shell-commands.md",
  "rules/stop-guard-exemptions.md",
  "rules/supervisor-reporting.md",
  "rules/user-escalation.md",
  "rules/workflow-off.md",
  "rules/worktree.md",
];

module.exports = {
  ON_DEMAND_TOKEN,
  ON_DEMAND_MARKER_RE,
  ON_DEMAND_FILES,
  EXPECTED_UNCONDITIONAL,
};
