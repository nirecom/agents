# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, static-check, table-driven, TL2, scope:common
#
# C1-C5 notation checks plus mode-equivalence and usage errors.

echo ""
echo "=== C1-C5 notation checks ==="

# --- table-driven cases: name | builder | mode | want_exit | want_token ---
while IFS='|' read -r name builder mode want_exit want_token; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; builder="${builder//[[:space:]]/}"
    mode="${mode//[[:space:]]/}"; want_exit="${want_exit//[[:space:]]/}"
    want_token="${want_token//[[:space:]]/}"
    CASE_N=$((CASE_N + 1))
    d="$BASE/c$CASE_N"
    "$builder" "$d"
    got_exit="$(run_checker "$d" "$mode")"
    out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
    if [ "$got_exit" != "$want_exit" ]; then
        fail "$name ($mode): want exit $want_exit, got $got_exit — output: $(echo "$out" | head -3 | tr '\n' ' ')"
    elif [ -n "$want_token" ] && ! printf '%s' "$out" | grep -q "$want_token"; then
        fail "$name ($mode): exit $got_exit correct but token '$want_token' absent — output: $(echo "$out" | head -3 | tr '\n' ' ')"
    else
        pass "$name ($mode)"
    fi
done <<'TABLE'
clean-tree            | fx_base                 | all    | 0 |
clean-tree            | fx_base                 | staged | 0 |
c1-no-frontmatter     | fx_c1_no_frontmatter    | all    | 1 | INVALID_ON_DEMAND_PATHS
c1-token-plus-glob    | fx_c1_token_plus_glob   | all    | 1 | INVALID_ON_DEMAND_PATHS
c1-wrong-single-glob  | fx_c1_wrong_single_glob | all    | 1 | INVALID_ON_DEMAND_PATHS
c1-no-frontmatter     | fx_c1_no_frontmatter    | staged | 1 | INVALID_ON_DEMAND_PATHS
c2-missing-marker     | fx_c2_missing_marker    | all    | 1 | MISSING_ON_DEMAND_MARKER
c2-orphan-marker      | fx_c2_orphan_marker     | all    | 1 | ORPHAN_ON_DEMAND_MARKER
c2-missing-marker     | fx_c2_missing_marker    | staged | 1 | MISSING_ON_DEMAND_MARKER
c3-reserved-worktree  | fx_c3_reserved_path     | all    | 1 | RESERVED_PATH_EXISTS
c3-reserved-staged    | fx_c3_reserved_path     | staged | 1 | RESERVED_PATH_EXISTS
c4-bangbang           | fx_c4_bangbang          | all    | 1 | NONCANONICAL_ON_DEMAND_TOKEN
c4-underscore         | fx_c4_underscore        | all    | 1 | NONCANONICAL_ON_DEMAND_TOKEN
c4-bare               | fx_c4_bare              | all    | 1 | NONCANONICAL_ON_DEMAND_TOKEN
c4-underscore         | fx_c4_underscore        | staged | 1 | NONCANONICAL_ON_DEMAND_TOKEN
c5-unlisted-rule      | fx_c5_unlisted          | all    | 1 | UNLISTED_UNCONDITIONAL_RULE
c5-unlisted-rule      | fx_c5_unlisted          | staged | 1 | UNLISTED_UNCONDITIONAL_RULE
TABLE

# --- E-EQ: --staged and --all agree on identical trees (clean and violating) ---
for pair in "fx_base:0" "fx_c5_unlisted:1" "fx_c2_orphan_marker:1"; do
    b="${pair%%:*}"; expect="${pair##*:}"
    CASE_N=$((CASE_N + 1)); da="$BASE/eqa$CASE_N"
    CASE_N=$((CASE_N + 1)); ds="$BASE/eqs$CASE_N"
    "$b" "$da"; "$b" "$ds"
    ra="$(run_checker "$da" all)"
    rs="$(run_checker "$ds" staged)"
    if [ "$ra" = "$rs" ] && [ "$ra" = "$expect" ]; then
        pass "E-EQ: --all and --staged agree on $b (both exit $ra)"
    else
        fail "E-EQ: --all=$ra --staged=$rs (want both $expect) for $b"
    fi
done

# --- E-USAGE: exit 2 on no args and on an unknown flag ---
CASE_N=$((CASE_N + 1)); du="$BASE/usage$CASE_N"; fx_base "$du"
u_rc=0; ( cd "$du" && bash "$CHECKER" ) >/dev/null 2>&1 || u_rc=$?
[ "$u_rc" = "2" ] && pass "E-USAGE: no arguments exits 2" || fail "E-USAGE: no arguments exits 2 (got $u_rc)"
u_rc=0; ( cd "$du" && bash "$CHECKER" --bogus-flag ) >/dev/null 2>&1 || u_rc=$?
[ "$u_rc" = "2" ] && pass "E-USAGE: unknown flag exits 2" || fail "E-USAGE: unknown flag exits 2 (got $u_rc)"
