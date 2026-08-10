#!/bin/bash
# tests/fix-1899-parse-remote-url/mutation-probe.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, mutation-probe, table-driven, parser, regex, security, path-traversal, TL1, scope:issue-specific
#
# Group M of the fix-1899-parse-remote-url split suite — the mutation probe.
#
# Why: the charset cases in owner-repo-charset.sh all go through
# parseOriginOwnerRepo, and a case can go green for the wrong reason — the URL
# could be rejected earlier (host classification, path splitting) and never reach
# OWNER_RE / REPO_RE at all. Those tests would then pass against a regex that has
# been silently widened back to the pre-#1899 form. This group proves the charset
# constants are LOAD-BEARING: each mutation below rewrites exactly one regex (or
# the dot-segment guard) in a temporary copy of the module and asserts that at
# least one case which passes against the real module now FAILS against the copy.
#
# Mutations are semantic (widen / drop an anchor), not the never-match /(?!)/ of
# bin/mutation-probe.sh — a never-match mutant is killed by any positive case and
# so cannot tell "the regex is exercised" from "the regex rejects everything".
#
# The control mutant closes the other half: an inert edit (a comment) must kill
# NOTHING, so a kill can only come from the regex change and never from harness
# noise (temp-file path, require cache, node startup).
#
# Cases are reused verbatim from owner-repo-charset.sh (groups F and G) — this
# group invents no new expectations; it re-runs existing ones against mutants.
#
# TL1 (pure module, no git, no network). TL3 gap: none specific to this group —
# it asserts a property of the TEST SUITE, not of a live environment.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

MUT_DIR="$(mktemp -d)"
_fix1899_pru_mut_cleanup() { rm -rf "$MUT_DIR"; }
trap _fix1899_pru_mut_cleanup EXIT

# Pristine module text, read ONCE — every mutant is derived from this, never from
# another mutant, so the mutations cannot compound.
PRU_SRC="$(cat "$AGENTS_DIR/hooks/lib/parse-remote-url.js")"

# ---------------------------------------------------------------------------
# Case list — reused verbatim from owner-repo-charset.sh (F rejects, G accepts).
# ---------------------------------------------------------------------------
CASE_NAMES=(); CASE_INPUTS=(); CASE_WANTS=()
add_case() { CASE_NAMES+=("$1"); CASE_INPUTS+=("$2"); CASE_WANTS+=("$3"); }

while IFS='|' read -r c_name c_input c_want; do
    [ -z "${c_name// /}" ] && continue
    case "$c_name" in \#*) continue ;; esac
    add_case "$(echo "$c_name" | xargs)" "$(echo "$c_input" | xargs)" "$(echo "$c_want" | xargs)"
done <<'TABLE'
owner-dotdot        | https://github.com/../x.git            | fail:unparsable-owner-repo
owner-dot           | https://github.com/./x                 | fail:unparsable-owner-repo
repo-dot            | https://github.com/a/.                 | fail:unparsable-owner-repo
repo-dotdot         | https://github.com/a/..                | fail:unparsable-owner-repo
owner-underscore    | https://github.com/a_b/x               | fail:unparsable-owner-repo
owner-dot-inner     | https://github.com/a.b/x               | fail:unparsable-owner-repo
owner-leading-dash  | https://github.com/-abc/x              | fail:unparsable-owner-repo
real-https-dotgit   | https://github.com/nirecom/agents.git  | ok:nirecom/agents:nirecom:agents:github.com
repo-leading-dot    | https://github.com/nirecom/.config     | ok:nirecom/.config:nirecom:.config:github.com
owner-inner-dash    | https://github.com/my-org-x/repo       | ok:my-org-x/repo:my-org-x:repo:github.com
TABLE

# Length boundaries, built programmatically (same reason as owner-repo-charset.sh:
# a miscounted literal must not be able to invert the assertion).
OWNER40="$(printf 'a%.0s' $(seq 1 40))"
REPO101="$(printf 'b%.0s' $(seq 1 101))"
add_case "owner-len-40" "https://github.com/$OWNER40/x" "fail:unparsable-owner-repo"
add_case "repo-len-101" "https://github.com/a/$REPO101" "fail:unparsable-owner-repo"

# ---------------------------------------------------------------------------
# mk_mutant <name> <literal-search> <literal-replace>
#   Writes MUT_DIR/<name>.js and echoes its node-usable path.
#   Echoes ERR:no-match / ERR:multi-match instead when the search text is not a
#   unique substring of the pristine source — so a mutation that silently stopped
#   applying (source reworded) is a FAIL, never a vacuous pass.
#   Pure bash substitution: no sed/regex escaping of the pattern text involved.
# ---------------------------------------------------------------------------
mk_mutant() {
    local name="$1" search="$2" replace="$3" stripped count out
    stripped="${PRU_SRC//"$search"/}"
    count=$(( (${#PRU_SRC} - ${#stripped}) / ${#search} ))
    if [ "$count" -eq 0 ]; then printf 'ERR:no-match'; return 0; fi
    if [ "$count" -gt 1 ]; then printf 'ERR:multi-match'; return 0; fi
    out="$MUT_DIR/$name.js"
    printf '%s\n' "${PRU_SRC/"$search"/"$replace"}" > "$out"
    printf '%s' "$(nodepath "$out")"
}

# count_divergences <module-path> -> "<killed>|<names...>"
#   Runs every case against <module-path> and reports the cases whose result
#   differs from the pristine expectation.
count_divergences() {
    local mod="$1" i killed=0 names="" got
    for i in "${!CASE_NAMES[@]}"; do
        got="$(call_fn "$mod" parseOriginOwnerRepo "${CASE_INPUTS[$i]}")"
        if [ "$got" != "${CASE_WANTS[$i]}" ]; then
            killed=$((killed + 1))
            names="$names ${CASE_NAMES[$i]}"
        fi
    done
    printf '%s|%s' "$killed" "${names# }"
}

# probe <mutant-name> <search> <replace> <want-kills: yes|no>
probe() {
    local name="$1" search="$2" replace="$3" want="$4" mod res killed
    mod="$(mk_mutant "$name" "$search" "$replace")"
    case "$mod" in
        ERR:*) fail "mutant/$name/build — $mod"; return 0 ;;
    esac
    pass "mutant/$name/build"
    res="$(count_divergences "$mod")"
    killed="${res%%|*}"
    if [ "$want" = "yes" ]; then
        if [ "$killed" -ge 1 ]; then
            pass "mutant/$name/killed-by (${res#*|})"
        else
            fail "mutant/$name/killed-by — mutation survived: no existing case detects it (regex not load-bearing)"
        fi
    else
        assert_eq "control/$name/kills-nothing" "0|" "$res"
    fi
}

# ===========================================================================
# Group M1 — baseline: every case must hold against the PRISTINE module.
#   Without this, a mutant "kill" could just be a broken expectation.
# ===========================================================================
group_baseline() {
    local i got
    for i in "${!CASE_NAMES[@]}"; do
        got="$(call_fn "$PRU_JS" parseOriginOwnerRepo "${CASE_INPUTS[$i]}")"
        assert_eq "baseline/${CASE_NAMES[$i]}" "${CASE_WANTS[$i]}" "$got"
    done
}

# ===========================================================================
# Group M2 — mutants. Each rewrites exactly one charset decision and must be
#   killed by at least one of the existing cases above.
# ===========================================================================
group_mutants() {
    # OWNER_RE widened to the repo charset — the pre-#1899 shape that admitted
    # "." / ".." / "a_b" as a whole owner segment (F1 [HIGH]).
    probe "owner-charset-widened" \
        'const OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/;' \
        'const OWNER_RE = /^[A-Za-z0-9._-][A-Za-z0-9._-]{0,38}$/;' \
        yes

    # OWNER_RE end anchor dropped — the 39-char login cap becomes a prefix match,
    # so an over-long or out-of-charset owner passes on its leading run.
    probe "owner-anchor-dropped" \
        'const OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/;' \
        'const OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}/;' \
        yes

    # REPO_RE length cap widened past the 100-char contract maximum.
    probe "repo-length-widened" \
        'const REPO_RE = /^[A-Za-z0-9._-]{1,100}$/;' \
        'const REPO_RE = /^[A-Za-z0-9._-]{1,200}$/;' \
        yes

    # The dot-segment guard that REPO_RE alone cannot express (a repo may begin
    # with a dot, so "." / ".." are excluded outside the charset).
    probe "repo-dot-guard-removed" \
        'if (repo === "." || repo === "..") return false;' \
        'if (false) return false;' \
        yes

    # Control: an inert comment edit. A kill here would mean the harness reports
    # divergence for reasons unrelated to the regexes, making every kill above
    # meaningless.
    probe "control-comment-only" \
        '// Pure git-remote-URL parsing.' \
        '// Pure git-remote-URL parsing (mutation-probe control edit).' \
        no
}

group_baseline
group_mutants

finish
