#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-8: THE PROTECTED PATH SITTING BESIDE THE INTERPRETER BODY.
#
# Round 8 fixed two members of ONE class: a regex whose over-matching is safe
# while it is used to EXTRACT text, reused as a PERMISSION predicate, where
# over-matching is a bypass.
#
#   Fix A (interpreter-scan.js, covered by ./cases-round7-proof.sh + the
#          `proof_scoped_*` assertions below): the proof-flag set was derived
#          from the extraction alternation, which carries pwsh's progressive
#          `-EncodedCommand` prefix chain - minimal member `-E`. Proof is now
#          KIND-SCOPED: `-En` proves a program only when the interpreter is
#          pwsh.
#   Fix B (bash-scan.js, THIS file): segmentArgvHitsProtectedArg() skipped
#          classification of EVERY argv token in a segment whose rawText matched
#          INTERPRETER_RE. Tier 2 only ever judges the EXTRACTED BODIES, so a
#          protected path parked in a SIBLING OPERAND was judged by nobody:
#
#              sh -c 'rm "$1"' _ <marker>                       -> ALLOW (bug)
#              python3 -c 'os.remove(sys.argv[1])' <marker>     -> ALLOW (bug)
#              node -e "console.log(1)" <marker>                -> ALLOW (bug)
#
#          The deferral is now per TOKEN: only a token that IS one of the
#          extracted bodies defers to the body gate.
#
# THE PAIRING IS THE POINT. A "fix" that simply DELETED the deferral would turn
# every 16-x row below green while breaking the read path RD3 opened, so the
# 16-nr rows are not decoration - 16-nr1..16-nr3 were measured to flip to BLOCK
# under a deferral-deleted mutant of bash-scan.js, and are what distinguishes
# "narrowed" from "removed". 16-nr6..16-nr9 are the #1709 read symmetry.
#
# TWO DIFFERENT REASONS FOR A BLOCK - do not conflate them:
#   * 16-o / 16-p / 16-q / 16-q2 are CORRECT blocks, not concessions. The
#     protected path IS an operand of the command, and the per-token rule
#     classifies it; argv order (16-o), body count (16-p) and how benign the
#     body reads (16-q/16-q2) are all irrelevant to that. Nothing here is
#     available to relax.
#   * ACCEPTED OVER-BLOCK (16-r..16-s only): an interpreter invoked with a
#     protected path and NO extractable body (`node <marker>`,
#     `python3 <token>`). The path is being handed to the interpreter as its
#     PROGRAM FILE, which is indistinguishable here from a write target, so
#     "cannot analyse -> fail closed" applies (HIGH-2, round 6). This is not a
#     fix-B artifact either - it blocks with fix B reverted too.
#
# Table format and placeholders: see ./cases-round6-stdin.sh.

# run_R8_sibling_operand - the nine measured ALLOW->BLOCK shapes, both protected
# families (CPR-5), across the four interpreter grammars that carry an inline
# body plus the two indirection wrappers (`xargs -I{} sh -c`, argv-index reads).
run_R8_sibling_operand() {
    _run_r6_table "R8" <<'TABLE'
16-a sh -c body, marker operand|block|sh -c 'rm "$1"' _ @DIR@/@MK@
16-b sh -c body, token operand|block|sh -c 'rm "$1"' _ @DIR@/@TOK@
16-c bash -c body, marker operand|block|bash -c 'rm "$1"' _ @DIR@/@MK@
16-d bash -c body, token operand|block|bash -c 'rm "$1"' _ @DIR@/@TOK@
16-e python3 -c argv[1] marker|block|python3 -c 'import os,sys; os.remove(sys.argv[1])' @DIR@/@MK@
16-f python3 -c argv[1] token|block|python3 -c 'import os,sys; os.remove(sys.argv[1])' @DIR@/@TOK@
16-g node -e argv[2] marker|block|node -e 'require("fs").unlinkSync(process.argv[2])' x @DIR@/@MK@
16-h node -e argv[2] token|block|node -e 'require("fs").unlinkSync(process.argv[2])' x @DIR@/@TOK@
16-i perl -e ARGV[0] marker|block|perl -e 'unlink $ARGV[0]' @DIR@/@MK@
16-j perl -e ARGV[0] token|block|perl -e 'unlink $ARGV[0]' @DIR@/@TOK@
16-k pwsh -Command args[0] marker|block|pwsh -Command 'Remove-Item $args[0]' @DIR@/@MK@
16-l pwsh -Command args[0] token|block|pwsh -Command 'Remove-Item $args[0]' @DIR@/@TOK@
16-m xargs -I{} sh -c marker|block|xargs -I{} sh -c 'rm {}' @DIR@/@MK@
16-n xargs -I{} sh -c token|block|xargs -I{} sh -c 'rm {}' @DIR@/@TOK@
TABLE
}

# run_R8_operand_seams - the same defect approached from the seams, because the
# per-token rule must not have been implemented as "the LAST argv token" or "the
# token AFTER the body":
#   16-o  protected path BEFORE the body (argv order must not matter)
#   16-p  TWO bodies, only the operand protected (a body-count heuristic fails)
#   16-q  a benign body with a protected operand - nothing in the body hints at
#         the target, so only classifying the operand itself can catch it
#   16-r/16-s  an interpreter with a protected operand and NO extractable body:
#         pinned as BLOCK deliberately (see ACCEPTED OVER-BLOCK above), so a
#         later change that starts ALLOWING `node <marker>` has to argue for it.
run_R8_operand_seams() {
    _run_r6_table "R8" <<'TABLE'
16-o operand BEFORE the body|block|node @DIR@/@MK@ -e "console.log(1)"
16-p two bodies, operand protected|block|node -e "console.log(1)" -e "console.log(2)" @DIR@/@MK@
16-q benign body, marker operand|block|node -e "console.log(1)" @DIR@/@MK@
16-q2 benign body, token operand|block|node -e "console.log(1)" @DIR@/@TOK@
16-r interpreter, no body, marker|block|node @DIR@/@MK@
16-s interpreter, no body, token|block|python3 @DIR@/@TOK@
TABLE
}

# run_R8_deferral_survives - the counterweight. RD3 (supervisor-audit round 6)
# established that an interpreter body arrives as ONE argv token holding a whole
# nested command line whose trailing `'<path>'` LOOKS like a bare path; judging
# it here would fail-close a proven-safe read before Tier 2's read-only gate ever
# ran. Fix B must keep that true.
#
# 16-nr1..16-nr3 are the DISCRIMINATING rows (measured BLOCK against a mutant
# whose deferral is deleted rather than narrowed); 16-nr4/16-nr5 are the same
# property in the two other languages. 16-nr6..16-nr9 are #1709: a guard that
# blocks READING a marker breaks the workflow it exists to protect.
run_R8_deferral_survives() {
    _run_r6_table "R8" <<'TABLE'
16-nr1 RD3 pwsh read token|approve|pwsh -Command "Get-Content -Raw '@DIR@/@TOK@'"
16-nr2 RD3 pwsh read marker|approve|pwsh -Command "Get-Content -Raw '@DIR@/@MK@'"
16-nr3 pwsh read, no -Raw|approve|pwsh -Command "Get-Content '@DIR@/@TOK@'"
16-nr4 node -e read marker|approve|node -e "console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))"
16-nr5 python3 -c read marker|approve|python3 -c "print(open('@DIR@/@MK@').read())"
16-nr6 #1709 cat marker|approve|cat @DIR@/@MK@
16-nr7 #1709 grep marker|approve|grep x @DIR@/@MK@
16-nr8 #1709 wc token|approve|wc -l @DIR@/@TOK@
16-nr9 #1709 less marker|approve|less @DIR@/@MK@
TABLE
}

# run_R8_proof_kind_scope - fix A at the hook level. The pair is the assertion:
# the SAME `-En...` prefix is proof for pwsh (17-nr1: stdin is then DATA, so the
# marker fed on `< FILE` is a read) and proves nothing for python3/node (17-a,
# 17-b: `-E` is ignore-environment there, so stdin is still PROGRAM text and the
# pipe route stays fail-closed). 17-c pins that an UNQUOTED body is not a body:
# `-EncodedCommand x` has nothing extractable, so it proves nothing even for
# pwsh - the round-7 "a bodyless flag proves nothing" rule, unchanged.
run_R8_proof_kind_scope() {
    _run_r6_table "R8" <<'TABLE'
17-a -En is not proof for python3|block|printf '%s' "import os; os.remove('@DIR@/@MK@')" | python3 -En -
17-b -Command is not proof for node|block|printf '%s' "require('fs').unlinkSync('@DIR@/@MK@')" | node -Command x
17-c pwsh -EncodedCommand, no body|block|pwsh -EncodedCommand x < @DIR@/@MK@
17-d pwsh -Command, unquoted body|block|pwsh -Command x < @DIR@/@MK@
17-nr1 -En IS proof for pwsh|approve|pwsh -EncodedCommand "x" < @DIR@/@MK@
17-nr2 -Command IS proof for pwsh|approve|pwsh -Command "Write-Output 1" < @DIR@/@MK@
TABLE
}

# run_R8_operand_unit - the MECHANISM behind the verdicts above.
#
# The hook-level rows prove the verdict changed; only the unit layer can prove
# WHY, and the why is the whole fix: the token that defers is exactly a member
# of extractAllInterpreterBodies(rawText).bodies - the set Tier 2 will actually
# judge - and a sibling operand of the SAME segment is not in that set. Any
# future predicate that is merely correlated with "is a body" (segment matches
# INTERPRETER_RE, token contains a space, token is not last) goes red here even
# if it happens to keep every hook row above green.
run_R8_operand_unit() {
    local probe="$PARTS_DIR/round8-operand-probe.js"
    if [ ! -f "$probe" ]; then
        fail "R8-U probe missing at $probe - the per-token deferral is unasserted"
        return
    fi
    local out
    out="$("$RWT" 20 node "$(node_path "$probe")" "$_AGENTS_DIR_NODE" 2>/dev/null)"
    if [ -z "$out" ]; then
        fail "R8-U probe produced no output (bash-scan.js / interpreter-scan.js not loadable)"
        return
    fi
    local _get
    _get() { printf '%s\n' "$out" | while IFS= read -r line; do
        case "$line" in "$1="*) printf '%s' "${line#*=}"; return ;; esac
    done; }

    assert_eq "R8-U segmentArgvHitsProtectedArg is exported" "true" "$(_get sea_exported)"
    # Pairs: same body alone -> null (defers), body + protected operand -> the
    # operand's kind. Deleting the deferral reds the first of each pair; the
    # pre-round-8 per-segment deferral reds the second.
    assert_eq "R8-U body defers, sibling operand does not" "true" "$(_get sea_ok)"
    assert_eq "R8-U per-token deferral has no misses" "-" "$(_get sea_bad)"
    assert_eq "R8-U a null segment yields null (no throw)" "true" "$(_get sea_null_seg)"
    assert_eq "R8-U the deferring token IS an extracted body" "true" "$(_get sea_body_extracted)"
    assert_eq "R8-U the operand is NOT an extracted body" "true" "$(_get sea_operand_not_extracted)"

    # Fix A at the unit layer: the union regex (asserted by R6-ID) answers "is
    # this a program flag AT ALL" for probes; permission decisions must ask the
    # KIND-SCOPED form, or pwsh's `-En` prefix chain grants proof to python3.
    assert_eq "R8-U inlineProgramFlagProof is exported" "true" "$(_get proof_scoped_exported)"
    assert_eq "R8-U proof is scoped to the interpreter kind" "true" "$(_get proof_scoped_ok)"
    assert_eq "R8-U kind-scoped proof has no misses" "-" "$(_get proof_scoped_bad)"
    assert_eq "R8-U isPwshWord identifies pwsh only" "true" "$(_get proof_pwsh_word)"
}
