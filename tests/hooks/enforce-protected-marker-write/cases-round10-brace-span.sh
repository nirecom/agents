#!/usr/bin/env bash
# Part of tests/hooks/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-10 HIGH-1: a brace group spanning the path separator (`touch {<wf>/x,<wf>/<mk>}`,
# `<wf>/{./x,<mk>}`, `{<wf>,/tmp}/<mk>`) moves the basename boundary, because bash expands
# braces over the WHOLE word; the fix enumerates candidates of the raw token first. Each
# block row forges clearance (session-markers.js trusts existence). The 10-nr* rows pin
# the over-block boundary (CPR-ORTH); since #2434 every ordinary-name row targets @ODIR@,
# as the strict placement guard blocks every write under @DIR@.
# Placeholders: ./cases-round6-stdin.sh and ./cases-round9-brace-ansi.sh, plus @BS@ -> one
# backslash (for ./cases-round10-ansi-argv.sh; defined here as this part is sourced first).
_r10_expand() {
    local t="${1//@BS@/\\}"
    _r9_expand "$t"
}
_run_r10_table() {
    local section="$1"
    _run_r6_table "$section" < <(printf '%s\n' "$(_r10_expand "$(cat)")")
}

# run_R10_brace_span - the measured ALLOW->BLOCK shapes. Both protected families
# (CPR-ORTH), and every write route the fix touches: argv, redirect, tee, dd of=, mv,
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
10-nr1 comma-less {x} stays literal in argv|approve|touch @ODIR@/@MK@{x}
10-nr2 brace group entirely outside the workflow dir|approve|touch {/tmp/a,/tmp/b}
10-nr3 brace group in one dir, unrelated stems|approve|touch {@ODIR@/a.txt,@ODIR@/b.txt}
10-nr4 ordinary numeric range|approve|touch /tmp/f{1..4}.txt
10-nr5 dir-changing group with an ordinary basename|approve|touch {@ODIR@,/tmp}/plain.txt
10-nr6 comma-less group on an ordinary stem|approve|touch @ODIR@/plain{x}.txt
TABLE
}
