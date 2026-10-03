#!/usr/bin/env bash
# Part of tests/hooks/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-10 HIGH-2: ANSI-C escapes in ARGUMENT position. `echo x > $'<wf>/<mk-1>\x66'`
# blocked while `touch $'<wf>/<mk-1>\x66'` approved — the argv path compared cooked words
# only. The invariant is PARITY, asserted as ONE comparison per payload (_r10_parity), so a
# change moving both verdicts the wrong way still fails. 10-h2g hides the `/` via `\x2f`;
# 10-h2f (uppercase `\X`) is the accepted fail-closed over-block inherited from round 9.
# 10-h2nr* allow rows pin the boundary (CPR-ORTH); since #2434 their ordinary names target
# @ODIR@, as the strict placement guard blocks every write under @DIR@. Placeholders: see
# ./cases-round6-stdin.sh, ./cases-round9-brace-ansi.sh, ./cases-round10-brace-span.sh.
_r10_parity() {
    local label="$1" want="$2" tgt argv_v redir_v
    tgt="$(_r10_expand "$3")"
    argv_v="$(classify "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r6_mk_input "touch $tgt" "$LINKED_WT")")")"
    redir_v="$(classify "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r6_mk_input "echo x > $tgt" "$LINKED_WT")")")"
    assert_eq "R10 $label - argv form and > redirect form reach the same verdict ($want)" \
        "argv=$want redirect=$want" "argv=$argv_v redirect=$redir_v"
}

# run_R10_ansi_argv_parity - the invariant, across every escape family bash decodes
# (hex, octal, unicode), both protected families, and the separator-hiding variant.
run_R10_ansi_argv_parity() {
    _r10_parity "10-h2a hex escape rebuilds the marker" block "\$'@DIR@/@MK1@@BS@x66'"
    _r10_parity "10-h2b octal escape rebuilds the marker" block "\$'@DIR@/@MK1@@BS@146'"
    _r10_parity "10-h2c unicode escape rebuilds the marker" block "\$'@DIR@/@MK1@@BS@u0066'"
    _r10_parity "10-h2d hex escape mid-name" block "\$'@DIR@/@SID@.@BS@x77orkflow-off'"
    _r10_parity "10-h2e hex escape rebuilds the token" block "\$'@DIR@/@TOK1@@BS@x65'"
    _r10_parity "10-h2f uppercase @BS@X is not decoded by bash (accepted over-block)" block "\$'@DIR@/@MK1@@BS@X66'"
    _r10_parity "10-h2g @BS@x2f hides the path separator itself" block "\$'@DIR@@BS@x2f@MK@'"
    _r10_parity "10-h2nr1 no escape sequences at all" approve "\$'@ODIR@/plain.txt'"
    _r10_parity "10-h2nr2 escape-bearing path outside the workflow dir" approve "\$'/tmp/a@BS@x66'"
    _r10_parity "10-h2nr3 ordinary quoted path" approve "\"@ODIR@/plain.txt\""
}

# run_R10_ansi_argv_commands - the same escape in the argument of write commands
# that have no redirect sibling at all. Parity cannot speak for these, so each is a
# plain verdict row; together with the parity block above they cover the write
# routes the fix touches (CPR-ORTH).
run_R10_ansi_argv_commands() {
    _run_r10_table "R10" <<'TABLE'
10-h2i tee argument|block|echo x | tee $'@DIR@/@MK1@@BS@x66'
10-h2j ln -s destination|block|ln -s /tmp/x $'@DIR@/@MK1@@BS@x66'
10-h2k dd of= argument|block|dd if=/dev/null of=$'@DIR@/@MK1@@BS@x66'
10-h2l install destination|block|install /tmp/x $'@DIR@/@MK1@@BS@x66'
10-h2m mv destination|block|mv /tmp/x $'@DIR@/@MK1@@BS@x66'
10-h2n token via tee|block|echo x | tee $'@DIR@/@TOK1@@BS@x65'
10-h2nr4 tee, ordinary escape-bearing path outside wf|approve|echo x | tee $'/tmp/a@BS@x66'
10-h2nr5 tee, no escape sequences|approve|echo x | tee $'@ODIR@/plain.txt'
10-h2nr6 cp source is not a write target|approve|cp $'/tmp/a@BS@x66' /tmp/b
TABLE
}
