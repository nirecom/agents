#!/bin/bash
# tests/fix-1899-origin-repo-resolver/mutation-probe.sh
# Tests: bin/github-issues/lib/origin-repo.sh
# Tags: origin-resolution, github-issues, mutation-probe, table-driven, parser, regex, security, path-traversal, TL2, scope:issue-specific
#
# Group M of the fix-1899-origin-repo-resolver split suite — the mutation probe,
# and the CPR-ORTH mirror of tests/fix-1899-parse-remote-url/mutation-probe.sh.
#
# Why the bash half needs its own probe: origin-repo.sh does NOT share a regex
# with the JS module — the contract is mirrored by hand in four separate `[[ ]]`
# tests (owner charset, "."/".." guard, repo charset, length arithmetic). Killing
# the JS constants says nothing about these. Worse, a bash case can go green for
# the wrong reason: the resolver returns rc 2 as soon as
# bin/is-github-dotcom-remote declines the host, and rc 2 never reaches the
# charset gate at all — so a widened bash regex would still show "rc != 0".
# This group proves those four decisions are LOAD-BEARING: each mutation rewrites
# exactly one of them in a temporary copy of the library and asserts that at
# least one case which passes against the real library now FAILS against the copy.
#
# The copy is placed inside a reconstructed bin/github-issues/lib/ tree with
# bin/is-github-dotcom-remote alongside it, because the library resolves that
# helper through "${BASH_SOURCE[0]}/../../". A bare copy in a flat temp dir would
# fail the helper lookup, return rc 2 everywhere, and make every mutant look
# "killed" for a reason that has nothing to do with the regex.
#
# The control mutant closes the other half: an inert comment edit must kill
# NOTHING, so a kill can only come from the charset change.
#
# Cases are reused verbatim from owner-repo-charset.sh (groups F and G).
#
# TL2 (real git fixtures, real bash). TL3 gap: none specific to this group — it
# asserts a property of the TEST SUITE, not of a live environment.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

MUT_ROOT="$TMP/mutants"
mkdir -p "$MUT_ROOT"

# Pristine library text, read ONCE — every mutant derives from this, never from
# another mutant, so mutations cannot compound.
ORIGIN_SRC="$(cat "$ORIGIN_LIB")"

# ---------------------------------------------------------------------------
# Case list — reused verbatim from owner-repo-charset.sh. Each fixture repo is
# created ONCE here and reused across the baseline and every mutant.
# Want format is call_resolver's "<rc>|<stdout>".
# ---------------------------------------------------------------------------
CASE_NAMES=(); CASE_DIRS=(); CASE_WANTS=()
add_case() {
    CASE_NAMES+=("$1")
    CASE_DIRS+=("$(mk_repo "mut-$1" "$2")")
    CASE_WANTS+=("$3")
}

while IFS='|' read -r c_name c_url c_want; do
    [ -z "${c_name// /}" ] && continue
    case "$c_name" in \#*) continue ;; esac
    c_want="$(echo "$c_want" | xargs)"
    # `read` drops ONE trailing IFS delimiter, so a want of "3|" (rc 3, empty
    # stdout) arrives as "3". Restore the separator rather than relying on a
    # trailing space in the table, which any whitespace-trimming edit would eat.
    case "$c_want" in *'|'*) ;; *) c_want="$c_want|" ;; esac
    add_case "$(echo "$c_name" | xargs)" "$(echo "$c_url" | xargs)" "$c_want"
done <<'TABLE'
owner-dotdot        | https://github.com/../x.git             | 3|
owner-dot           | https://github.com/./x                  | 3|
repo-dot            | https://github.com/a/.                  | 3|
repo-dotdot         | https://github.com/a/..                 | 3|
owner-underscore    | https://github.com/a_b/x                | 3|
owner-dot-inner     | https://github.com/a.b/x                | 3|
owner-leading-dash  | https://github.com/-abc/x               | 3|
real-https-dotgit   | https://github.com/nirecom/agents.git   | 0|nirecom/agents
repo-leading-dot    | https://github.com/nirecom/.config      | 0|nirecom/.config
owner-inner-dash    | https://github.com/my-org-x/repo        | 0|my-org-x/repo
TABLE

# Length boundaries, built programmatically (a miscounted literal must not be
# able to invert the assertion).
OWNER40="$(printf 'a%.0s' $(seq 1 40))"
REPO101="$(printf 'b%.0s' $(seq 1 101))"
add_case "owner-len-40" "https://github.com/$OWNER40/x" "3|"
add_case "repo-len-101" "https://github.com/a/$REPO101" "3|"

# ---------------------------------------------------------------------------
# mk_mutant <name> <literal-search> <literal-replace>
#   Builds MUT_ROOT/<name>/bin/github-issues/lib/origin-repo.sh (with the
#   is-github-dotcom-remote helper in its expected relative place) and echoes the
#   mutated library path.
#   Echoes ERR:no-match / ERR:multi-match when the search text is not a unique
#   substring of the pristine source — a mutation that silently stopped applying
#   (library reworded) is a FAIL, never a vacuous pass.
#   Pure bash substitution: no sed/regex escaping of the pattern text involved.
# ---------------------------------------------------------------------------
mk_mutant() {
    local name="$1" search="$2" replace="$3" stripped count base out
    stripped="${ORIGIN_SRC//"$search"/}"
    count=$(( (${#ORIGIN_SRC} - ${#stripped}) / ${#search} ))
    if [ "$count" -eq 0 ]; then printf 'ERR:no-match'; return 0; fi
    if [ "$count" -gt 1 ]; then printf 'ERR:multi-match'; return 0; fi
    base="$MUT_ROOT/$name"
    rm -rf "$base"
    mkdir -p "$base/bin/github-issues/lib"
    cp "$AGENTS_DIR/bin/is-github-dotcom-remote" "$base/bin/is-github-dotcom-remote"
    chmod +x "$base/bin/is-github-dotcom-remote" 2>/dev/null || true
    out="$base/bin/github-issues/lib/origin-repo.sh"
    printf '%s\n' "${ORIGIN_SRC/"$search"/"$replace"}" > "$out"
    printf '%s' "$out"
}

# call_resolver_at <lib-path> <repo-dir> -> "<rc>|<stdout>"
#   Same harness as _lib.sh's call_resolver, with the library path parameterized
#   so a mutant copy can be exercised.
call_resolver_at() {
    local out rc
    out=$(run_with_timeout 20 bash -c '
        set -u
        [ -f "$1" ] || { printf "ERR:lib-missing"; exit 90; }
        # shellcheck disable=SC1090
        . "$1"
        command -v resolve_origin_owner_repo >/dev/null 2>&1 || { printf "ERR:fn-missing"; exit 91; }
        resolve_origin_owner_repo "$2"
    ' _ "$1" "$2" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

# count_divergences <lib-path> -> "<killed>|<names...>"
count_divergences() {
    local lib="$1" i killed=0 names="" got
    for i in "${!CASE_NAMES[@]}"; do
        got="$(call_resolver_at "$lib" "${CASE_DIRS[$i]}")"
        if [ "$got" != "${CASE_WANTS[$i]}" ]; then
            killed=$((killed + 1))
            names="$names ${CASE_NAMES[$i]}"
        fi
    done
    printf '%s|%s' "$killed" "${names# }"
}

# probe <mutant-name> <search> <replace> <want-kills: yes|no>
probe() {
    local name="$1" search="$2" replace="$3" want="$4" lib res killed
    lib="$(mk_mutant "$name" "$search" "$replace")"
    case "$lib" in
        ERR:*) fail "mutant/$name/build — $lib"; return 0 ;;
    esac
    pass "mutant/$name/build"
    res="$(count_divergences "$lib")"
    killed="${res%%|*}"
    if [ "$want" = "yes" ]; then
        if [ "$killed" -ge 1 ]; then
            pass "mutant/$name/killed-by (${res#*|})"
        else
            fail "mutant/$name/killed-by — mutation survived: no existing case detects it (charset gate not load-bearing)"
        fi
    else
        assert_eq "control/$name/kills-nothing" "0|" "$res"
    fi
}

# ===========================================================================
# Group M1 — baseline: every case must hold against the PRISTINE library, and an
#   rc-3 expectation must really be rc 3 (not rc 2 from the host classifier),
#   otherwise a mutant "kill" would prove nothing about the charset gate.
# ===========================================================================
group_baseline() {
    local i got
    for i in "${!CASE_NAMES[@]}"; do
        got="$(call_resolver_at "$ORIGIN_LIB" "${CASE_DIRS[$i]}")"
        assert_eq "baseline/${CASE_NAMES[$i]}" "${CASE_WANTS[$i]}" "$got"
    done
}

# ===========================================================================
# Group M2 — mutants. Each rewrites exactly one of the four hand-mirrored
#   charset decisions and must be killed by at least one existing case.
# ===========================================================================
group_mutants() {
    # Owner charset widened to the repo charset — the pre-#1899 shape that
    # admitted "." / ".." / "a_b" as a whole owner segment (F1 [HIGH]).
    probe "owner-charset-widened" \
        '[[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 3' \
        '[[ "$owner" =~ ^[A-Za-z0-9._-][A-Za-z0-9._-]{0,38}$ ]] || return 3' \
        yes

    # Owner end anchor dropped — the 39-char login cap becomes a prefix match, so
    # an over-long or out-of-charset owner passes on its leading run.
    probe "owner-anchor-dropped" \
        '[[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 3' \
        '[[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38} ]] || return 3' \
        yes

    # The dot-segment guard the repo charset alone cannot express (a repo may
    # legitimately begin with a dot, so "." / ".." are excluded separately).
    probe "repo-dot-guard-removed" \
        '[[ "$repo" != "." && "$repo" != ".." ]] || return 3' \
        'true || return 3' \
        yes

    # Repo length cap widened past the 100-char contract maximum.
    probe "repo-length-widened" \
        '(( ${#repo} >= 1 && ${#repo} <= 100 )) || return 3' \
        '(( ${#repo} >= 1 && ${#repo} <= 200 )) || return 3' \
        yes

    # Control: an inert comment edit. A kill here would mean the harness reports
    # divergence for reasons unrelated to the charset gate (helper lookup, temp
    # tree layout), making every kill above meaningless.
    probe "control-comment-only" \
        '# origin-repo.sh — resolve repository identity from the ORIGIN remote only.' \
        '# origin-repo.sh — resolve repository identity (mutation-probe control edit).' \
        no
}

group_baseline
group_mutants

finish
