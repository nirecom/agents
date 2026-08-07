#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-9 HIGH-1: A `-c`-CLUSTER FLAG ON A COMMAND THAT IS NOT AN INTERPRETER.
#
# Round 8 narrowed segmentArgvHitsProtectedArg()'s RD3 deferral from per-SEGMENT
# to per-TOKEN by building the deferral set from
# extractAllInterpreterBodies(seg.rawText).bodies. That set is consumed in the
# PERMISSION direction — membership SKIPS bare-path classification and hands the
# token to Tier 2 — but it was built from an EXTRACTION alternation (FLAG_ALTS)
# whose regex does not require an interpreter NAME anywhere in the segment, while
# Tier 2 only runs when looksLikeInterpreterInvocation() says so.
#
# So any ORDINARY command carrying a `-c`-cluster flag had its quoted next token
# swallowed by a deferral to a gate that then bailed at the interpreter check —
# and the token was judged by NOBODY:
#
#     tar  -cf  '<wf>/<sid>.workflow-off' /tmp/x     -> ALLOW (bug)
#     install /tmp/src -c '<wf>/<sid>.workflow-off'  -> ALLOW (bug)
#     ar -rc / zip -c / cpio -oc / xz -c / find -exec-> ALLOW (bug)
#
# `tar -cf` is the sharpest member: it CREATES the named file, and
# hooks/lib/session-markers.js authorizes on a marker's EXISTENCE alone, so one
# `tar -cf '<wf>/<sid>.workflow-off' /tmp/x` mints full WORKFLOW_OFF clearance.
#
# The fix builds the deferral set only when looksLikeInterpreterInvocation()
# holds — defer ONLY to a judge that will actually run.
#
# TWO DIFFERENT REASONS FOR A BLOCK — do not conflate them:
#
#   * CORRECT BLOCKS, nothing here is available to relax (18-a..18-d, 18-i,
#     18-t*, 18-r*): the protected path is the command's own WRITE TARGET.
#     `tar -cf X`, `ar -rc X`, `zip -c X` and `install SRC -c DST` all CREATE X.
#     18-i is the same statement for the workflow-dir glob verdict, which the
#     deferral swallowed too.
#   * ACCEPTED OVER-BLOCK (18-e..18-h, 18-m1..18-m3): a command this scanner
#     does not recognize, naming a protected path on its argv. `xz -c FILE`
#     READS FILE, `find -exec FILE \;` EXECUTES it, and `foo`/`cpio`'s operand
#     may be ignored entirely — none of them writes. They block because
#     bash-scan.js's documented policy is that an unrecognized command naming a
#     protected path is a hit (READ_ONLY_ARG_COMMAND_RE is an allowlist, and
#     `less -o` is why membership is granted to a NAME only after a per-option
#     sweep). Relaxing any of these means extending that allowlist as a CLASS
#     (CPR-E2C), never special-casing one row here.
#
# WHICH MECHANISM IS RESPONSIBLE — the controls are not decoration. 18-c1..18-c3
# were measured BLOCK against the pre-fix code as well, and they are what pins
# the defect to the flag-cluster deferral rather than to "bare paths are not
# classified at all":
#   18-c1  the SAME `tar -cf` with the path UNQUOTED (no quoted body to extract)
#   18-c2  `foo -x '<marker>'` — a flag OUTSIDE the `-c` cluster
#   18-c3  `tar -cf '/tmp/a.tar' '<marker>'` — only the token immediately AFTER
#          the flag was swallowed, so the SECOND operand always blocked
#
# THE PAIRING IS THE POINT (CPR-ORTH). A "fix" that simply deleted the deferral
# would turn every 18-x row green while re-breaking the RD3 read path round 8
# exists to protect, so 18-nr1..18-nr7 are load-bearing: they are the round-8
# deferral rows re-asserted under this file's change, plus the #1709 plain reads.
# 18-nn1/18-nn2 are the over-block controls — ordinary `tar`/`install` naming no
# protected path at all.
#
# Table format and placeholders: see ./cases-round6-stdin.sh.

# --- payload-shape builders (M-1 / round-4 H-1) -----------------------------
# The same command text must reach the same verdict through all three
# command-executing tools. runCommands is probed at commands[1] on purpose: an
# index-0 hit is indistinguishable from the pre-fix behaviour once the array is
# joined, so a suite that only probed commands[0] would stay green against a
# regression in the array path.
_r9_mk_terminal_input() {
    printf '{"tool_name":"runInTerminal","session_id":"wsid","cwd":"%s","tool_input":{"command":"%s"}}' \
        "$(_r6_json_esc "$2")" "$(_r6_json_esc "$1")"
}
_r9_mk_commands_input() {
    printf '{"tool_name":"runCommands","session_id":"wsid","cwd":"%s","tool_input":{"commands":["echo start","%s"]}}' \
        "$(_r6_json_esc "$2")" "$(_r6_json_esc "$1")"
}

# run_R9_flag_cluster - the measured ALLOW->BLOCK shapes. Both protected
# families where the shape allows it (CPR-ORTH).
run_R9_flag_cluster() {
    _run_r6_table "R9" <<'TABLE'
18-a tar -cf creates marker|block|tar -cf '@DIR@/@MK@' /tmp/x
18-b tar -cf creates token|block|tar -cf '@DIR@/@TOK@' /tmp/x
18-c install -c dest marker|block|install /tmp/src -c '@DIR@/@MK@'
18-d ar -rc archive marker|block|ar -rc '@DIR@/@MK@' /tmp/x
18-t1 zip -c archive marker|block|zip -c '@DIR@/@MK@' /tmp/x
18-r1 tar -cf marker, cwd-relative dir|block|cd @DIR@ && tar -cf '@MK@' /tmp/x
18-e cpio -oc token operand|block|cpio -oc '@DIR@/@TOK@' < /tmp/x
18-f xz -c marker operand|block|xz -c '@DIR@/@MK@'
18-g find -exec marker|block|find /tmp -exec '@DIR@/@MK@' \;
18-h find -exec token|block|find /tmp -exec '@DIR@/@TOK@' \;
18-i tar -cf workflow-dir glob|block|tar -cf '@DIR@/*' /tmp/x
18-m1 synthetic -ce cluster|block|foo -ce '@DIR@/@MK@'
18-m2 synthetic --eval flag|block|foo --eval '@DIR@/@TOK@'
18-m3 synthetic -abc cluster|block|foo -abc '@DIR@/@MK@'
TABLE
}

# run_R9_flag_cluster_controls - which mechanism is responsible, plus the
# over-block controls. 18-c1..18-c3 blocked BEFORE the fix too; if any of them
# ever goes red the defect has moved and the 18-x rows above stop proving what
# this file claims they prove.
run_R9_flag_cluster_controls() {
    _run_r6_table "R9" <<'TABLE'
18-c1 pre-fix control: unquoted operand|block|tar -cf @DIR@/@MK@ /tmp/x
18-c2 pre-fix control: flag outside cluster|block|foo -x '@DIR@/@MK@'
18-c3 pre-fix control: second operand|block|tar -cf '/tmp/a.tar' '@DIR@/@MK@'
18-nn1 ordinary tar|approve|tar -cf /tmp/a.tar /tmp/x
18-nn2 ordinary install -c|approve|install /tmp/src -c /tmp/dst
18-nn3 ordinary zip -c|approve|zip -c /tmp/a.zip /tmp/x
18-nn4 ordinary find -exec|approve|find /tmp -exec /bin/true \;
TABLE
}

# run_R9_deferral_intact - the counterweight (CPR-ORTH). The gate NARROWS the
# deferral set; it must not delete it. Every row here is a deferral that must
# still happen: an interpreter body whose trailing `'<path>'` merely LOOKS like
# a bare path (RD3), and the #1709 plain reads that a marker guard must never
# break. All were measured BLOCK against a deferral-DELETED mutant.
run_R9_deferral_intact() {
    _run_r6_table "R9" <<'TABLE'
18-nr1 RD3 pwsh read token|approve|pwsh -Command "Get-Content -Raw '@DIR@/@TOK@'"
18-nr2 RD3 pwsh read marker|approve|pwsh -Command "Get-Content -Raw '@DIR@/@MK@'"
18-nr3 RD3 pwsh read, no -Raw|approve|pwsh -Command "Get-Content '@DIR@/@MK@'"
18-nr4 #1709 cat marker|approve|cat @DIR@/@MK@
18-nr5 #1709 grep marker|approve|grep x @DIR@/@MK@
18-nr6 #1709 wc token|approve|wc -l @DIR@/@TOK@
18-nr7 #1709 less marker|approve|less @DIR@/@MK@
TABLE
}

# run_R9_flag_cluster_payloads - the SAME defect delivered through the other two
# command-executing tools. The scanner is shared, but the payload shapes are not
# (Bash/runInTerminal: `command` string; runCommands: `commands` ARRAY), and a
# shape that never reaches the scanner is a full bypass regardless of how good
# the scanner is.
run_R9_flag_cluster_payloads() {
    local mk="$SID.workflow-off" tok="$SID.off-clearance"
    local cmd_mk="tar -cf '$WFDIR/$mk' /tmp/x"
    local cmd_tok="install /tmp/src -c '$WFDIR/$tok'"
    local benign="tar -cf /tmp/a.tar /tmp/x"

    assert_block "R9 18-p1 runInTerminal tar -cf marker" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r9_mk_terminal_input "$cmd_mk" "$LINKED_WT")")"
    assert_block "R9 18-p2 runInTerminal install -c token" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r9_mk_terminal_input "$cmd_tok" "$LINKED_WT")")"
    assert_approve "R9 18-p3 runInTerminal ordinary tar" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r9_mk_terminal_input "$benign" "$LINKED_WT")")"

    assert_block "R9 18-p4 runCommands[1] tar -cf marker" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r9_mk_commands_input "$cmd_mk" "$LINKED_WT")")"
    assert_block "R9 18-p5 runCommands[1] install -c token" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r9_mk_commands_input "$cmd_tok" "$LINKED_WT")")"
    assert_approve "R9 18-p6 runCommands[1] ordinary tar" \
        "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r9_mk_commands_input "$benign" "$LINKED_WT")")"
}
