#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-10 HIGH-1: A BRACE GROUP THAT SPANS THE PATH SEPARATOR.
#
# Round-9 taught the normalizer that brace expansion CREATES names, but it applied
# the expansion to the BASENAME of the raw token only. That is the wrong unit,
# because bash expands braces over the WHOLE WORD before any path splitting, so a
# group that contains a `/` moves the basename boundary:
#
#     touch {<wf>/x,<wf>/<sid>.workflow-off}     basename of the raw word is
#                                                `<sid>.workflow-off}` - not the
#                                                marker - while bash creates the
#                                                marker itself
#     touch <wf>/{./x,<sid>.workflow-off}        the `./` element makes the raw
#                                                basename disagree again
#     touch {<wf>,/tmp}/<sid>.workflow-off       the group changes the DIRECTORY,
#                                                so containment - not the basename
#                                                - is what the group moves
#
# The fix takes candidate spellings of the RAW token first and derives a basename
# from each candidate (round-9 did it the other way round). Direction discipline is
# unchanged: the normalizer may widen in the DETECTION direction, never rewrite.
#
# WHY EACH ROW IS A FORGE, NOT A STYLE POINT: hooks/lib/session-markers.js
# authorizes on EXISTENCE alone, so any one of the block rows below is a
# single-command grant of full session clearance. Verified by construction - every
# block row's expansion set contains the exact protected basename in the exact
# workflow directory.
#
# THE ALLOW ROWS ARE THE OTHER HALF OF THE FIX (CPR-5). Enumerating candidates from
# the raw word touches every write target in every command, so a widener that
# widens too far is a different and equally real defect:
#   10-nr1  bash fidelity, argv position: `{x}` has no comma and no `..`, so bash
#           leaves it literal and `<mk>{x}` is NOT the marker. This is the argv
#           sibling of round-9's redirect-position 19-nr1 - the fix moved argv
#           handling, so the fidelity control has to move with it.
#   10-nr2  a brace group entirely outside the workflow dir
#   10-nr3  a brace group in the workflow dir with unrelated stems
#   10-nr4  an ordinary numeric range
#   10-nr5  a DIRECTORY-changing group with an ordinary basename - the same shape
#           as the 10-k forge, differing only in the basename, which is exactly
#           what must decide it
#   10-nr6  a comma-less group on an ordinary stem
#
# Table format and placeholders: see ./cases-round6-stdin.sh and
# ./cases-round9-brace-ansi.sh (@DIR@ @MK@ @TOK@ @NL@ @MK1@ @TOK1@ @SID@).

# _r10_expand / _run_r10_table: the round-9 expander (which chains to the round-6
# one) plus @BS@ -> a single backslash. ANSI-C payloads in ./cases-round10-ansi-argv.sh
# must spell escape sequences that survive verbatim into the command text; routing
# the backslash through a placeholder keeps every editor and serializer between the
# table and the hook out of that decision. Defined here because this file is sourced
# before the other round-10 parts.
_r10_expand() {
    local t="${1//@BS@/\\}"
    _r9_expand "$t"
}
_run_r10_table() {
    local section="$1"
    _run_r6_table "$section" < <(printf '%s\n' "$(_r10_expand "$(cat)")")
}

# run_R10_brace_span - the measured ALLOW->BLOCK shapes. Both protected families
# (CPR-5), and every write route the fix touches: argv, redirect, tee, dd of=, mv,
# ln -s.
run_R10_brace_span() {
    _run_r10_table "R10" <<'TABLE'
10-a touch, group spans the slash|block|touch {@DIR@/x,@DIR@/@MK@}
10-b touch, group after the dir slash|block|touch @DIR@/{./x,@MK@}
10-c touch, group opens with the slash|block|touch @DIR@{/x,/@MK@}
10-d token family, group spans the slash|block|touch {@DIR@/x,@DIR@/@TOK@}
10-e tee, group spans the slash|block|echo x | tee {@DIR@/x,@DIR@/@MK@}
10-f dd of=, group spans the slash|block|dd if=/dev/null of={@DIR@/x,@DIR@/@MK@}
10-g mv destination, group spans the slash|block|mv /tmp/x {@DIR@/a,@DIR@/@MK@}
10-h nested groups, inner one holds the marker|block|touch {@DIR@/{x,@MK@},/tmp/y}
10-i range rebuilds the marker in argv position|block|touch @DIR@/@MK1@{f..f}
10-j range nested inside a slash-spanning group|block|touch {@DIR@/@MK1@{f..f},/tmp/y}
10-k group changes the DIRECTORY, marker basename outside it|block|touch {@DIR@,/tmp}/@MK@
10-l ln -s destination, group spans the slash|block|ln -s /tmp/x {@DIR@/a,@DIR@/@MK@}
10-m token range inside a slash-spanning group|block|touch {@DIR@/x,@DIR@/@TOK1@{e..e}}
10-n token, group after the dir slash|block|touch @DIR@/{./x,@TOK@}
10-o .tmp intermediate via a slash-spanning group|block|touch {@DIR@/x,@DIR@/@MK@.tmp}
TABLE
}

# run_R10_brace_span_controls - the over-block boundary. Each row is the nearest
# non-forging neighbour of a block row above, so a future widening cannot pass
# this file without deleting an assertion.
run_R10_brace_span_controls() {
    _run_r10_table "R10" <<'TABLE'
10-nr1 comma-less {x} stays literal in argv|approve|touch @DIR@/@MK@{x}
10-nr2 brace group entirely outside the workflow dir|approve|touch {/tmp/a,/tmp/b}
10-nr3 brace group in the workflow dir, unrelated stems|approve|touch {@DIR@/a.txt,@DIR@/b.txt}
10-nr4 ordinary numeric range|approve|touch /tmp/f{1..4}.txt
10-nr5 dir-changing group with an ordinary basename|approve|touch {@DIR@,/tmp}/plain.txt
10-nr6 comma-less group on an ordinary stem|approve|touch @DIR@/plain{x}.txt
TABLE
}
