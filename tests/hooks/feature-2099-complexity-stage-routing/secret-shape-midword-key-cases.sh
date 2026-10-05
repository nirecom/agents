#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/secret-shape-midword-key-cases.sh
# Tests: hooks/workflow-state/complexity-routing/secret-shape.js
# Tags: complexity, routing, secret-shape, redaction, mid-word-key, table-driven, security, scope:issue-specific, scanner-parity
# Sourced after secret-shape-classifier-cases.sh (split at the 500-line HARD limit); reuses its
# SS_MOD_N and SS_REDACT_PRELUDE. Redaction equals the outbound scanner's hard-secret set, so an
# sk- shape glued to a preceding character ("xsk-...") is redacted whenever the scanner flags it:
# letters-only, digits-only, "_" and "-" separated runs and hyphenated prose such as
# "task-complexity-signals-file-name" included. Only a body below the 20-character floor survives.

d2099ss_redact_midword_key_like_run() {
    local got
    # SS-12: fixtures are built at runtime so the outbound scan never sees a literal key shape.
    got=$(run_node "$SS_REDACT_PRELUDE"'
const SKP = "s" + "k-";
const KEY = "ABCD1234efgh5678IJKL9012";
const mix = (n) => "a1".repeat(Math.ceil(n / 2)).slice(0, n);
show([
  ["midword-mixed", "x" + SKP + KEY],
  ["midword-digit-before-proj", "9" + SKP + "proj-" + KEY],
  ["midword-svcacct", "x" + SKP + "svcacct-" + KEY],
  ["midword-in-prose", "prefix x" + SKP + KEY + " suffix"],
  ["midword-two-keys", "ta" + SKP + KEY + " and tu" + SKP + KEY + "!"],
  ["midword-underscore-run", "x" + SKP + "abcdefghij_123456789"],
  ["midword-run-20-exact", "x" + SKP + mix(20)],
  ["midword-run-20-then-hyphen", "x" + SKP + mix(20) + "-tail"],
  ["midword-run-19-then-hyphen", "x" + SKP + mix(19) + "-bcdefgh"],
  ["midword-body-19", "x" + SKP + mix(19)],
  ["prose-task-file", "tas" + "k-complexity-signals-file"],
  ["prose-task-file-name", "tas" + "k-complexity-signals-file-name"],
  ["midword-letters-only", "x" + SKP + "abcdefghijklmnopqrstuvwx"],
  ["midword-digits-only", "x" + SKP + "1".repeat(24)],
  ["midword-hyphen-split", "x" + SKP + "abcd1234-efgh5678-ijkl9012"],
  ["token-start-key", SKP + KEY],
  ["token-start-after-space", "a " + SKP + KEY],
]);
')
    assert_block "SS-12 a mid-word sk- shape is redacted whenever the scanner flags it; a 19-char body survives" "$got" <<'EOF'
midword-mixed "x[REDACTED]"
midword-digit-before-proj "9[REDACTED]"
midword-svcacct "x[REDACTED]"
midword-in-prose "prefix x[REDACTED] suffix"
midword-two-keys "ta[REDACTED] and tu[REDACTED]!"
midword-underscore-run "x[REDACTED]"
midword-run-20-exact "x[REDACTED]"
midword-run-20-then-hyphen "x[REDACTED]"
midword-run-19-then-hyphen "x[REDACTED]"
midword-body-19 unchanged
prose-task-file "ta[REDACTED]"
prose-task-file-name "ta[REDACTED]"
midword-letters-only "x[REDACTED]"
midword-digits-only "x[REDACTED]"
midword-hyphen-split "x[REDACTED]"
token-start-key "[REDACTED]"
token-start-after-space "a [REDACTED]"
EOF
}

# SS-13: isSecretShaped keeps its unanchored (SS-3) verdicts and now agrees with the redactor
# on every form; a second pass over a mid-word result changes nothing.
d2099ss_midword_classifier_unchanged_and_idempotent() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
const { isSecretShaped } = require(process.env.SS_MOD_N);
const SKP = "s" + "k-";
const KEY = "ABCD1234efgh5678IJKL9012";
const forms = [["midword-mixed", "x" + SKP + KEY], ["midword-letters-only", "x" + SKP + "abcdefghijklmnopqrstuvwx"],
  ["prose-task-file", "tas" + "k-complexity-signals-file"]];
for (const [n, t] of forms) console.log("classifier-" + n + " " + String(isSecretShaped(t)) + " redacted=" + String(red(t) !== t));
const dirty = "a x" + SKP + KEY + " b 9" + SKP + "proj-" + KEY + " tas" + "k-complexity-signals-file";
const once = red(dirty);
console.log("first-pass " + JSON.stringify(once));
console.log("second-pass-identical " + String(red(once) === once));
')
    assert_block "SS-13 isSecretShaped and the redactor agree; re-redacting a mid-word result is a no-op" "$got" <<'EOF'
classifier-midword-mixed true redacted=true
classifier-midword-letters-only true redacted=true
classifier-prose-task-file true redacted=true
first-pass "a x[REDACTED] b 9[REDACTED] ta[REDACTED]"
second-pass-identical true
EOF
}

# SS-14: "_" no longer splits anything: snake_case words glued after an "sk-" substring are
# redacted as the scanner flags them (accepted over-redaction); only a sub-20 body survives.
d2099ss_midword_underscore_splits_run() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
const SKP = "s" + "k-";
const mix = (n) => "a1".repeat(Math.ceil(n / 2)).slice(0, n);
show([
  ["prose-risk-assessment", "ri" + SKP + "assessment_threshold_v2"],
  ["prose-disk-usage", "di" + SKP + "usage_report_2024_final"],
  ["prose-in-sentence", "the ri" + SKP + "assessment_threshold_v2 value"],
  ["midword-underscored-mixed", "x" + SKP + "abcd_1234_efgh_5678_ijkl_9012"],
  ["midword-underscore-19-each-side", "x" + SKP + mix(19) + "_" + mix(19)],
  ["midword-unbroken-mixed", "x" + SKP + "ABCD1234efgh5678IJKL9012"],
  ["midword-underscore-then-run-20", "x" + SKP + "abc_" + mix(20)],
  ["midword-run-20-then-underscore", "x" + SKP + mix(20) + "_tail"],
  ["midword-run-20-boundary", "x" + SKP + mix(20)],
  ["midword-run-19-boundary", "x" + SKP + mix(19)],
  ["token-start-underscored", SKP + "abcd_1234_efgh_5678_ijkl_9012"],
]);
')
    assert_block "SS-14 an underscore no longer splits the run: glued snake_case is redacted, a 19-char body is not" "$got" <<'EOF'
prose-risk-assessment "ri[REDACTED]"
prose-disk-usage "di[REDACTED]"
prose-in-sentence "the ri[REDACTED] value"
midword-underscored-mixed "x[REDACTED]"
midword-underscore-19-each-side "x[REDACTED]"
midword-unbroken-mixed "x[REDACTED]"
midword-underscore-then-run-20 "x[REDACTED]"
midword-run-20-then-underscore "x[REDACTED]"
midword-run-20-boundary "x[REDACTED]"
midword-run-19-boundary unchanged
token-start-underscored "[REDACTED]"
EOF
}

d2099ss_redact_midword_key_like_run
d2099ss_midword_classifier_unchanged_and_idempotent
d2099ss_midword_underscore_splits_run
