#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-10 MEDIUM-1: A TARGET ASSEMBLED BY COMMAND SUBSTITUTION.
#
# Before this fix a write target that could not be resolved statically was simply
# approved, so the protected basename never had to appear in the command at all:
#
#     touch "$(printf '%s%s' <wf>/<sid>.workflow -off)"   -> APPROVE (hole)
#     touch <wf>/<sid>.workflow$(printf -- -off)          -> APPROVE (hole)
#
# The fix judges an unresolved target by the EVIDENCE the command text still
# carries - the assignment text, the raw word and the substitution body are each
# examined for a path fragment that resolves INSIDE the workflow directory, or for
# a residual expansion sitting in a basename whose directory is the workflow
# directory (including the `cd <wf> && …` relative case). A hit yields the
# "workflow-dynamic" verdict: fail closed, because an unanalysable target aimed at
# the one directory whose files ARE the authorization cannot be waved through.
#
# THE COST IS PAID BY ORDINARY WORK, so the must-stay-ALLOW set below is not a
# courtesy - it is the constraint that keeps the rule usable. `> "$(mktemp)"`,
# `T=$(mktemp); > "$T"`, `> $LOG`, `> "$OUT"` and `> $TMPDIR/out.txt` are the
# everyday dynamic targets; every one of them is unresolved, and every one must
# stay approved. That is what the "aimed at the workflow directory" qualifier buys.
#
# FOLLOW-ON NARROWING (10-m1x rows). Making a residual `$` suspicious immediately
# made `$'…'` suspicious too, because ANSI-C quoting also starts with a `$` - which
# would have re-blocked round-9's 19-nr2 ALLOW. The narrowing removes ANSI-C
# segments before deciding whether anything is unresolved, and it must not reach
# further than that: an escape-bearing `$'…'` that rebuilds the marker still blocks
# through the round-9 decoder. Both sides are pinned here because they are one
# change, and reading only one of them makes the other look like a bug.
#
# ACCEPTED OVER-BLOCK, PINNED AS INTENTIONAL (10-ob rows). The evidence sweep looks
# at the substitution BODY, and a body that names the workflow directory is
# indistinguishable from one that writes there - so three shapes that only READ now
# block:
#     echo "$(cat <wf>/<sid>.state.json)"
#     echo "`cat <wf>/<sid>.state.json`"
#     touch "$(cat <wf>/<sid>.state.json)"
# and so does any dynamically-named write INTO the workflow directory, however
# innocent its intent (10-ob4: `touch <wf>/report-$(date +%s).txt`). The rule is
# "unanalysable + aimed at the workflow directory", and nothing in the command text
# distinguishes a timestamped report from an assembled marker name.
# This is the sanctioned direction for "cannot analyse" (same policy as round-6's
# opaque routes), but it is a real cost, so BOTH SIDES are pinned: the reads that
# must keep working - `SID=$(cat …)`, assign-then-echo, `<(…)`, and plain
# cat/grep/ls of the workflow dir - are asserted immediately below the over-blocks.
# A future narrowing of the over-block is then a deliberate, visible edit to this
# file rather than silent drift, and a future WIDENING trips the ALLOW rows.
#
# ---------------------------------------------------------------------------
# RESIDUAL GAPS - MEASURED, DELIBERATELY NOT ASSERTED
#
# Two shapes still reach APPROVE on the fixed tree and both really do create the
# marker. They are recorded here rather than pinned, because writing `approve` next
# to a live forge would encode the vulnerability as a requirement:
#
#   (i)  cd <wf> && touch "$(printf '%s%s' <sid>.workflow -off)"
#        A quoted substitution whose body contains WHITESPACE and whose word
#        carries no `/`: the target-context classifier's looksLikePath test fails,
#        so the word takes the whitespace-splitting branch and the dynamic-target
#        qualifier is never consulted. The same command without the interior space
#        (10-m1c below) blocks.
#   (ii) touch `printf '%s%s' <wf>/<sid>.workflow -off`
#        An UNQUOTED substitution whose body contains whitespace: the tokenizer
#        splits the word, and no single piece is a protected target on its own. The
#        `$( )` form of the same payload (10-m1a) blocks, and the backtick form
#        after `cd <wf>` (10-m1e) blocks - so this is an asymmetry, not a policy.
#
# Neither is in scope for a test-only change; both belong to bash-target-context.js
# and are reported upstream.
# ---------------------------------------------------------------------------
#
# Table format and placeholders: see ./cases-round6-stdin.sh, ./cases-round9-brace-ansi.sh
# and ./cases-round10-brace-span.sh (@BS@ -> one backslash).

# run_R10_dynamic_target - the measured ALLOW->BLOCK shapes: both assembly styles
# (whole target inside one substitution, and a substituted SUFFIX), absolute and
# `cd <wf>`-relative, argv and redirect position, both protected families.
run_R10_dynamic_target() {
    _run_r10_table "R10" <<'TABLE'
10-m1a whole target assembled in one substitution|block|touch "$(printf '%s%s' @DIR@/@SID@.workflow -off)"
10-m1b substituted suffix completes the marker|block|touch @DIR@/@SID@.workflow$(printf -- -off)
10-m1c relative target assembled after cd into the workflow dir|block|cd @DIR@ && touch "$(printf @SID@.workflow-off)"
10-m1d relative substituted suffix after cd|block|cd @DIR@ && touch @SID@.workflow$(printf -- -off)
10-m1e backtick assembly after cd into the workflow dir|block|cd @DIR@ && touch `printf '%s%s' @SID@.workflow -off`
10-m1f substituted suffix, redirect position|block|echo x > @DIR@/@SID@.workflow$(printf -- -off)
10-m1g whole target assembled, redirect position|block|echo x > "$(printf '%s%s' @DIR@/@SID@.workflow -off)"
10-m1h whole target assembled, tee argument|block|echo x | tee "$(printf '%s%s' @DIR@/@SID@.workflow -off)"
10-m1i variable-spliced suffix|block|S=.workflow-off; touch @DIR@/@SID@$S
10-m1j token family, substituted suffix|block|touch @DIR@/@SID@.off-clearanc$(printf -- e)
TABLE
}

# run_R10_dynamic_target_controls - the everyday dynamic targets. Each is
# unresolved in exactly the same way as a block row above; only the absence of the
# workflow directory separates them, which is the whole content of the qualifier.
run_R10_dynamic_target_controls() {
    _run_r10_table "R10" <<'TABLE'
10-m1nr1 mktemp into a redirect|approve|echo x > "$(mktemp)"
10-m1nr2 assigned mktemp into a redirect|approve|T=$(mktemp); echo x > "$T"
10-m1nr3 bare $LOG redirect|approve|echo x > $LOG
10-m1nr4 quoted $OUT redirect|approve|echo x > "$OUT"
10-m1nr5 $TMPDIR path redirect|approve|echo x > $TMPDIR/out.txt
10-m1nr6 mktemp in argv position|approve|touch "$(mktemp)"
10-m1nr7 timestamped log outside the workflow dir|approve|touch /tmp/log-$(date +%s).txt
TABLE
}

# run_R10_ansi_narrowing - the follow-on narrowing, both sides. 10-m1x1/x2 would
# have become BLOCK when a residual `$` was made suspicious; 10-m1x3/x4 must not be
# relaxed by the narrowing that rescued them.
run_R10_ansi_narrowing() {
    _run_r10_table "R10" <<'TABLE'
10-m1x1 ANSI-C ordinary path, redirect|approve|echo x > $'@DIR@/plain.txt'
10-m1x2 ANSI-C ordinary path, argv|approve|touch $'@DIR@/plain.txt'
10-m1x3 ANSI-C escape rebuilding the marker still blocks, redirect|block|echo x > $'@DIR@/@MK1@@BS@x66'
10-m1x4 ANSI-C escape rebuilding the marker still blocks, argv|block|touch $'@DIR@/@MK1@@BS@x66'
TABLE
}

# run_R10_accepted_overblock - the reads that now fail closed. Pinned as
# INTENTIONAL, not as correct-in-isolation: see the header note.
run_R10_accepted_overblock() {
    _run_r10_table "R10" <<'TABLE'
10-ob1 echo of a substituted read of the workflow dir|block|echo "$(cat @DIR@/@SID@.state.json)"
10-ob2 echo of a backtick read of the workflow dir|block|echo "`cat @DIR@/@SID@.state.json`"
10-ob3 argv-position substituted read of the workflow dir|block|touch "$(cat @DIR@/@SID@.state.json)"
10-ob4 innocent timestamped filename inside the workflow dir|block|touch @DIR@/report-$(date +%s).txt
TABLE
}

# run_R10_overblock_boundary - the reads that MUST keep working. #1709 read
# symmetry is the counterweight the whole guard is balanced against: a hook that
# blocks reading session state breaks the workflow it exists to protect.
run_R10_overblock_boundary() {
    _run_r10_table "R10" <<'TABLE'
10-obnr1 assignment from a substituted read|approve|SID=$(cat @DIR@/x)
10-obnr2 assign then echo the variable|approve|S=$(cat @DIR@/x); echo "$S"
10-obnr3 process substitution read|approve|diff <(cat @DIR@/x) /tmp/y
10-obnr4 plain cat of a workflow-dir file|approve|cat @DIR@/@SID@.state.json
10-obnr5 plain grep of a workflow-dir file|approve|grep foo @DIR@/@SID@.state.json
10-obnr6 plain ls of the workflow dir|approve|ls @DIR@
TABLE
}
