#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-6 unit layer: the INTERPRETER-IDENTITY SSOT behind the stdin routing.
#
# The hook-level cases in cases-round6-stdin.sh prove the routes are closed for
# the spellings they name. This file asserts the single function every one of
# those routes consults - interpreterKindOfWord() - directly and exhaustively
# over hooks/block-.../interpreter-scan.js's own name arrays, because it is now
# the single point of failure for the whole class: get it wrong for one spelling
# (`NODE.EXE`, `/usr/bin/node`, `C:\...\python3.exe`) and EVERY route reopens for
# that spelling at once, silently, with no payload test necessarily naming it.
#
# Assertions are on `key=value` lines emitted by ./round6-identity-probe.js (a
# FILE, never `node -e`: the modules under test live under a directory whose own
# name is a protected string). Route shapes are asserted as PREDICATES
# (0 / exactly 1 / at least 1) rather than exact triples: which bucket a delivery
# syntax lands in is the contract, while the exact number of fail-closed opaque
# texts is an implementation detail that may legitimately shrink.

# _r6_probe_get <key> -> value ("" when the key is absent)
_r6_probe_get() {
    printf '%s\n' "$_R6_PROBE_OUT" | while IFS= read -r line; do
        case "$line" in "$1="*) printf '%s' "${line#*=}"; return ;; esac
    done
}
_r6_assert_true() { assert_eq "R6-ID $1" "true" "$(_r6_probe_get "$2")"; }

# _r6_assert_route <label> <key> <bodies> <files> <opaque>
# Each expectation is "0" (must be empty), "1" (exactly one), "+" (>= 1) or
# "*" (don't care - a bucket whose exact population is not part of the contract).
_r6_assert_route() {
    local label="$1" val i want got ok=yes
    val="$(_r6_probe_get "$2")"; shift 2
    local -a fields; IFS='/' read -r -a fields <<< "$val"
    if [ "${#fields[@]}" -ne 3 ]; then
        fail "R6-ID $label - unparseable route shape [$val]"; return
    fi
    for i in 0 1 2; do
        want="$1"; shift; got="${fields[$i]}"
        case "$want" in
            0) [ "$got" = "0" ] || ok=no ;;
            1) [ "$got" = "1" ] || ok=no ;;
            +) [ "${got:-0}" -ge 1 ] 2>/dev/null || ok=no ;;
            *) : ;;
        esac
    done
    if [ "$ok" = "yes" ]; then pass "R6-ID $label -> $val"
    else fail "R6-ID $label got=$val (bodies/files/opaque)"; fi
}

run_R6_identity() {
    local probe="$PARTS_DIR/round6-identity-probe.js"
    if [ ! -f "$probe" ]; then
        fail "R6-ID probe missing at $probe - the identity SSOT is unasserted"
        return
    fi
    _R6_PROBE_OUT="$("$RWT" 20 node "$(node_path "$probe")" "$_AGENTS_DIR_NODE" 2>/dev/null)"
    if [ -z "$_R6_PROBE_OUT" ]; then
        fail "R6-ID probe produced no output (interpreter-scan.js / nested-bodies.js not loadable)"
        return
    fi

    # --- interpreterKindOfWord: case, directory prefix and .exe tolerance ---
    _r6_assert_true "kind mapping over every listed spelling" kind_ok
    assert_eq "R6-ID kind mapping has no misses" "-" "$(_r6_probe_get kind_bad)"
    _r6_assert_true "non-string words are null (no throw)" kind_nonstring
    # Exhaustive over the SSOT arrays: a name added to the array but not to the
    # Set behind interpreterKindOfWord would be unrouted on every route at once.
    _r6_assert_true "every LANGUAGE name maps (raw/UPPER/path/.exe)" ssot_language
    _r6_assert_true "every SHELL name maps (raw/UPPER/path/.exe)" ssot_shell
    _r6_assert_true "language and shell sets are disjoint" ssot_disjoint
    _r6_assert_true "language set still contains node" ssot_lang_has_node
    _r6_assert_true "shell set still contains bash" ssot_shell_has_bash

    # --- INLINE_PROGRAM_FLAG_RE: the only accepted proof (round 7) ----------
    # Asserted in BOTH directions. The negative direction is the load-bearing
    # one: `-E` / `-p` / `-P` / `--print` each run inline code in ONE language
    # and mean something ordinary in another, so admitting any of them makes
    # `python3 -E - <<< '<program>'` clear itself - the exact bypass round 7
    # closed. A future edit that "helpfully" widens the family goes red here.
    _r6_assert_true "INLINE_PROGRAM_FLAG_RE is exported" ipf_exported
    _r6_assert_true "proof family accepts -c/-e/--eval=/-Command only" ipf_ok
    assert_eq "R6-ID proof family has no misses" "-" "$(_r6_probe_get ipf_bad)"

    # --- stdinProgramInterpreterKind: null EXACTLY when argv PROVES ---------
    # Round 7 replaced the argv-SHAPE walk (fail-open: a flag's own value read
    # as the program operand) with positive proof. What keeps
    # `cat <marker> | python3 -c 'print(1)'` (stdin = DATA, hook case 12-nr1)
    # out of the fail-closed opaque path is now the body-carrying `-c` FLAG -
    # not the operand shape, which is why `node --title x` and `node script.js`
    # report a kind while `node -e 'x'` and `node --eval=code` do not.
    _r6_assert_true "kind is null exactly when a flag PROVES the program" stdin_kind_ok
    assert_eq "R6-ID stdin-kind has no misses" "-" "$(_r6_probe_get stdin_kind_bad)"
    _r6_assert_true "a null segment yields null (no throw)" stdin_kind_null_seg

    # --- stdinProgramRoutes: delivery syntax -> bucket ----------------------
    _r6_assert_route "here-string to language -> body"      route_herestring_lang       + 0 '*'
    _r6_assert_route "here-string to shell -> no lang body" route_herestring_shell      0 0 '*'
    _r6_assert_route "heredoc to language -> body"          route_heredoc               + 0 ""
    _r6_assert_route "heredoc to non-interpreter -> none"   route_heredoc_shell         0 0 0
    _r6_assert_route "unterminated heredoc -> fail closed"  route_heredoc_unterminated  0 0 +
    _r6_assert_route "< FILE -> path, not body"             route_stdin_file            0 1 0
    _r6_assert_route "pipe -> opaque"                       route_pipe                  0 0 +
    _r6_assert_route "whole pipeline is opaque"             route_pipe_chain            0 0 +
    _r6_assert_route "argv-supplied program -> no route"    route_plain                 0 0 0
    _r6_assert_route "non-interpreter < FILE -> no route"   route_cat_file              0 0 0

    # The body must arrive quote-stripped and verbatim, or every anchored
    # read-only shape in interpreter-scan.js misses and #1709 read symmetry
    # (hook cases 8-nr4 / 9-nr1) fails closed.
    assert_eq "R6-ID heredoc body is verbatim"    "console.log(1)" "$(_r6_probe_get heredoc_body)"
    assert_eq "R6-ID here-string body is unquoted" "console.log(1)" "$(_r6_probe_get herestring_body)"
}
