#!/usr/bin/env bash
# Part of tests/hooks/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-10 MEDIUM-1: a target assembled by command substitution (`touch "$(printf …)"`)
# used to approve. An unresolved target whose evidence resolves INTO the workflow dir now
# fails closed ("workflow-dynamic"); everyday dynamic targets ($(mktemp), $LOG, $TMPDIR)
# must stay approved. 10-m1x: ANSI-C `$'…'` is not a residual `$`; since #2434 the ordinary
# rows target @ODIR@ (strict placement guard). 10-ob: accepted over-block of reads naming
# the wf dir, with #1709 read symmetry pinned below. Residual gaps (not asserted, reported
# upstream): `cd <wf> && touch "$(printf '%s%s' <sid>.workflow -off)"` and an unquoted
# backtick with whitespace in the body. Placeholders: see ./cases-round10-brace-span.sh.
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
10-m1x1 ANSI-C ordinary path, redirect|approve|echo x > $'@ODIR@/plain.txt'
10-m1x2 ANSI-C ordinary path, argv|approve|touch $'@ODIR@/plain.txt'
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
