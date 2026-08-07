#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-9 HIGH-2: SPELLINGS THAT *CREATE* THE PROTECTED BASENAME.
#
# The candidate-basename normalizer modelled globs, NTFS streams and Windows
# trailing-dot stripping, but not the two bash constructs that BUILD a name:
#
#     brace expansion  echo x > <wf>/<sid>.workflow-of{f..f}   -> …workflow-off
#                      tee     <wf>/<sid>.workflow-{off,off}   -> …workflow-off
#     ANSI-C quoting   echo x > $'<wf>/<sid>.workflow-of\x66'  -> …workflow-off
#
# The difference from a glob is the whole point and must not be blurred: a glob
# can only ever match a file that ALREADY EXISTS, while these two CREATE the
# exact protected basename — and hooks/lib/session-markers.js authorizes on a
# marker's EXISTENCE alone, so each of the rows below is a one-command forge of
# full session clearance.
#
# The ANSI-C half was worse than a miss. unquoteBashWord() had no `$'…'` mode, so
# `\x66` fell through to the PLAIN-context escape rule (`\` + next char -> next
# char) and the normalizer MANUFACTURED `…workflow-ofx66` — a basename the shell
# never creates — while the shell created `…workflow-off`. A normalizer consumed
# in the DETECTION direction may widen; it may never rewrite.
#
# TWO DIFFERENT REASONS FOR A BLOCK — do not conflate them:
#
#   * CORRECT BLOCKS, nothing here is available to relax (19-a..19-g): each row
#     is a spelling bash expands ONTO the protected basename. Verified by
#     construction: every one is the real marker/token name with its last
#     character (or one interior character) re-spelled.
#   * PRE-EXISTING GLOB VERDICT, not a round-9 row (19-x1/19-x2): `…-of[f]` and
#     `…-of*` were BLOCK before this fix and are asserted here only so the new
#     candidate enumeration cannot silently change them. They are correct: a
#     glob that commits literal characters into the protected suffix can expand
#     onto the real file.
#   * ACCEPTED OVER-BLOCK — deliberately fail closed (19-o1, and the over-cap
#     assertion in the unit probe): `$'…\X66'` uses an UPPERCASE `\X`, which
#     bash does NOT decode (it yields the literal `\X66`), while the shared
#     decoder does. That is widening in the detection direction, so it stands;
#     do not "fix" it by narrowing the decoder. Likewise a brace pattern whose
#     expansion exceeds MAX_CANDIDATE_SPELLINGS answers "hit" rather than
#     finishing, which costs a legitimate `touch f{1..5000}.txt` a block.
#
# THE BOUNDARY IS PINNED BY THE ALLOW ROWS (CPR-ORTH). The normalizer runs on every
# write target in every command, so a widener that widens too far is a different
# and equally real defect:
#   19-nr1  bash fidelity — a single brace element with no comma and no `..` is
#           NOT a brace expansion in bash (`{x}` stays literal), so `<mk>{x}` is
#           NOT the marker and must not be treated as it
#   19-nr2  a `$'…'` with no escape sequences at all
#   19-nr3  an uppercase spelling of an ordinary name
#   19-nr4  a `~/…` form   19-nr5  a backslash-bearing path
#   19-nr6/19-nr7  ordinary brace and ANSI-C writes outside the workflow dir
#
# Table format and placeholders: see ./cases-round6-stdin.sh. This file adds
# three more, because the payloads must SPLIT the protected basename apart:
#   @SID@   -> the sandbox session id
#   @MK1@   -> the marker basename MINUS its last character
#   @TOK1@  -> the token basename MINUS its last character

# _run_r9_table <section>: ./cases-round6-stdin.sh's runner plus the three
# placeholders above. Process substitution (not a pipe) keeps the runner in THIS
# shell, so its PASS/FAIL increments survive.
_r9_expand() {
    local t="$1"
    t="${t//@MK1@/$SID.workflow-of}"
    t="${t//@TOK1@/$SID.off-clearanc}"
    t="${t//@SID@/$SID}"
    _r6_expand "$t"
}
_run_r9_table() {
    local section="$1"
    _run_r6_table "$section" < <(printf '%s\n' "$(_r9_expand "$(cat)")")
}

# run_R9_brace_ansi - the measured ALLOW->BLOCK shapes, both protected families
# (CPR-ORTH) and both construct families.
run_R9_brace_ansi() {
    _run_r9_table "R9" <<'TABLE'
19-a brace range rebuilds marker|block|echo x > @DIR@/@MK1@{f..f}
19-b brace range rebuilds token|block|echo x > @DIR@/@TOK1@{e..e}
19-c brace comma via tee|block|echo x | tee @DIR@/@SID@.workflow-{off,off}
19-d brace comma, whole basename|block|echo x > @DIR@/{@MK@,@MK@}
19-e ANSI-C hex escape tail|block|echo x > $'@DIR@/@MK1@\x66'
19-f ANSI-C octal escape tail|block|echo x > $'@DIR@/@MK1@\146'
19-g ANSI-C hex escape mid-name|block|echo x > $'@DIR@/@SID@.\x77orkflow-off'
19-g2 ANSI-C hex escape, token|block|echo x > $'@DIR@/@TOK1@\x65'
19-g3 brace comma, token via tee|block|echo x | tee @DIR@/@SID@.off-{clearance,clearance}
TABLE
}

# run_R9_brace_ansi_boundary - the verdicts this change must NOT move.
# 19-x1/19-x2 are the pre-existing glob rule; 19-o1 is the named over-block.
run_R9_brace_ansi_boundary() {
    _run_r9_table "R9" <<'TABLE'
19-x1 pre-existing glob class [f]|block|echo x > @DIR@/@MK1@[f]
19-x2 pre-existing glob star|block|echo x > @DIR@/@MK1@*
19-o1 over-block: uppercase \X is not bash|block|echo x > $'@DIR@/@MK1@\X66'
19-nr1 bash fidelity: {x} is literal|approve|echo x > @DIR@/@MK@{x}
19-nr2 ANSI-C with no escapes|approve|echo x > $'@DIR@/plain.txt'
19-nr3 uppercase ordinary name|approve|echo x > @DIR@/PLAIN.TXT
19-nr4 tilde form, ordinary name|approve|echo x > ~/protmark-plain.txt
19-nr5 backslash-bearing path|approve|echo x > /tmp/a\b.txt
19-nr6 ordinary brace outside wf|approve|echo x > /tmp/{a,b}
19-nr7 ordinary ANSI-C outside wf|approve|echo x > $'/tmp/a\x66'
19-nr8 ordinary brace range outside wf|approve|echo x > /tmp/f{1..4}.txt
TABLE
}

# run_R9_brace_ansi_unit - the MECHANISM. The hook rows prove the verdict moved;
# only the unit layer can prove the enumeration is the bash expansion and not
# something merely correlated with it, and only the unit layer can reach the cap
# boundary (a 1025-element brace group is not a hook payload anybody types).
#
# The probe recomputes its expectations independently — the alternative sets for
# `{a,b}`, `{a..b}`, `{a..b..n}`, zero-padded ranges and nesting are built in the
# probe from the range definition, then compared against candidateSpellings().
# Re-asserting the function's own output against itself would pass against any
# implementation, including a broken one.
run_R9_brace_ansi_unit() {
    local probe="$PARTS_DIR/round9-brace-ansi-probe.js"
    if [ ! -f "$probe" ]; then
        fail "R9-U probe missing at $probe - the candidate enumeration is unasserted"
        return
    fi
    local out
    out="$("$RWT" 20 node "$(node_path "$probe")" "$_AGENTS_DIR_NODE" 2>/dev/null)"
    if [ -z "$out" ]; then
        fail "R9-U probe produced no output (brace-ansi-expand.js / protected-basenames.js not loadable)"
        return
    fi
    local _get
    _get() { printf '%s\n' "$out" | while IFS= read -r line; do
        case "$line" in "$1="*) printf '%s' "${line#*=}"; return ;; esac
    done; }

    assert_eq "R9-U brace-ansi-expand module is loadable" "true" "$(_get mod_loaded)"
    assert_eq "R9-U brace expansion matches recomputed sets" "true" "$(_get brace_ok)"
    assert_eq "R9-U brace expansion has no misses" "-" "$(_get brace_bad)"
    assert_eq "R9-U a single element {x} is NOT expanded" "true" "$(_get brace_single_literal)"
    assert_eq "R9-U nested groups expand to the cartesian product" "true" "$(_get brace_nested)"
    assert_eq "R9-U zero-padded ranges keep their width" "true" "$(_get brace_padded)"
    assert_eq "R9-U the raw spelling is never dropped" "true" "$(_get brace_keeps_raw)"

    # The cap is a fail-CLOSED boundary, so both sides of it are asserted: below
    # the cap the enumeration completes and answers honestly (no match), above it
    # the answer is "hit" even though no expansion carries the suffix. The edge
    # row pins WHERE the boundary falls — the raw spelling is itself a candidate,
    # so an N-alternative group costs N+1 and the last group that fits has CAP-1
    # alternatives. An off-by-one here moves a fail-closed boundary in silence.
    assert_eq "R9-U below the cap the enumeration completes" "true" "$(_get cap_below_ok)"
    assert_eq "R9-U at the cap the raw spelling tips it over" "true" "$(_get cap_edge_overcap)"
    assert_eq "R9-U above the cap the enumeration is abandoned" "true" "$(_get cap_above_overcap)"
    assert_eq "R9-U above the cap the answer is HIT (fails closed)" "true" "$(_get cap_above_hit)"
    assert_eq "R9-U below the cap a non-matching pattern is not a hit" "true" "$(_get cap_below_miss)"

    assert_eq "R9-U ANSI-C hex escape decodes to the real character" "true" "$(_get ansi_hex)"
    assert_eq "R9-U unquoteBashWord no longer rewrites \\x66 to x66" "true" "$(_get unquote_fixed)"
    assert_eq "R9-U unquoteBashWord rebuilds the protected basename" "true" "$(_get unquote_marker)"
    assert_eq "R9-U plain-context backslash escape is unchanged" "true" "$(_get unquote_plain)"
}
