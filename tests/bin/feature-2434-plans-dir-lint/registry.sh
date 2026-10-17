#!/usr/bin/env bash
# Tests: hooks/lib/plans-artifact-registry.js
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, control-dir, registry, classification, table-driven, pwsh-not-required
# Part file of tests/bin/feature-2434-plans-dir-lint.sh (sourced; uses its reg
# driver, check, trim_f and SID_* fixtures). The registry's classification: the
# inventory table, sid shapes, unregistered/no-sid, ambiguity and the kind sets.

case_begin "inventory-table-verdicts" "hooks/lib/plans-artifact-registry.js"
# Every inventory row, under a UUID sid. The verdict is the whole contract:
# control rows move, artifact rows stay, and nothing in the table is ambiguous.
while IFS='|' read -r name want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(trim_f "$name")"; want="$(trim_f "$want")"
    check "inventory: $name is $want" "$want" "$(reg classify "$SID_UUID-$name")"
done <<'TABLE'
# control — review loop state
detail-plan-round-number.txt                        | control
outline-plan-last-round.txt                         | control
test-review-terminal.txt                            | control
security-code-unresolved-concerns.json              | control
review-security-shared-concern-ledger.txt           | control
security-plan-concern-ledger-cycle3.txt             | control
detail-plan-concern-ledger-cap-snapshot.txt         | control
outline-plan-concern-carrier.md                     | control
security-code-round-2-delta-codex.txt               | control
# control — sole-writer CLIs
security-code-exit6-accepted.txt                    | control
review-plan-security-exit6-accepted.txt             | control
review-tests-exit6-accepted.txt                     | control
outline-risk-signal.txt                             | control
detail-risk-signal.txt                              | control
worker-commit-push.json                             | control
worker-x-1.json                                     | control
worker-commit-push.dispatched                       | control
# control — context, signals, close family, supervisor, init, clarify
codex-context.md                                    | control
codex-context.detail-plan.built                     | control
plan.jsonl                                          | control
changed-files.txt                                   | control
complexity-signals.txt                              | control
detail-signals.txt                                  | control
write-tests-signals.txt                             | control
write-code-signals.txt                              | control
finalize-state-1.json                               | control
finalize-binding-1.json                             | control
issue-close-outcome.json                            | control
session-close-gate.json                             | control
final-report-env.json                               | control
supervisor-state.json                               | control
wi-checkpoint.json                                  | control
handoff.md                                          | control
wt-cleanup-active                                   | control
workflow-init-aborted-pathA-multiN-label-failure.md | control
companion-precheck.json                             | control
intent-scan-block.txt                               | control
guard-attempt.tmp                                   | control
# artifacts — stay in PLANS_DIR
intent.md                                           | artifact
outline.md                                          | artifact
detail.md                                           | artifact
context.md                                          | artifact
survey-code.md                                      | artifact
survey-history.md                                   | artifact
issue-prefill.md                                    | artifact
test-review.md                                      | artifact
concerns-log.md                                     | artifact
codex-round-2-raw.md                                | artifact
complexity-judge-raw.txt                            | artifact
detail-judge-raw.txt                                | artifact
write-tests-judge-raw.txt                           | artifact
write-code-judge-raw.txt                            | artifact
write-code-files.txt                                | artifact
worker-commit-push.draft.json                       | artifact
worker-x-1.draft.json                               | artifact
issue-create-dispatch.txt                           | artifact
issue-create-survey.json                            | artifact
sweep-issues-survivors.tsv                          | artifact
sweep-issues-decisions.tsv                          | artifact
refactor-prompts-scan.json                          | artifact
note-topic.md                                       | artifact
note-topic.json                                     | artifact
user-requested-topic.md                             | artifact
sweep-plans-approved-sessions.txt                   | artifact
jev-0123456789abcdef-answer.txt                     | artifact
TABLE
case_end

case_begin "sid-shapes-parse-alike" "hooks/lib/plans-artifact-registry.js"
# The kind is parsed from the remainder, never carved from the sid's shape, so
# a sid holding dashes of its own must still come back whole.
for SID in "$SID_UUID" "$SID_DATE" "$SID_DERIVED" "$SID_TEST"; do
    check "sid shape $SID: the round-number control file parses to its sid" \
        "sid=$SID kind=set" "$(reg parse "$SID-detail-plan-round-number.txt")"
    check "sid shape $SID: the detail artifact parses to its sid" \
        "sid=$SID kind=set" "$(reg parse "$SID-detail.md")"
    check "sid shape $SID: round-number classifies as control" \
        "control" "$(reg classify "$SID-detail-plan-round-number.txt")"
    check "sid shape $SID: detail.md classifies as artifact" \
        "artifact" "$(reg classify "$SID-detail.md")"
done
# The derived sid's files are its own: '<uuid>' cut leaves 'b1-...', which is
# no kind, so the only candidate is the full '<uuid>-b1'.
check "a derived sid's control file is not mistaken for its parent's" \
    "sid=$SID_DERIVED kind=set" "$(reg parse "$SID_DERIVED-test-review-round-number.txt")"
case_end

case_begin "unregistered-and-no-sid" "hooks/lib/plans-artifact-registry.js"
# A name matching no kind is a session's file when a session provably exists
# under that prefix (its context / intent in PLANS, or its state json in WF).
: > "$WORKFLOW_PLANS_DIR/$SID_UUID-context.md"
check "an unknown name under a sid with a context.md is unregistered" \
    "unregistered" "$(reg classify "$SID_UUID-foo.md")"
# #2558: worker logs left PLANS_DIR, so the session-close log is no longer a kind.
check "a sid-prefixed session-close worker log is unregistered (#2558)" \
    "unregistered" "$(reg classify "$SID_UUID-session-close-worker.log")"
check "a sid-prefixed stamped finalize worker log is unregistered (#2558)" \
    "unregistered" "$(reg classify "$SID_UUID-finalize-worker-2026-09-28T01-02-03-456Z.log")"
: > "$WORKFLOW_STATE_DIR/$SID_DATE.json"
check "an unknown name under a sid with a workflow state json is unregistered" \
    "unregistered" "$(reg classify "$SID_DATE-scratch.txt")"
check "a worker stamp log with no session behind any prefix is no-sid" \
    "no-sid" "$(reg classify "2026-09-28T01-02-03-456Z-commit-push.log")"
# The fast path: the guard's current sid needs no stat at all.
check "an unknown name under the caller's own sid is unregistered without evidence" \
    "unregistered" "$(reg classify "20991231-235959-anything.bin" "20991231-235959")"
check "the same name with no ctx sid and no evidence is no-sid" \
    "no-sid" "$(reg classify "20991231-235959-anything.bin")"
case_end

case_begin "ambiguous-kind-table" "hooks/lib/plans-artifact-registry.js"
# With a test-only table in which 'x-y.txt' and 'y.txt' are both kinds,
# 'a-x-y.txt' splits two ways — ambiguous is reported, never a silent pick.
check "a name that parses under two sid prefixes is ambiguous" \
    "ambiguous" "$(reg parse-injected "a-x-y.txt")"
check "and a name with a single parse is not" \
    "not-ambiguous" "$(reg parse-injected "a-q-y.txt")"
case_end

case_begin "format-tokens-and-kind-sets" "hooks/lib/plans-artifact-registry.js"
check "FORMAT_TOKENS lists exactly the six review formats" \
    "detail-plan,outline-plan,review-security-shared,security-code,security-plan,test-review" \
    "$(reg format-tokens)"
check "no format token is a dash-suffix of another" "none" "$(reg suffix-collisions)"
check "MIGRATABLE_KINDS is a subset of CONTROL_KINDS" "subset" "$(reg migratable-subset)"
check "a switched control kind is migratable" "yes" "$(reg migratable "detail-plan-terminal.txt")"
check "the short-lived guard-attempt marker is not migratable" "no" "$(reg migratable "guard-attempt.tmp")"
check "legacyBasename is the pre-#2434 <sid>-<name> spelling" \
    "$SID_UUID-detail-plan-terminal.txt" "$(reg legacy "$SID_UUID" "detail-plan-terminal.txt")"
check "getPlansArtifactPath throws on an unregistered kind" "threw" "$(reg artifact-path-unknown)"
check "SOURCE_LINT_EXCEPTIONS is an array" "array" "$(reg lint-exceptions)"
case_end

case_begin "sid-grammar-single-source" "hooks/lib/plans-artifact-registry.js"
# C1: the sid grammar lives in state-io/core.js only. The registry imports it
# and holds no sid regex of its own.
SRC=""
[ -f "$REG_JS" ] && SRC="$(cat "$REG_JS")"
check "the registry names SESSION_ID_VALID_RE" "yes" \
    "$(printf '%s' "$SRC" | grep -q 'SESSION_ID_VALID_RE' && printf yes || printf no)"
check "and requires it from state-io/core" "yes" \
    "$(printf '%s' "$SRC" | grep -Eq "require\([^)]*state-io/core" && printf yes || printf no)"
check "and does not redefine the sid character class" "absent" \
    "$(printf '%s' "$SRC" | grep -Fq '[A-Za-z0-9_-]+$' && printf present || printf absent)"
case_end
true
