#!/usr/bin/env bash
# tests/feature-2063-prefill-comments-contract/skill-contract.sh
# Tests: skills/workflow-init/SKILL.md, bin/workflow/render-issue-comments
# Tags: workflow-init, prompt-contract, static-grep, issue-comments, tl2, scope:issue-specific

# W1, W3, W3b, W4, W7, W8 (#2063): what the WI-12 Path B instruction must SAY — the B1 command and its flags, the shared issue number (asserted as notation AND resolved against a real two-issue driver session), the non-zero-rc rule (stated and executed), a complete renumber, and SKILL.md still under the prompt-file hard limit.

# TL3 gap: whether the agent performs the documented steps is not observable — only
# the structure of what it is told to do is. Mitigated at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# --- W1: the B1 line names the binary and both flags ---------------------------
W1_OK=1
W1_MISS=""
for tok in 'bin/workflow/render-issue-comments' '--checkpoint' '--issue'; do
    case "$B1_LINE" in *"$tok"*) ;; *) W1_OK=0; W1_MISS="$tok" ;; esac
done
if [ -n "$B1_LINE" ] && [ "$W1_OK" = "1" ]; then
    pass "W1: the B1 line names render-issue-comments, --checkpoint and --issue"
else
    fail "W1: B1 line missing '${W1_MISS:-the whole line}': '$(printf '%s' "$B1_LINE" | head -c 200)'"
fi

# --- W3: both steps address the SAME issue, from the driver's own checkpoint ----
# Deliberate coupling to SKILL.md notation (`- **B1.**`, a backtick span, the
# <CHECKPOINT>/<N> placeholders). The coupling IS the guard: Path B's call contract
# must not drift unannounced, so edit SKILL.md and this file in the same diff.
if printf '%s' "$B1_LINE" | grep -qF '<N>' && printf '%s' "$B2_LINE" | grep -qF '<N>'; then
    pass "W3: B1 and B2 share the '<N>' placeholder notation"
else
    fail "W3: '<N>' is not carried by both the B1 and B2 lines"
fi
if printf '%s' "$B1_LINE" | grep -qiE 'same|identical'; then
    pass "W3: the B1 line requires the same issue number B2 seeds"
else
    fail "W3: the B1 line does not tie its issue number to B2's"
fi
if printf '%s' "$B1_LINE" | grep -qF 'CHECKPOINT='; then
    pass "W3: the B1 line points --checkpoint at the driver's CHECKPOINT= value"
else
    fail "W3: the B1 line does not name the driver's CHECKPOINT= output"
fi

# --- W3b: the SAME instruction, resolved against a REAL multi-issue session -------
# W3 above is syntactic: it proves B1 and B2 carry the same `<N>` NOTATION, never what
# that notation resolves to. P26 (feature-2063-render-issue-comments/render-contract.sh)
# proves `--issue` selects, but from a hand-built checkpoint with no driver and no
# SKILL.md in the loop. Between them nothing covers the failure that actually damages a
# session: two issues on one workflow-init run, and the prefill seeded from the wrong
# one. So a REAL two-issue driver session is built, ISSUES[0] is read off its own
# checkpoint, and the extracted B1 command plus the writer step's own component list
# are executed against it with that real number substituted for `<N>`.
W3B_SH="$TMPD/w3b-session.sh"
W3B_CKPT="$TMPD/w3b-ckpt.json"
# A subprocess on purpose: the driver harness defines its own pass/fail/AGENTS_DIR and
# an EXIT trap that removes its temp tree, so the checkpoint is copied out before return.
cat > "$W3B_SH" <<'W3BSH'
#!/bin/bash
# argv: <agents-dir> <checkpoint-copy-destination>
set -u
. "$1/tests/feature-workflow-init-driver/driver-issue-comments/_lib.sh"
W3B_OUT_CKPT="$2"
[ -f "$DRIVER" ] || { echo "BOOTSTRAP=sut-missing"; exit 3; }
setup_case wid-2063-w3b
mock_issue 4310 OPEN "type:task" "PRIMARY-TITLE-4310"
mock_issue 4311 OPEN "type:task" "SIBLING-TITLE-4311"
mock_issue_body 4310 "PRIMARY-BODY-4310"
mock_issue_body 4311 "SIBLING-BODY-4311"
mock_issue_comments 4310 '[{"author":{"login":"alice"},"body":"PRIMARY-COMMENT-4310","createdAt":"2026-07-02T00:00:00Z"}]'
mock_issue_comments 4311 '[{"author":{"login":"dave"},"body":"SIBLING-COMMENT-4311","createdAt":"2026-07-03T00:00:00Z"}]'
set_wip 4310 same
set_wip 4311 same
run_driver '#4310' '#4311'
W3B_CK="$(get_kv CHECKPOINT)" || true
if [ -z "$W3B_CK" ] || [ ! -f "$W3B_CK" ]; then
    echo "BOOTSTRAP=no-checkpoint"
    exit 4
fi
cp "$W3B_CK" "$W3B_OUT_CKPT" || { echo "BOOTSTRAP=copy-failed"; exit 5; }
echo "BOOTSTRAP=ok"
exit 0
W3BSH
W3B_LOG="$(bash "$W3B_SH" "$AGENTS_DIR" "$W3B_CKPT" 2>&1 | grep '^BOOTSTRAP=' | tail -1)"
ckpt_field() {  # <ckpt> <dot.path> — '<missing>' / '<unreadable>' on failure
    node -e '
const fs = require("fs");
let v;
try { v = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.stdout.write("<unreadable>"); process.exit(0); }
for (const k of process.argv[2].split(".")) { if (v == null) break; v = v[k]; }
if (v === undefined || v === null) process.stdout.write("<missing>");
else if (typeof v === "object") process.stdout.write(JSON.stringify(v));
else process.stdout.write(String(v));
' "$1" "$2"
}
W3B_READY=0
if [ ! -f "$W3B_CKPT" ]; then
    fail "W3b: no two-issue driver session could be built (${W3B_LOG:-no bootstrap output}) — the multi-issue selection is not observable"
else
    W3B_FIRST="$(ckpt_field "$W3B_CKPT" state.issues.0)"
    W3B_SECOND="$(ckpt_field "$W3B_CKPT" state.issues.1)"
    W3B_SIB="$(ckpt_field "$W3B_CKPT" "state.issue_json_cache.$W3B_SECOND")"
    # Liveness: the sibling must genuinely BE in the checkpoint the command reads, or
    # "the sibling's text is absent" is a fact about data that never existed. Each leak
    # needle is re-checked against this entry below, one at a time.
    case "$W3B_SIB" in
        *SIBLING-TITLE-4311*)
            W3B_READY=1
            pass "W3b: the session cached BOTH issues (#$W3B_FIRST and #$W3B_SECOND) — the selection probe is live" ;;
        *)
            fail "W3b: the sibling issue never reached the checkpoint cache, so a leak could not show: '$(printf '%s' "$W3B_SIB" | head -c 200)'" ;;
    esac
fi
if [ "$W3B_READY" != "1" ] || [ -z "$CMD_TEMPLATE" ]; then
    fail "W3b(i): the B1 command's exit status against a real multi-issue session is not observable"
    fail "W3b(ii): ISSUES[0]'s own comment reaching the prefill is not observable"
    fail "W3b(iii): the sibling issue's comment staying OUT of the prefill is not observable"
    fail "W3b(iii): the sibling issue's title staying OUT of the prefill is not observable"
    fail "W3b(iii): the sibling issue's body staying OUT of the prefill is not observable"
else
    # The REAL number, read off the driver's own checkpoint — not the `<N>` placeholder.
    W3B_CMD="$(subst_raw "$CMD_TEMPLATE" "$W3B_CKPT" "$W3B_FIRST")"
    W3B_SECTION="$(bash -c "$W3B_CMD" 2>"$TMPD/w3b.err")"
    W3B_RC=$?
    assert_eq "W3b(i): the extracted B1 command exits 0 for ISSUES[0] of a two-issue session" "0" "$W3B_RC"
    W3B_FILE="$TMPD/issue-prefill-multi.md"
    W3B_COMPONENTS="$(writer_components "$(writer_line)")"
    if [ -z "$W3B_COMPONENTS" ]; then
        fail "W3b(ii): SKILL.md names no writer components — the assembled prefill is not observable"
        fail "W3b(iii): SKILL.md names no writer components — the sibling-absence hunt is not observable"
    else
        assemble_prefill "$W3B_FILE" "$W3B_COMPONENTS" "$W3B_FIRST" \
            "$(ckpt_field "$W3B_CKPT" "state.issue_json_cache.$W3B_FIRST.title")" \
            "$(ckpt_field "$W3B_CKPT" "state.issue_json_cache.$W3B_FIRST.body")" \
            "$W3B_SECTION"
        # Positive first: every absence assertion below is gated on it, so a prefill that
        # rendered nothing at all is reported unmet rather than trivially clean.
        W3B_LIVE=0
        if grep -qF -- 'PRIMARY-COMMENT-4310' "$W3B_FILE" 2>/dev/null; then
            W3B_LIVE=1
            pass "W3b(ii): ISSUES[0]'s own comment is in the assembled prefill"
        else
            fail "W3b(ii): ISSUES[0]'s comment never reached the prefill: '$(head -c 200 "$W3B_FILE" 2>/dev/null)' err='$(head -c 160 "$TMPD/w3b.err")'"
        fi
        for W3B_NEEDLE in SIBLING-COMMENT-4311 SIBLING-TITLE-4311 SIBLING-BODY-4311; do
            if [ "$W3B_LIVE" != "1" ]; then
                fail "W3b(iii): '$W3B_NEEDLE' absence is unfalsifiable — nothing of ISSUES[0] was assembled either"
            elif ! printf '%s' "$W3B_SIB" | grep -qF -- "$W3B_NEEDLE"; then
                fail "W3b(iii): '$W3B_NEEDLE' is not in the sibling's own cache entry — its absence from the prefill proves nothing"
            elif grep -qF -- "$W3B_NEEDLE" "$W3B_FILE" 2>/dev/null; then
                fail "W3b(iii): the sibling issue's '$W3B_NEEDLE' leaked into ISSUES[0]'s prefill"
            else
                pass "W3b(iii): the sibling issue's '$W3B_NEEDLE' is absent from ISSUES[0]'s prefill"
            fi
        done
    fi
fi

# --- W4: the non-zero-rc contract is both stated and observable ------------------
# A fabricated "no comments" placeholder written after a failed fetch is
# indistinguishable from truth downstream, so both halves are asserted.
if printf '%s' "$B1_LINE" | grep -qiE 'non-?zero|rc[^0-9]*(!|not )'; then
    pass "W4: the B1 line states the non-zero-rc rule"
else
    fail "W4: the B1 line does not state the non-zero-rc rule: '$(printf '%s' "$B1_LINE" | head -c 200)'"
fi
if printf '%s' "$B2_LINE" | grep -qi 'omit'; then
    pass "W4: the B2 line requires omitting the section"
else
    fail "W4: the B2 line does not say to omit the section"
fi
if printf '%s' "$B2_LINE" | grep -qiE 'fabricat|invent|substitut'; then
    pass "W4: the B2 line forbids fabricating a replacement"
else
    fail "W4: the B2 line does not forbid fabricating a replacement"
fi
if [ -z "$CMD_TEMPLATE" ]; then
    fail "W4: degraded-run exit code not observable (no command to execute)"
    fail "W4: degraded-run stdout not observable (no command to execute)"
else
    CMD_BROKEN="$(subst_raw "$CMD_TEMPLATE" "$CKPT_BROKEN" "$N")"
    W4_OUT="$(bash -c "$CMD_BROKEN" 2>"$TMPD/w4.err")"
    W4_RC=$?
    assert_eq "W4: a state-less checkpoint exits 3 through the B1 command" "3" "$W4_RC"
    assert_eq "W4: the degraded run writes nothing to stdout" "" "$W4_OUT"
fi

# --- W7: the renumber is complete and left nothing dangling --------------------
PATH_B="$(path_b_section)"
if printf '%s\n' "$PATH_B" | grep -qF -- '- **B3.**' && printf '%s\n' "$PATH_B" | grep -qF -- '- **B4.**'; then
    pass "W7: Path B carries the renumbered B3 and B4 steps"
else
    fail "W7: Path B is missing B3 and/or B4 after the renumber"
fi
for lbl in B1 B2 B3 B4; do
    W7_C="$(printf '%s\n' "$PATH_B" | grep -cF -- "- **$lbl.**" || true)"
    assert_eq "W7: Path B declares $lbl exactly once" "1" "$W7_C"
done
W7_MARK="$(printf '%s\n' "$PATH_B" | grep -cF 'WORKFLOW_MARK_STEP_workflow_init_complete' || true)"
assert_eq "W7: the completion sentinel appears exactly once in Path B" "1" "$W7_MARK"
W7_STALE="$(grep -rEl -- 'WI-12 B[23]' "$AGENTS_DIR/skills" "$AGENTS_DIR/tests" "$AGENTS_DIR/CLAUDE.md" --exclude="$SUITE_NAME.sh" --exclude-dir="$SUITE_NAME" 2>/dev/null || true)"
if [ -z "$W7_STALE" ]; then
    pass "W7: no stale Path B step references remain in skills/, tests/ or CLAUDE.md"
else
    fail "W7: stale Path B step references survive in: $(printf '%s' "$W7_STALE" | tr '\n' ' ')"
fi

# --- W8: the added lines did not push SKILL.md past the prompt-file hard limit --
W8_LINES="$(awk 'END{print NR}' "$SKILL" 2>/dev/null || echo 0)"
if [ "${W8_LINES:-0}" -lt 200 ]; then
    pass "W8: SKILL.md is $W8_LINES lines (under the 200-line HARD limit)"
else
    fail "W8: SKILL.md is $W8_LINES lines (at or over the 200-line HARD limit)"
fi

finish
