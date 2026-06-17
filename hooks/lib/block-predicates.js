"use strict";

// SSOT for block-predicate regexes shared across hooks.
// Extracted in #885 (Axis A) from hooks/enforce-issue-close.js so other
// hooks (e.g. enforce-worktree.js double-block scenarios) can recognize
// the same inline-skill shape without copy-pasting the literal.
//
// INLINE_SKILL_RE matches the exact `gh issue close` invocation shape that
// /issue-close-finalize generates:
//   ISSUE_CLOSE_SKILL=1 gh issue close <N> --reason completed
// Strict-shape: no other env vars, digits-only issue id, `--reason completed`
// required, end-anchored ($). HWS = `[ \t]` (horizontal only — excludes \n/\r).
const INLINE_SKILL_RE =
  /^[ \t]*ISSUE_CLOSE_SKILL=1[ \t]+gh[ \t]+issue[ \t]+close[ \t]+\d+[ \t]+--reason[ \t]+completed[ \t]*$/;

module.exports = { INLINE_SKILL_RE };
