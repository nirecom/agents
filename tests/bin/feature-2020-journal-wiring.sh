#!/usr/bin/env bash
# Tests: bin/concern-ledger, bin/lib/codex-review-loop/boundary-journal.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh
# Tags: TL2, codex-review-loop, concern-ledger, concern-journal, threat-boundary, issue-2020, scope:issue-specific, pwsh-not-required
# #2020: `concern-ledger stage` keeps security out-of-boundary/no-path rows out of the ledger and buffers
# journal rows per call; the stage wrappers call bj_post_wrapper "$RC" and only a counted exit code
# flushes the buffer into the concern journal (journal-flush), so a failed or retried round is journaled
# once. Marker lines of the wrapper stdout ride the same buffer; an unwritable journal fails stage.
# TL3 gap (what this test does NOT catch):
# - a live codex reviewer emitting the axis prefixes and marker lines (the reviewer is the stub
#   of tests/bin/feature-2937-review-loop/fixture.sh); the orchestrator step is not driven here.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"
# Re-pin at top level: the fixture's harness_isolate pin is not inherited through this source path.
export WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"

# jall <sid> — every journal row of the session (any format's journal file).
jall() { local f; for f in "$(ctl "$1")"/*-concern-journal.tsv; do [ -f "$f" ] && cat "$f"; done; return 0; }
# jn <sid> <needle> — how many journal rows carry <needle>.
jn() { jall "$1" | grep -cF -- "$2"; }
# jf <sid> <needle> <col> — column <col> of the first journal row carrying <needle>.
jf() { jall "$1" | grep -F -- "$2" | head -n 1 | cut -f "$3"; }
# stage_cli <sid> <fmt> <producer> <parser> <report> — the real stage of the copied tree; rc in S_RC.
stage_cli() {
    S_RC=0
    AGENTS_MAIN_ROOT="$ROOT" run_with_timeout 60 bash "$ROOT/bin/concern-ledger" stage --plans-dir "$P" \
        --session-id "$1" --format "$2" --round 1 --producer "$3" --from-report "$5" --parser "$4" \
        > "$FX_TMP/stage.out" 2> "$FX_TMP/stage.err" || S_RC=$?
    S_ERR="$(cat "$FX_TMP/stage.err" 2>/dev/null)"
}
dpath() { printf '%s/%s-round-1-delta-%s.txt' "$(ctl "$1")" "$2" "$3"; }
# nrows <delta> — concern rows of a delta file (0 when the file is absent).
nrows() { if [ -f "$1" ]; then grep -vc '^#' "$1"; else printf 0; fi; }
has() { if grep -qF -- "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi; }
ordered() { if [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; then printf yes; else printf no; fi; }

L_A5='1. [HIGH] axis:A5/B2 cat:security unquoted argument reaches eval in bin/x'
L_A2='2. [MEDIUM] axis:A2/B1 cat:security a network attacker could replace the script'
L_A0='3. [MEDIUM] axis:A0/B0 cat:security injection with no reachable input path'
L_DOC='4. [LOW] axis:A0/B0 cat:docs README names a removed flag'
MARK='[NOT-CONCERN] axis:A3/B2 | bin/y.sh#- | a malicious co-tenant could read the temp file'
NUM_RPT="$FX_TMP/numbered.txt"
printf '## Codex Review: PERFORMED\n\nNEEDS_REVISION\n%s\n%s\n%s\n%s\n' "$L_A5" "$L_A2" "$L_A0" "$L_DOC" > "$NUM_RPT"

case_begin "p1-and-p2b-split-through-the-detail-wrapper" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
sid="jw-split"; seed_sid "$sid"; st seed "$sid"
reply "$sid" detail-plan 1 "NEEDS_REVISION" "$L_A5" "$L_A2" "$L_A0" "$L_DOC" "$MARK"
wrap make-detail-plan "$sid"
LED="$(ctl "$sid")/detail-plan-concern-ledger.txt"
assert_eq "split: an open HIGH keeps round 1 at exit 1 (unchanged)" "1" "$W_RC"
assert_eq "split: the A5 security finding is in the ledger" "yes" "$(has "$LED" 'unquoted argument reaches eval')"
assert_eq "split: the docs A0 finding is in the ledger" "yes" "$(has "$LED" 'README names a removed flag')"
assert_eq "split: the security A2 row is kept out of the ledger" "no" "$(has "$LED" 'network attacker')"
assert_eq "split: the security A0 row is kept out of the ledger" "no" "$(has "$LED" 'no reachable input path')"
# needle | kind (P1 rows 1-4, the P2b marker last); every text is journaled exactly once.
while IFS='|' read -r needle kind; do
    assert_eq "split: '$needle' is journaled once" "1" "$(jn "$sid" "$needle")"
    assert_eq "split: '$needle' kind" "$kind" "$(jf "$sid" "$needle" 8)"
    assert_eq "split: '$needle' reviewer is codex" "codex" "$(jf "$sid" "$needle" 7)"
done <<'ROWS'
unquoted argument reaches eval|concern
a network attacker could replace|out-of-boundary
no reachable input path|no-path
README names a removed flag|concern
malicious co-tenant|out-of-boundary
ROWS
assert_eq "split: five journal rows in total (no duplicate between P1 and P2b)" "5" "$(jall "$sid" | grep -c .)"
case_end

case_begin "p2b-approved-round-markers-in-all-five-wrappers" "bin/lib/codex-review-loop/boundary-journal.sh"
SC_BODY="$FX_TMP/sc-approved.txt"
printf '## Concern Delta\n\n## HIGH\n(none)\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n%s\n' "$MARK" > "$SC_BODY"
for pair in make-outline-plan:outline-plan make-detail-plan:detail-plan review-plan-security:security-plan \
            review-tests:test-review review-code-security:security-code; do
    skill="${pair%%:*}"; fmt="${pair#*:}"; sid="jw-ap-$fmt"
    seed_sid "$sid"; st seed "$sid"
    reply "$sid" "$fmt" 1 "APPROVED" "$MARK"
    if [ "$skill" = review-tests ]; then
        printf '#!/usr/bin/env bash\necho staged\n' > "$REPO/tests/t-staged.sh"
        git -C "$REPO" add tests/t-staged.sh
    fi
    export FX_SC_BODY="$SC_BODY"
    wrap "$skill" "$sid"
    unset FX_SC_BODY
    if [ "$skill" = review-tests ]; then
        git -C "$REPO" rm -q --cached tests/t-staged.sh
        rm -f "$REPO/tests/t-staged.sh"
    fi
    m='malicious co-tenant'
    assert_eq "$skill: the APPROVED round exits 0 (unchanged)" "0" "$W_RC"
    assert_eq "$skill: the marker line is journaled once" "1" "$(jn "$sid" "$m")"
    assert_eq "$skill: kind / category / axis" "out-of-boundary security A3 B2" \
        "$(jf "$sid" "$m" 8) $(jf "$sid" "$m" 9) $(jf "$sid" "$m" 10) $(jf "$sid" "$m" 11)"
    assert_eq "$skill: reviewer codex, round 1" "codex 1" "$(jf "$sid" "$m" 7) $(jf "$sid" "$m" 5)"
    # The stub reviewer never builds a criteria block, so the per-call hash file stays absent.
    assert_eq "$skill: criteria_hash is 'unknown' when no hash file was written" "unknown" "$(jf "$sid" "$m" 14)"
    assert_eq "$skill: no per-call criteria-hash file is left behind" "0" \
        "$(find "$(ctl "$sid")" -maxdepth 1 -name '*-criteria-hash.*.txt' 2>/dev/null | grep -c .)"
done
case_end

case_begin "p2b-all-markers-needs-revision-keeps-exit-and-diagnoses" "bin/lib/codex-review-loop/boundary-journal.sh"
# R14: NEEDS_REVISION whose findings are all marker lines. The bare loop gives the baseline rc.
for sid in jw-r14-loop jw-r14-wrap; do seed_sid "$sid"; st seed "$sid"; reply "$sid" detail-plan 1 "NEEDS_REVISION" "$MARK"; done
loop jw-r14-loop detail-plan --cap 2 --max-extensions 1 --extensions-used 0
wrap make-detail-plan jw-r14-wrap
assert_eq "r14: the wrapper exit code equals the bare loop's" "$L_RC" "$W_RC"
assert_contains "r14: stderr names the Threat boundary rule" "Threat boundary" "$W_ERR"
# detail R14 (Accepted Tradeoff): the halted round is rolled back and re-run under the same round
# number, so journaling its markers would double-count them against the re-run's rows.
assert_eq "r14: the halted round's marker line is not journaled" "0" "$(jn jw-r14-wrap 'malicious co-tenant')"
case_end

case_begin "p1-stage-reviewer-and-criteria-hash" "bin/concern-ledger"
HF="$FX_TMP/hash-out.txt"; printf 'a1b2c3d4e5f6\n' > "$HF"
export REVIEW_CRITERIA_HASH_OUT="$HF"
stage_cli jw-p1-hash detail-plan review-plan-codex numbered "$NUM_RPT"
unset REVIEW_CRITERIA_HASH_OUT
assert_eq "p1 hash: stage exits 0" "0" "$S_RC"
assert_eq "p1 hash: four rows journaled" "4" "$(jall jw-p1-hash | grep -c .)"
assert_eq "p1 hash: criteria_hash is read from REVIEW_CRITERIA_HASH_OUT" "a1b2c3d4e5f6" "$(jf jw-p1-hash 'unquoted argument' 14)"
assert_eq "p1 hash: producer column" "review-plan-codex" "$(jf jw-p1-hash 'unquoted argument' 6)"
stage_cli jw-p1-nohash detail-plan review-plan-codex numbered "$NUM_RPT"
assert_eq "p1 hash: 'unknown' without the env" "unknown" "$(jf jw-p1-nohash 'unquoted argument' 14)"

SC_RPT="$FX_TMP/scanner.txt"
printf '## Codex Review: PERFORMED\n\n## Concern Delta\n%s\n%s\n%s\n%s\n' \
    '[HIGH] - | bin/x.sh#run_cmd | security | axis:A5/B2 shell injection through an unquoted argument' \
    '[MEDIUM] - | bin/x.sh#fetch | security | axis:A2/B1 a network attacker swaps the download' \
    '[LOW] - | docs/a.md#intro | docs | axis:A0/B0 the intro names a removed flag' \
    "$MARK" > "$SC_RPT"
stage_cli jw-p1-sc review-security-shared security-scanner anchored "$SC_RPT"
D="$(dpath jw-p1-sc review-security-shared security-scanner)"
assert_eq "p1 scanner: stage exits 0" "0" "$S_RC"
assert_eq "p1 scanner: the A5 security row reaches the delta" "yes" "$(has "$D" 'shell injection')"
assert_eq "p1 scanner: the docs A0 row reaches the delta" "yes" "$(has "$D" 'names a removed flag')"
assert_eq "p1 scanner: the security A2 row stays out of the delta" "no" "$(has "$D" 'network attacker')"
assert_eq "p1 scanner: three P1 rows, the marker left to P2" "3" "$(jall jw-p1-sc | grep -c .)"
assert_eq "p1 scanner: every row is reviewer cc-fallback" "cc-fallback" "$(jall jw-p1-sc | cut -f7 | sort -u | paste -sd, -)"
assert_eq "p1 scanner: the A2 row is out-of-boundary" "out-of-boundary" "$(jf jw-p1-sc 'network attacker' 8)"
case_end

case_begin "p1-all-rows-out-of-boundary-diagnoses" "bin/concern-ledger"
OUT_RPT="$FX_TMP/all-out.txt"
printf '## Codex Review: PERFORMED\n\nNEEDS_REVISION\n%s\n%s\n' "$L_A2" "$L_A0" > "$OUT_RPT"
stage_cli jw-p1-out detail-plan review-plan-codex numbered "$OUT_RPT"
assert_eq "p1 all-out: no concern row reaches the delta" "0" \
    "$(nrows "$(dpath jw-p1-out detail-plan review-plan-codex)")"
assert_contains "p1 all-out: stderr names the Threat boundary rule" "Threat boundary" "$S_ERR"
assert_eq "p1 all-out: both rows journaled" "2" "$(jall jw-p1-out | grep -c .)"
case_end

case_begin "p1-unwritable-journal-fails-stage" "bin/concern-ledger"
stage_cli jw-p1-ok detail-plan review-plan-codex numbered "$NUM_RPT"
assert_eq "unwritable: a writable journal stages (precondition)" "present" "$(clf_file_state "$(dpath jw-p1-ok detail-plan review-plan-codex)")"
mkdir -p "$(ctl jw-p1-bad)/detail-plan-concern-journal.tsv"
stage_cli jw-p1-bad detail-plan review-plan-codex numbered "$NUM_RPT"
assert_ne "unwritable: stage fails" "0" "$S_RC"
assert_eq "unwritable: no delta is published" "missing" "$(clf_file_state "$(dpath jw-p1-bad detail-plan review-plan-codex)")"

sid="jw-wrap-bad"; seed_sid "$sid"; st seed "$sid"
reply "$sid" detail-plan 1 "NEEDS_REVISION" "$L_A5" "$L_DOC"
mkdir -p "$(ctl "$sid")/detail-plan-concern-journal.tsv"
wrap make-detail-plan "$sid"
assert_eq "unwritable: the wrapper halts with exit 4" "4" "$W_RC"
assert_contains "unwritable: the reviewer's finding is still shown" "unquoted argument reaches eval" "$W_OUT"
assert_eq "unwritable: the ledger holds no row of the round" "no" "$(has "$(ctl "$sid")/detail-plan-concern-ledger.txt" 'unquoted argument')"
case_end

# static_wiring <skill> — the wrapper exports the hash path before the loop, hands its stdout to
# bj_post_wrapper after it, still ends with exit "$RC", and reaches boundary-journal.sh.
WCTL="$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-review-loop/review-wrapper-control.sh"
static_wiring() {
    local skill="$1" S loop_ln post_ln exp_ln
    S="$SCRIPT_CHECKOUT_ROOT/skills/$skill/scripts/run-codex-review-loop.sh"
    loop_ln="$(grep -n 'bin/run-codex-review-loop"' "$S" | tail -n 1 | cut -d: -f1)"
    post_ln="$(grep -n 'bj_post_wrapper' "$S" | tail -n 1 | cut -d: -f1)"
    exp_ln="$(grep -n 'bj_export_hash_out' "$S" | head -n 1 | cut -d: -f1)"
    assert_eq "$skill: the loop call is found (precondition)" "yes" "$([ -n "$loop_ln" ] && echo yes || echo no)"
    assert_eq "$skill: bj_export_hash_out runs before the loop" "yes" "$(ordered "$exp_ln" "$loop_ln")"
    assert_eq "$skill: bj_post_wrapper runs after the loop" "yes" "$(ordered "$loop_ln" "$post_ln")"
    assert_eq "$skill: the script still ends with exit \"\$RC\"" 'exit "$RC"' "$(sed '/^[[:space:]]*$/d' "$S" | tail -n 1 | tr -d '\r')"
    assert_eq "$skill: boundary-journal.sh is sourced by the script or the shared control" "yes" \
        "$(grep -qF 'boundary-journal.sh' "$S" "$WCTL" 2>/dev/null && echo yes || echo no)"
}

case_begin "p2b-static-make-outline-plan" "skills/make-outline-plan/scripts/run-codex-review-loop.sh"
static_wiring make-outline-plan
case_end

case_begin "p2b-static-make-detail-plan" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
static_wiring make-detail-plan
case_end

case_begin "p2b-static-review-plan-security" "skills/review-plan-security/scripts/run-codex-review-loop.sh"
static_wiring review-plan-security
case_end

case_begin "p2b-static-review-tests" "skills/review-tests/scripts/run-codex-review-loop.sh"
static_wiring review-tests
case_end

case_begin "p2b-static-review-code-security" "skills/review-code-security/scripts/run-codex-review-loop.sh"
static_wiring review-code-security
case_end

# --- #2020 layer 2: rows go to a per-call buffer and land only when bj_round_counts "$RC" says the
# round counts (Contract B Verdict of exit-codes.md); CC-fallback rounds take the same path.
# Fallback cases drive the wrapper with --prestaged-report, which the four path-kind wrappers only
# forward after #2478 (rwc_parse_fallback_args): until the rebase onto #2478 they stay red here.
# FX_RV=1 makes the codex stub fail (exit 3, no rows), so a wrapper that drops the forwarded
# arguments can never pass a fallback assertion with codex rows.

# wrapa <skill> <sid> [args...] — the real stage wrapper with forwarded arguments (W_*).
wrapa() {
    local skill="$1" sid="$2" errf="$FX_TMP/wrapa.err"
    shift 2
    W_RC=0
    W_OUT="$( cd "$REPO" || exit 1
        export AGENTS_MAIN_ROOT="$ROOT"
        SESSION_ID="$sid" PLANS_DIR="$P" EXTENSIONS_USED="${WRAP_EXT:-0}" \
            bash "$ROOT/skills/$skill/scripts/run-codex-review-loop.sh" "$@" 2>"$errf"
    )" || W_RC=$?
    W_ERR="$(cat "$errf" 2>/dev/null)"
}
# fbreport <file> <echo|-> <line...> — a CC-fallback report in the codex-output contract; <echo>
# becomes the final 'BOUNDARY_VERSION: <echo>' line after the block ('-' = no echo line).
fbreport() {
    local f="$1" e="$2"
    shift 2
    {
        printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
        printf '%s\n' "$@"
        printf '<!-- end-codex-output -->\n'
        [ "$e" = - ] || printf 'BOUNDARY_VERSION: %s\n' "$e"
    } > "$f"
}
# agent_of <skill> / fmt_of <skill> / nr_of <skill> — the fallback agent, loop format and the
# needs-revision verdict line of each path-kind wrapper.
agent_of() { case "$1" in make-outline-plan) printf outline-reviewer ;; make-detail-plan) printf detail-reviewer ;; review-plan-security) printf plan-security-reviewer ;; review-tests) printf test-reviewer ;; esac; }
fmt_of() { case "$1" in make-outline-plan) printf outline-plan ;; make-detail-plan) printf detail-plan ;; review-plan-security) printf security-plan ;; review-tests) printf test-review ;; review-code-security) printf security-code ;; esac; }
nr_of() { if [ "$1" = make-outline-plan ]; then printf 'MISSING_ALTERNATIVE: a third approach was not considered'; else printf NEEDS_REVISION; fi; }
# rt_stage on|off — the staged test file review-tests needs to have something to review.
rt_stage() {
    if [ "$1" = on ]; then
        printf '#!/usr/bin/env bash\necho staged\n' > "$REPO/tests/t-staged.sh"; git -C "$REPO" add tests/t-staged.sh
    else
        git -C "$REPO" rm -q --cached tests/t-staged.sh; rm -f "$REPO/tests/t-staged.sh"
    fi
}
# fbwrap <skill> <sid> <report> [args...] — one fallback round through the wrapper.
fbwrap() {
    local skill="$1" sid="$2" rep="$3"
    shift 3
    [ "$skill" = review-tests ] && rt_stage on
    export FX_RV=1
    wrapa "$skill" "$sid" --prestaged-report "$rep" --prestaged-producer "$(agent_of "$skill")" --prestaged-exec PERFORMED "$@"
    unset FX_RV
    [ "$skill" = review-tests ] && rt_stage off
    return 0
}
# nbj <sid> — per-call files (.bj-buf-* / .bj-out-* / .bj-err-*) left in the control dir.
nbj() { find "$(ctl "$1")" -maxdepth 1 -name '.bj-*' 2>/dev/null | grep -c .; }
# spy_on / spy_off — log each stage's BJ_JOURNAL_BUFFER / BJ_LOOP_FORMAT and each journal-flush
# argument list of the copied bin/concern-ledger to $FX_SPY_LOG.
export FX_SPY_LOG="$FX_TMP/spy.log"
spy_on() {
    mv "$ROOT/bin/concern-ledger" "$ROOT/bin/concern-ledger.spied"
    printf '%s\n' '#!/usr/bin/env bash' 'case "${1:-}" in' \
        '  stage) printf "stage buf=%s fmt=%s\n" "${BJ_JOURNAL_BUFFER:-}" "${BJ_LOOP_FORMAT:-}" >> "$FX_SPY_LOG" ;;' \
        '  journal-flush) printf "flush %s\n" "$*" >> "$FX_SPY_LOG" ;;' 'esac' \
        'exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/concern-ledger.spied" "$@"' > "$ROOT/bin/concern-ledger"
    chmod +x "$ROOT/bin/concern-ledger"
}
spy_off() { mv -f "$ROOT/bin/concern-ledger.spied" "$ROOT/bin/concern-ledger"; }
# col16 <sid> <needle> — the boundary version column of the first row carrying <needle>.
col16() { jf "$1" "$2" 16; }

case_begin "retry-after-exit-4-journals-once" "bin/lib/codex-review-loop/boundary-journal.sh"
sid="jw-retry"; seed_sid "$sid"; st seed "$sid"
reply "$sid" detail-plan 1 "NEEDS_REVISION" "$L_A5" "$L_DOC" "$MARK"
ledger_rows_lost_on_reduce on
wrap make-detail-plan "$sid"
ledger_rows_lost_on_reduce off
assert_eq "retry: a ledger that loses its rows on reduce halts round 1 (exit 4, precondition)" "4" "$W_RC"
assert_eq "retry: the halted round journals nothing" "0" "$(jall "$sid" | grep -c .)"
wrap make-detail-plan "$sid"
assert_eq "retry: the re-run of round 1 continues (exit 1)" "1" "$W_RC"
for needle in 'unquoted argument reaches eval' 'README names a removed flag' 'malicious co-tenant'; do
    assert_eq "retry: '$needle' is journaled exactly once" "1" "$(jn "$sid" "$needle")"
done
assert_eq "retry: no per-call buffer is left behind" "0" "$(nbj "$sid")"
case_end

case_begin "exit-3-codex-round-journals-nothing" "bin/lib/codex-review-loop/boundary-journal.sh"
sid="jw-exit3"; seed_sid "$sid"; st seed "$sid"
reply "$sid" detail-plan 1 "NEEDS_REVISION" "$L_A5" "$MARK"
export FX_RV=1
wrap make-detail-plan "$sid"
unset FX_RV
assert_eq "exit3: a failing codex reviewer is exit 3 (precondition)" "3" "$W_RC"
assert_eq "exit3: no journal row (Verdict no), markers on stdout included" "0" "$(jall "$sid" | grep -c .)"
assert_eq "exit3: no per-call buffer is left behind" "0" "$(nbj "$sid")"
case_end

# Every wrapper sets BJ_JOURNAL_BUFFER (its own format's buffer) before the stage and hands its own
# exit code to the flush unchanged; security-code rows carry the loop format, not the ledger format.
case_begin "buffer-before-stage-and-rc-to-flush-in-all-five-wrappers" "bin/lib/codex-review-loop/boundary-journal.sh"
SC_NR="$FX_TMP/sc-needs-revision.txt"
printf '## Concern Delta\n\n## HIGH\n%s\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n' \
    '- [HIGH] - | reviewed.txt#5 | security | axis:A5/B2 unquoted argument reaches eval' > "$SC_NR"
spy_on
for skill in make-outline-plan make-detail-plan review-plan-security review-tests review-code-security; do
    fmt="$(fmt_of "$skill")"; sid="jw-spy-$fmt"
    seed_sid "$sid"; st seed "$sid"
    reply "$sid" "$fmt" 1 "$(nr_of "$skill")" "$L_A5"
    : > "$FX_SPY_LOG"
    [ "$skill" = review-tests ] && rt_stage on
    export FX_SC_BODY="$SC_NR"
    wrap "$skill" "$sid"
    unset FX_SC_BODY
    [ "$skill" = review-tests ] && rt_stage off
    sline="$(grep '^stage ' "$FX_SPY_LOG" | head -n 1)"
    assert_eq "$skill: the round stages (precondition)" "yes" "$([ -n "$sline" ] && echo yes || echo no)"
    assert_contains "$skill: the stage sees its own format's buffer" "buf=$(ctl "$sid")/.bj-buf-$fmt-" "$sline"
    assert_contains "$skill: the stage sees BJ_LOOP_FORMAT" "fmt=$fmt" "$sline"
    assert_eq "$skill: journal-flush gets the wrapper's exit code" "$W_RC" \
        "$(sed -n 's/^flush .*--rc \([0-9]*\).*/\1/p' "$FX_SPY_LOG" | head -n 1)"
    assert_eq "$skill: the fmt column is the loop format" "$fmt" "$(jf "$sid" 'unquoted argument reaches eval' 4)"
    assert_eq "$skill: no per-call file is left behind" "0" "$(nbj "$sid")"
done
spy_off
case_end

case_begin "gate-call-shape-in-all-five-wrappers" "bin/lib/codex-review-loop/boundary-journal.sh"
for skill in make-outline-plan make-detail-plan review-plan-security review-tests review-code-security; do
    S="$SCRIPT_CHECKOUT_ROOT/skills/$skill/scripts/run-codex-review-loop.sh"
    assert_eq "$skill: bj_post_wrapper receives \"\$RC\" unchanged" "1" "$(grep -cF 'bj_post_wrapper "$RC"' "$S")"
    if [ "$skill" = review-code-security ]; then want='bj_export_hash_out "$@"'
    else want='bj_export_hash_out ${RWC_FWD_ARGS[@]+"${RWC_FWD_ARGS[@]}"}'; fi
    assert_eq "$skill: bj_export_hash_out gets the forwarded arguments" "1" "$(grep -cF -- "$want" "$S")"
done
case_end

# review-tests: the gate reads the loop's RC (0 here), not the later detect-input-error HALT.
case_begin "review-tests-input-error-after-rc-0-keeps-the-round" "skills/review-tests/scripts/run-codex-review-loop.sh"
sid="jw-rt-detect"; seed_sid "$sid"; st seed "$sid"
reply "$sid" test-review 1 "APPROVED" "$MARK" "INPUT_ERROR tests/missing.sh"
rt_stage on
wrap review-tests "$sid"
rt_stage off
assert_eq "rt-detect: detect-input-error halts the wrapper (exit 4, precondition)" "4" "$W_RC"
assert_eq "rt-detect: the RC 0 round's marker line is journaled once" "1" "$(jn "$sid" 'malicious co-tenant')"
case_end

# Depends on #2478: --prestaged-report / --fallback-brief reach the four wrappers only through
# rwc_parse_fallback_args; red (exit 3) until the rebase onto #2478.
case_begin "fallback-rounds-journal-as-cc-fallback-in-four-wrappers" "bin/lib/codex-review-loop/boundary-journal.sh"
for skill in make-outline-plan make-detail-plan review-plan-security review-tests; do
    fmt="$(fmt_of "$skill")"; agent="$(agent_of "$skill")"
    # APPROVED, marker only.
    sid="jw-fba-$fmt"; seed_sid "$sid"; st seed "$sid"
    fbreport "$FX_TMP/$sid.md" v1 "APPROVED" "$MARK"
    fbwrap "$skill" "$sid" "$FX_TMP/$sid.md"
    assert_eq "$skill fallback APPROVED: exit 0" "0" "$W_RC"
    assert_eq "$skill fallback APPROVED: the marker is journaled once" "1" "$(jn "$sid" 'malicious co-tenant')"
    assert_eq "$skill fallback APPROVED: reviewer / producer" "cc-fallback $agent" \
        "$(jf "$sid" 'malicious co-tenant' 7) $(jf "$sid" 'malicious co-tenant' 6)"
    # NEEDS_REVISION, a concern and a marker.
    sid="jw-fb-$fmt"; seed_sid "$sid"; st seed "$sid"
    fbreport "$FX_TMP/$sid.md" v1 "$(nr_of "$skill")" "$L_A5" "$MARK"
    fbwrap "$skill" "$sid" "$FX_TMP/$sid.md"
    assert_eq "$skill fallback needs-revision: exit 1" "1" "$W_RC"
    for needle in 'unquoted argument reaches eval' 'malicious co-tenant'; do
        assert_eq "$skill fallback needs-revision: '$needle' is journaled once" "1" "$(jn "$sid" "$needle")"
        assert_eq "$skill fallback needs-revision: '$needle' reviewer / producer / version" "cc-fallback $agent v1" \
            "$(jf "$sid" "$needle" 7) $(jf "$sid" "$needle" 6) $(col16 "$sid" "$needle")"
    done
    # INPUT_ERROR: exit 4, the round is given back, nothing is journaled.
    sid="jw-fbe-$fmt"; seed_sid "$sid"; st seed "$sid"
    fbreport "$FX_TMP/$sid.md" v1 "$(nr_of "$skill")" "$L_A5" "$MARK"
    { printf 'INPUT_ERROR %s/missing-input.md\n' "$P"; cat "$FX_TMP/$sid.md"; } > "$FX_TMP/$sid-e.md"
    fbwrap "$skill" "$sid" "$FX_TMP/$sid-e.md"
    assert_eq "$skill fallback INPUT_ERROR: exit 4" "4" "$W_RC"
    assert_eq "$skill fallback INPUT_ERROR: no journal row" "0" "$(jall "$sid" | grep -c .)"
    assert_eq "$skill fallback INPUT_ERROR: no per-call file is left behind" "0" "$(nbj "$sid")"
    # --fallback-brief: exec'd before bj_export_hash_out, so no journal and no .bj-* file.
    sid="jw-fbb-$fmt"; seed_sid "$sid"; st seed "$sid"
    [ "$skill" = review-tests ] && rt_stage on
    export FX_RV=1
    wrapa "$skill" "$sid" --fallback-brief
    unset FX_RV
    [ "$skill" = review-tests ] && rt_stage off
    assert_eq "$skill --fallback-brief: exit 0" "0" "$W_RC"
    assert_eq "$skill --fallback-brief: no journal row" "0" "$(jall "$sid" | grep -c .)"
    assert_eq "$skill --fallback-brief: no .bj-* file" "0" "$(nbj "$sid")"
done
case_end

# The fallback version is the agent's echo reconciled against the side record bj_export_hash_out
# writes: a matching echo keeps v1, another version or no echo gives unknown. The echo line is
# neither a concern nor a marker and leaves the verdict alone, under numbered (round 1) and cnref
# (round 2) parsing alike. Depends on #2478 (fbwrap drives make-detail-plan with --prestaged-report).
case_begin "fallback-version-echo-reconciled" "bin/lib/codex-review-loop/boundary-journal.sh"
for e in v2 -; do
    sid="jw-fbv-${e/-/none}"; seed_sid "$sid"; st seed "$sid"
    fbreport "$FX_TMP/$sid.md" "$e" "NEEDS_REVISION" "$L_A5"
    fbwrap make-detail-plan "$sid" "$FX_TMP/$sid.md"
    assert_eq "version echo '$e': the round continues (exit 1)" "1" "$W_RC"
    assert_eq "version echo '$e': the row's version is unknown" "unknown" "$(col16 "$sid" 'unquoted argument reaches eval')"
done
sid="jw-fb-detail-plan"   # round 1 (numbered, echo v1) ran in the case above
assert_eq "echo r1: the echo line is no journal row" "0" "$(jn "$sid" 'BOUNDARY_VERSION')"
fbreport "$FX_TMP/$sid-r2.md" v1 "NEEDS_REVISION" "C1: unresolved — the argument still reaches eval"
fbwrap make-detail-plan "$sid" "$FX_TMP/$sid-r2.md"
# Same verdict as feature-2478-fallback-cap: an unresolved HIGH at round 2 with no extension used.
assert_eq "echo r2 (cnref): the verdict is unchanged (exit 5)" "5" "$W_RC"
assert_eq "echo r2 (cnref): the echo line is no journal row" "0" "$(jn "$sid" 'BOUNDARY_VERSION')"
assert_eq "echo r2 (cnref): the echo line is not in the ledger" "no" "$(has "$(ctl "$sid")/detail-plan-concern-ledger.txt" 'BOUNDARY_VERSION')"
case_end

# security-code fallback with the scanner's real report shape: no codex-output block, a flat
# Concern Delta, then the echo under its own '## Boundary Version' heading.
case_begin "security-code-fallback-scanner-report" "bin/lib/codex-review-loop/boundary-journal.sh"
SCAN_HIGH='[HIGH] - | reviewed.txt#5 | security | axis:A5/B2 eval of an unquoted argument'
scan() { { printf '# Security scan\n\n## Concern Delta\n'; printf '%s\n' "$@"; printf '\n## Boundary Version\n\nBOUNDARY_VERSION: v1\n'; } ; }
scan "$SCAN_HIGH" "$MARK" > "$FX_TMP/scan-findings.md"
scan "(none)" "$MARK" > "$FX_TMP/scan-none.md"
for v in findings none; do
    sid="jw-scfb-$v"; seed_sid "$sid"; st seed "$sid"
    wrapa review-code-security "$sid" --prestaged-report "$FX_TMP/scan-$v.md" --prestaged-producer security-scanner --prestaged-exec PERFORMED
    if [ "$v" = findings ]; then want=1; else want=0; fi
    assert_eq "scanner $v: the parse stays COMPLETE (exit $want, not 4)" "$want" "$W_RC"
    assert_eq "scanner $v: the marker row (reviewer / producer / fmt / version)" "cc-fallback security-scanner security-code v1" \
        "$(jf "$sid" 'malicious co-tenant' 7) $(jf "$sid" 'malicious co-tenant' 6) $(jf "$sid" 'malicious co-tenant' 4) $(col16 "$sid" 'malicious co-tenant')"
    assert_eq "scanner $v: the echo line is no journal row" "0" "$(jn "$sid" 'BOUNDARY_VERSION')"
done
assert_eq "scanner findings: the concern row (reviewer / fmt / version)" "cc-fallback security-code v1" \
    "$(jf jw-scfb-findings 'eval of an unquoted argument' 7) $(jf jw-scfb-findings 'eval of an unquoted argument' 4) $(col16 jw-scfb-findings 'eval of an unquoted argument')"
# Control: the heading is what keeps the echo out of the Concern Delta section.
{ printf '# Security scan\n\n## Concern Delta\n%s\nBOUNDARY_VERSION: v1\n' "$SCAN_HIGH"; } > "$FX_TMP/scan-noheading.md"
plabel() { ( set +u; . "$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger.sh" >/dev/null 2>&1 || exit 127; cl_parse_anchored "$1" security-scanner "$1.norm" 2>/dev/null ) | head -n 1 | tr -d '[:space:]'; }
assert_eq "scanner control: with the heading the parse is COMPLETE" "COMPLETE" "$(plabel "$FX_TMP/scan-findings.md")"
assert_ne "scanner control: without the heading the parse is not COMPLETE" "COMPLETE" "$(plabel "$FX_TMP/scan-noheading.md")"
case_end

# Pair: the same reply through a codex round and a fallback round gives the same row except ts,
# reviewer and producer (and the session id, a different session per round). FX_MID builds the
# criteria block inside the codex stub, so the codex side record is written as a live codex run's.
# Depends on #2478: the fallback round goes through --prestaged-report on make-detail-plan.
case_begin "pair-codex-and-fallback-rows-match" "bin/lib/codex-review-loop/boundary-journal.sh"
sid="jw-pair-cx"; seed_sid "$sid"; st seed "$sid"
reply "$sid" detail-plan 1 "NEEDS_REVISION" "$L_A5" "$L_DOC" "$MARK"
export FX_MID="bash '$ROOT/bin/review-criteria-block' '$REPO' >/dev/null 2>&1"
wrap make-detail-plan "$sid"
unset FX_MID
sid="jw-pair-fb"; seed_sid "$sid"; st seed "$sid"
fbreport "$FX_TMP/$sid.md" v1 "NEEDS_REVISION" "$L_A5" "$L_DOC" "$MARK"
fbwrap make-detail-plan "$sid" "$FX_TMP/$sid.md"
for needle in 'unquoted argument reaches eval' 'README names a removed flag' 'malicious co-tenant'; do
    cx="$(jall jw-pair-cx | grep -F -- "$needle" | cut -f1,4,5,8-16)"
    fb="$(jall jw-pair-fb | grep -F -- "$needle" | cut -f1,4,5,8-16)"
    assert_eq "pair '$needle': both rounds journal it (precondition)" "yes yes" \
        "$([ -n "$cx" ] && echo yes || echo no) $([ -n "$fb" ] && echo yes || echo no)"
    assert_eq "pair '$needle': every column but ts / sid / producer / reviewer matches" "$cx" "$fb"
done
case_end

# Every stage caller must run inside run-codex-review-loop, whose buffer is flushed only after the
# wrapper's exit code (bj_post_wrapper "$RC"); a new caller would journal outside that gate.
STAGE_CALL_RE='(ledger_cli|concern-ledger"?)[[:space:]]+stage([[:space:]]|$)'
stage_callers() {
    grep -HE -- "$STAGE_CALL_RE" "$@" 2>/dev/null | grep -vE '^[^:]*:[[:space:]]*(#|printf|echo)' | cut -d: -f1 | sort -u
}
case_begin "stage-caller-allowlist-pin" "bin/concern-ledger"
mapfile -t prod < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- bin skills hooks agents | grep -v '\.md$')
assert_eq "pin: production files are listed (precondition)" "yes" "$([[ "${#prod[@]}" -gt 0 ]] && echo yes || echo no)"
got="$(cd "$SCRIPT_CHECKOUT_ROOT" && stage_callers "${prod[@]}" | paste -sd, -)"
assert_eq "pin: only the review-loop passes invoke stage" \
    "bin/lib/codex-review-loop/path-ledger-pass.sh,bin/lib/codex-review-loop/prestaged-pass.sh" "$got"
printf '%s\n' '# concern-ledger stage in a comment' "printf 'run concern-ledger stage\n'" > "$FX_TMP/pin-quiet.sh"
printf '%s\n' 'bash "$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger" stage --round 1' > "$FX_TMP/pin-fake.sh"
assert_eq "pin self-check: a fake caller is flagged, comment and printf lines are not" "$FX_TMP/pin-fake.sh" \
    "$(stage_callers "$FX_TMP/pin-quiet.sh" "$FX_TMP/pin-fake.sh")"
case_end

finish
