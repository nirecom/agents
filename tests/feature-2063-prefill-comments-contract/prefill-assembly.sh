#!/usr/bin/env bash
# tests/feature-2063-prefill-comments-contract/prefill-assembly.sh
# Tests: skills/workflow-init/SKILL.md, bin/workflow/render-issue-comments
# Tags: workflow-init, prompt-contract, static-grep, issue-comments, tl2, scope:issue-specific

# W2, W5, W5b, W6, W11, W14 (#2063): run what SKILL.md says to run, assemble the prefill from the literal directives its own writer step carries, prove the assembly is byte-identical to the golden, sensitive to those literals, idempotent across a re-seed, and that a non-zero B1 leaves no comments section behind.

# TL3 gap: whether the agent performs the documented steps is not observable — only
# the structure of what it is told to do is. Mitigated at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# --- W2 (load-bearing): run what SKILL.md actually says to run -----------------
W2_OUT=""
if [ -z "$CMD_TEMPLATE" ]; then
    fail "W2: no backtick-quoted render-issue-comments command on the B1 line"
    fail "W2(i): exit status not observable (no command to execute)"
    fail "W2(ii): stdout heading not observable (no command to execute)"
    fail "W2(iii): comment bodies not observable (no command to execute)"
    fail "W2(iv): sentinel stripping not observable (no command to execute)"
else
    CMD="$(subst_raw "$CMD_TEMPLATE" "$CKPT" "$N")"
    pass "W2: a runnable command string was extracted from the B1 line"
    W2_OUT="$(bash -c "$CMD" 2>"$TMPD/w2.err")"
    W2_RC=$?
    assert_eq "W2(i): the extracted B1 command exits 0" "0" "$W2_RC"
    case "$W2_OUT" in
        '## Issue comments'*) pass "W2(ii): stdout begins with '## Issue comments'" ;;
        *) fail "W2(ii): stdout does not begin with the heading: '$(printf '%s' "$W2_OUT" | head -c 160)' err='$(head -c 160 "$TMPD/w2.err")'" ;;
    esac
    W2_BODIES=1
    case "$W2_OUT" in *'first prefill remark'*) ;; *) W2_BODIES=0 ;; esac
    case "$W2_OUT" in *' removed'*) ;; *) W2_BODIES=0 ;; esac
    if [ "$W2_BODIES" = "1" ]; then
        pass "W2(iii): both comment bodies reached stdout"
    else
        fail "W2(iii): a comment body is missing from stdout"
    fi
    case "$W2_OUT" in
        *'<<WORKFLOW'*) fail "W2(iv): a workflow sentinel survived into the prefill seed" ;;
        *) pass "W2(iv): no '<<WORKFLOW' byte survives into the prefill seed" ;;
    esac
fi

# --- W5: the prefill assembled FROM THE INSTRUCTION matches the golden ----------
# Both the ORDER and the LITERAL BYTES come from the directive list parsed out of
# SKILL.md's own writer step; this file composes nothing. A harness that wrote the
# document from its own idea of the format would pass whatever SKILL.md said — the
# cross-component false-green C2 raised. The golden pins element order, the blank-line
# boundaries, verbatim reuse of the CLI output and the renderer's intra-block spacing;
# W5b proves the comparison is actually sensitive to what SKILL.md carries.
PREFILL="$TMPD/issue-prefill.md"
: > "$PREFILL"
WRITER_LINE="$(writer_line)"
W5_COMPONENTS=""
if [ -z "$WRITER_LINE" ]; then
    fail "W5: no Path B step writes issue-prefill.md"
    fail "W5: the writer step's component order is not observable (no writer step)"
    fail "W5: the writer step's replace semantics are not observable (no writer step)"
    fail "W5: the writer step forbidding append is not observable (no writer step)"
else
    pass "W5: a Path B step writes issue-prefill.md"
    W5_COMPONENTS="$(writer_components "$WRITER_LINE")"
    assert_eq "W5: the writer step names seed, title, body, then B1's rendered comments" \
        "SEED TITLE BODY COMMENTS" "$W5_COMPONENTS"
    # A clause the parser cannot classify is reported, never dropped: silently skipping
    # it is how an instruction drifts out from under a still-green component assertion.
    case " $W5_COMPONENTS " in
        *' UNKNOWN '*)
            fail "W5: the writer step carries a clause the directive parser does not recognize — update SKILL.md and this parser in one diff: $(grep -m1 '^UNKNOWN' "$WRITER_DIRECTIVES" 2>/dev/null | head -c 200)" ;;
        *)
            pass "W5: every clause of the writer step classified as a known directive" ;;
    esac
    if grep -q '^SEP' "$WRITER_DIRECTIVES" 2>/dev/null; then
        pass "W5: the writer step names the one-blank-line separator between elements"
    else
        fail "W5: the writer step names no separator, so the element boundaries are undefined: '$(printf '%s' "$WRITER_LINE" | head -c 200)'"
    fi
    if printf '%s' "$WRITER_LINE" | grep -qiE 'write|overwrite|rewrite|replace'; then
        pass "W5: the writer step states a whole-file write"
    else
        fail "W5: the writer step names no write verb, so re-running it has no defined effect: '$(printf '%s' "$WRITER_LINE" | head -c 200)'"
    fi
    if printf '%s' "$WRITER_LINE" | grep -qiE 'append|add to the end'; then
        fail "W5: the writer step says to append — a resumed WI-12 would then double the comments section"
    else
        pass "W5: the writer step never says to append"
    fi
    assemble_prefill "$PREFILL" "$W5_COMPONENTS" "$N" "$TITLE" "$BODY" "$W2_OUT"
fi
W5_MATCHED=0
if [ ! -f "$GOLDEN" ]; then
    fail "W5: golden fixture missing at $GOLDEN"
elif cmp -s "$PREFILL" "$GOLDEN"; then
    W5_MATCHED=1
    pass "W5: the assembled prefill is byte-identical to the golden fixture"
else
    fail "W5: prefill differs from the golden: $(diff -u "$GOLDEN" "$PREFILL" 2>/dev/null | head -20 | tr '\n' '~')"
fi

# --- W5b: the golden comparison is SENSITIVE to SKILL.md's own literals ----------
# W5 matching proves the bytes agree; it does not prove they came from the instruction
# rather than from a constant in this harness. So one literal in the extracted directive
# list is perturbed and the SAME assembly must stop matching. If it still matches, the
# document is being composed from something other than SKILL.md and every W5-family
# assertion is decorative — precisely the false-green C2 named.
W5B_TSV="$TMPD/writer-directives-mutant.tsv"
W5B_FILE="$TMPD/issue-prefill-mutant.md"
if [ "$W5_MATCHED" != "1" ]; then
    fail "W5b: the base assembly does not match the golden yet, so perturbing it proves nothing"
elif ! node -e '
const fs = require("fs");
const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => l !== "");
const i = rows.findIndex((l) => !/^(SEP|COMMENTS)\t/.test(l));
if (i < 0) process.exit(9);
rows[i] = rows[i] + " MUTANT";
fs.writeFileSync(process.argv[2], rows.map((l) => l + "\n").join(""));
' "$WRITER_DIRECTIVES" "$W5B_TSV" 2>/dev/null; then
    fail "W5b: no literal directive could be perturbed — the sensitivity control cannot run"
else
    _W5B_SAVED="$WRITER_DIRECTIVES"
    WRITER_DIRECTIVES="$W5B_TSV"
    assemble_prefill "$W5B_FILE" "$W5_COMPONENTS" "$N" "$TITLE" "$BODY" "$W2_OUT"
    WRITER_DIRECTIVES="$_W5B_SAVED"
    if cmp -s "$W5B_FILE" "$GOLDEN"; then
        fail "W5b: a perturbed SKILL.md literal still assembled the golden — the prefill is not built from the instruction"
    else
        pass "W5b: perturbing one SKILL.md literal changes the assembled prefill"
    fi
fi

# --- W6: the blank-line boundary, independent of the golden --------------------
# Without it the body's last line and the heading collapse into one paragraph.
W6_PREV="$(node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
const i = lines.indexOf("## Issue comments");
process.stdout.write(i < 0 ? "<<ABSENT>>" : (i === 0 ? "<<FIRST-LINE>>" : lines[i - 1]));
' "$PREFILL")"
assert_eq "W6: the line before '## Issue comments' is blank" "" "$W6_PREV"
W6_COUNT="$(grep -c '^## Issue comments$' "$PREFILL" || true)"
assert_eq "W6: '## Issue comments' appears exactly once in the prefill" "1" "$W6_COUNT"

# --- W11 (idempotency): re-seeding the same state overwrites, never appends -----
# The prefill is rewritten on every resume of WI-12. A consumer that appended would
# double the comments section and the agent would read the issue twice.
if [ -z "$CMD_TEMPLATE" ]; then
    fail "W11: repeated B1 runs are byte-identical (no command to execute)"
    fail "W11: the re-assembled prefill is byte-identical (no command to execute)"
    fail "W11: '## Issue comments' still appears exactly once (no command to execute)"
else
    CMD_AGAIN="$(subst_raw "$CMD_TEMPLATE" "$CKPT" "$N")"
    W11_A="$(bash -c "$CMD_AGAIN" 2>/dev/null)"
    W11_B="$(bash -c "$CMD_AGAIN" 2>/dev/null)"
    if [ -z "$W11_A" ]; then
        fail "W11: repeated B1 runs are byte-identical — the first run rendered nothing"
    else
        assert_eq "W11: repeated B1 runs against one checkpoint are byte-identical" "$W11_A" "$W11_B"
    fi
    # Seeded with a stale document first: that is what makes "replaces" distinguishable
    # from "appends" — an appending consumer keeps the stale line and ships two comments
    # sections. The re-assembly runs through the SKILL.md-derived component list, so it
    # reproduces the instruction's write rather than a shape invented here.
    W11_FILE="$TMPD/issue-prefill-idem.md"
    printf 'STALE CONTENT FROM AN EARLIER RUN\n\n## Issue comments\n\n> stale remark\n' > "$W11_FILE"
    if [ -z "$W5_COMPONENTS" ]; then
        fail "W11: re-assembly is not observable (SKILL.md names no writer components)"
        fail "W11: stale-content replacement is not observable (SKILL.md names no writer components)"
        fail "W11: '## Issue comments' count after re-seeding is not observable"
        fail "W11: 'Comment 1' count after re-seeding is not observable"
    else
    for _ in 1 2; do
        assemble_prefill "$W11_FILE" "$W5_COMPONENTS" "$N" "$TITLE" "$BODY" "$W11_B"
    done
    W11_STALE="$(grep -c 'STALE CONTENT FROM AN EARLIER RUN' "$W11_FILE" || true)"
    assert_eq "W11: the earlier document is replaced, not appended to" "0" "$W11_STALE"
    if cmp -s "$W11_FILE" "$PREFILL"; then
        pass "W11: the re-assembled prefill is byte-identical to the first assembly"
    else
        fail "W11: re-assembly drifted: $(diff -u "$PREFILL" "$W11_FILE" 2>/dev/null | head -10 | tr '\n' '~')"
    fi
    W11_H="$(grep -c '^## Issue comments$' "$W11_FILE" || true)"
    assert_eq "W11: '## Issue comments' still appears exactly once after re-seeding" "1" "$W11_H"
    W11_C="$(grep -cE '^### Comment 1 — ' "$W11_FILE" || true)"
    assert_eq "W11: 'Comment 1' still appears exactly once after re-seeding" "1" "$W11_C"
    # Every OTHER component gets the same exactly-once count, not just the comments
    # section (CPR-ORTH). `cmp` above already fails on a doubled document, but it reports
    # "drifted" — these say WHICH element was written twice, and they are the assertions
    # that survive if the golden ever changes shape.
    W11_SEED="$(grep -c 'seed for clarify-intent' "$W11_FILE" || true)"
    assert_eq "W11: the clarify-intent seed marker is written exactly once" "1" "$W11_SEED"
    W11_TITLE="$(grep -c "^# Issue #$N: " "$W11_FILE" || true)"
    assert_eq "W11: the issue title heading is written exactly once" "1" "$W11_TITLE"
    W11_BODY="$(grep -c 'Prefill fixture body line one\.' "$W11_FILE" || true)"
    assert_eq "W11: the issue body is written exactly once" "1" "$W11_BODY"
    fi
fi

# --- W14 (C2): a FAILED B1 run leaves no comments section behind -----------------
# W2/W5/W11 all follow the success path. The path that actually damages a session is the
# other one: B1 exits non-zero (any of the seven reason tokens), and the writer step must
# then produce a prefill with NO comments section at all — not a heading with nothing
# under it, and above all not the CLI's diagnostic pasted in as if it were issue content.
# A stderr token embedded in the prefill would be read by clarify-intent as part of the
# user's issue, which is how "checkpoint_unreadable" ends up quoted back as a requirement.
W14_ERR="$TMPD/w12.err"
if [ -z "$CMD_TEMPLATE" ]; then
    fail "W14: B1's failure behaviour is not observable (no command to execute)"
    fail "W14: the writer step's failure rule is not observable (no command to execute)"
    fail "W14: the failure-path prefill is not observable (no command to execute)"
else
    W14_CMD="$(subst_raw "$CMD_TEMPLATE" "$CKPT_BROKEN" "$N")"
    W14_RC=0
    W14_OUT="$(bash -c "$W14_CMD" 2>"$W14_ERR")" || W14_RC=$?
    # An ABSENT CLI also exits non-zero with empty stdout and a one-line diagnostic, so
    # every assertion in this case would be satisfied by a command that never ran. The
    # bridge's own existence is therefore checked, not inferred from the exit status.
    if [ ! -f "$AGENTS_DIR/bin/workflow/render-issue-comments" ]; then
        fail "W14(i): bin/workflow/render-issue-comments does not exist — its failure path is not observable"
        fail "W14(i): a failed B1 run writing nothing to stdout is not observable"
    elif [ "$W14_RC" = "0" ]; then
        fail "W14(i): B1 exits 0 against a container-corrupt checkpoint — the failure path cannot be entered"
    else
        pass "W14(i): B1 exits non-zero ($W14_RC) against a container-corrupt checkpoint"
        assert_eq "W14(i): a failed B1 run writes nothing to stdout" "" "$W14_OUT"
    fi
    # The rule itself lives in SKILL.md: the prompt layer is the only place that can
    # decide to drop the component, so the instruction must SAY so. A writer step that
    # is silent about the failure leaves the agent to improvise, and "paste whatever the
    # command printed" is the improvisation this case exists to forbid.
    W14_SECTION="$(path_b_section)"
    if printf '%s' "$W14_SECTION" | grep -qiE '(non-zero|nonzero|fails?|failure|exit(s)? [1-9]|error)' \
        && printf '%s' "$W14_SECTION" | grep -qiE '(omit|skip|without|do not (write|include|add)|leave out|no comments section)'; then
        pass "W14(ii): Path B states that a failed B1 means the comments section is omitted"
    else
        fail "W14(ii): Path B names no rule for a non-zero B1 exit, so the failure output's fate is undefined: '$(printf '%s' "$W14_SECTION" | tr '\n' '~' | head -c 240)'"
    fi
    # And the consequence, assembled through the same SKILL.md-derived component list with
    # COMMENTS dropped — which is what that rule prescribes. Gated on the success assembly
    # having really produced a section: without that, "the heading is absent" is a fact
    # about a document nothing ever wrote a heading into.
    W14_FILE="$TMPD/issue-prefill-failed.md"
    if ! grep -q '^## Issue comments$' "$PREFILL" 2>/dev/null; then
        fail "W14(iii): the success assembly produced no comments section — its absence here would prove nothing"
    elif [ -z "$W5_COMPONENTS" ]; then
        fail "W14(iii): the failure-path assembly is not observable (SKILL.md names no writer components)"
    else
        W14_KEPT="$(printf '%s' "$W5_COMPONENTS" | tr ' ' '\n' | grep -v '^COMMENTS$' | tr '\n' ' ')"
        assemble_prefill "$W14_FILE" "$W14_KEPT" "$N" "$TITLE" "$BODY" ""
        W14_H="$(grep -c '^## Issue comments$' "$W14_FILE" || true)"
        assert_eq "W14(iii): a failed B1 leaves no '## Issue comments' heading at all" "0" "$W14_H"
        W14_TITLE_KEPT="$(grep -c "^# Issue #$N: " "$W14_FILE" || true)"
        assert_eq "W14(iii): the rest of the prefill is still written (title present)" "1" "$W14_TITLE_KEPT"
        W14_TOKEN="$(head -c 400 "$W14_ERR" 2>/dev/null | tr -d '\r\n')"
        if [ ! -f "$AGENTS_DIR/bin/workflow/render-issue-comments" ]; then
            fail "W14(iv): the diagnostic under test would be the shell's own 'not found' — the leak check is not observable"
        elif [ -z "$W14_TOKEN" ]; then
            fail "W14(iv): B1 printed no diagnostic, so the leak check has nothing to hunt for"
        elif grep -qF -- "$W14_TOKEN" "$W14_FILE" 2>/dev/null; then
            fail "W14(iv): B1's diagnostic was written into the prefill: '$W14_TOKEN'"
        else
            pass "W14(iv): B1's diagnostic reaches no part of the prefill"
        fi
    fi
fi

# W13 is deliberately not implemented. The literal request behind C2 is an end-to-end run
# of workflow-init's own SKILL.md — the agent reading Path B, invoking B1 itself, and
# writing issue-prefill.md from what came back. SKILL.md is prose addressed to an LLM, not
# a shell-executable artifact: the only executor is a live `claude -p` session with tool
# use recorded, which rules/test/claude-e2e.md gates behind RUN_TL3 and which this suite
# has no runner for. Simulating it here would assert against a re-implementation of the
# instruction rather than the instruction, so the gap is named instead of faked.
echo "SKIP: W13/skill-orchestration-e2e: Skipped-Because: executing workflow-init's Path B as written requires a live LLM session (rules/test/claude-e2e.md, RUN_TL3); W2/W5/W11/W14 execute the command and component list extracted FROM that prose, which is the closest observable proxy — mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration"

finish
