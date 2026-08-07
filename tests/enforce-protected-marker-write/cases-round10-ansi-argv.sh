#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-10 HIGH-2: ANSI-C ESCAPES IN *ARGUMENT* POSITION.
#
# Round-9 taught the decoder `$'…'`, but only the REDIRECT path kept the raw,
# still-quoted spelling of its target. The argv path compared COOKED words only -
# the tokenizer had already stripped the `$'…'` wrapper and, with it, the escape
# sequences the decoder exists to read. So one and the same payload split by
# delivery syntax:
#
#     echo x > $'<wf>/<sid>.workflow-of\x66'    -> BLOCK   (round 9)
#     touch    $'<wf>/<sid>.workflow-of\x66'    -> APPROVE (round 9 hole)
#
# Both commands create the identical file. The fix carries the raw argv spelling
# alongside the cooked one and classifies BOTH.
#
# THE INVARIANT IS PARITY, NOT TWO VERDICTS. These are not two independent rows
# that happen to agree; "the delivery syntax does not change the verdict" is the
# property the fix restores, so it is asserted as ONE comparison per payload
# (_r10_parity below). Two separate rows would still pass if a future change moved
# both verdicts together in the wrong direction, and would not name what broke if
# only one moved.
#
# WHY EACH PAYLOAD IS A FORGE: hooks/lib/session-markers.js authorizes on EXISTENCE
# alone. Every block payload below is the real marker/token basename with one
# character re-spelled as an escape, so bash writes the exact protected name in the
# exact workflow directory. 10-h2g is the separator variant: `\x2f` hides the `/`
# itself, so the raw word carries no visible path separator at all.
#
# ACCEPTED OVER-BLOCK, inherited unchanged from round-9 and re-pinned in argv
# position (CPR-ORTH): `$'…\X66'` uses an uppercase `\X`, which bash does NOT decode,
# so the shell creates `…-of\X66` and no forge occurs - but the shared decoder does
# decode it. That is widening in the DETECTION direction and it stands. Do not
# narrow the decoder to "fix" it.
#
# THE ALLOW ROWS (CPR-ORTH): the raw spelling now reaches the classifier for every
# argument of every write command, so the null cases matter as much as the forges:
#   10-h2nr1  a `$'…'` with no escape sequences at all, argv position (the argv
#             sibling of round-9's redirect-position 19-nr2)
#   10-h2nr2  the same, redirect position - kept so the pair is visibly symmetric
#   10-h2nr3  an escape-bearing `$'…'` outside the workflow dir
#   10-h2nr4  an ordinary quoted path in argv position
#
# Table format and placeholders: see ./cases-round6-stdin.sh, ./cases-round9-brace-ansi.sh
# and ./cases-round10-brace-span.sh (@BS@ -> one backslash).

# _r10_parity <label> <want> <target-spelling>
# Runs the SAME target through argv position (`touch <t>`) and redirect position
# (`echo x > <t>`) and asserts, in one comparison, that the two agree AND that they
# agree on <want>. A parity break and a wrong-verdict break are distinguishable in
# the failure output because both verdicts are printed.
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
    _r10_parity "10-h2nr1 no escape sequences at all" approve "\$'@DIR@/plain.txt'"
    _r10_parity "10-h2nr2 escape-bearing path outside the workflow dir" approve "\$'/tmp/a@BS@x66'"
    _r10_parity "10-h2nr3 ordinary quoted path" approve "\"@DIR@/plain.txt\""
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
10-h2nr5 tee, no escape sequences|approve|echo x | tee $'@DIR@/plain.txt'
10-h2nr6 cp source is not a write target|approve|cp $'/tmp/a@BS@x66' /tmp/b
TABLE
}
