# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, static-check, staged, TL2, scope:common
#
# --staged partial-staging coverage. The C1-C5 table always stages a whole fresh
# fixture, so it cannot distinguish an implementation that validates ONLY the supplied
# paths from one that also re-checks the policy-wide invariants. Each case here commits
# a baseline first and then hands the checker a DELIBERATELY NARROW file list.

echo ""
echo "=== --staged partial staging (policy-wide invariants) ==="

# --- S-NEG (negative control): an unrelated, valid single-file edit on a clean
# baseline must exit 0. Without this, S-POLICY / S-COMMITTED below would also pass
# against a checker that unconditionally fails. ---
CASE_N=$((CASE_N + 1)); d="$BASE/stg-neg$CASE_N"
fx_base "$d"; git_commit_all "$d"
printf '\n<!-- unrelated edit -->\n' >> "$d/rules/cond.md"
git -C "$d" add rules/cond.md >/dev/null 2>&1
neg_rc="$(run_checker_files "$d" "rules/cond.md")"
if [ "$neg_rc" = "0" ]; then
    pass "S-NEG: an unrelated single-file edit on a clean baseline exits 0"
else
    fail "S-NEG: want exit 0, got $neg_rc — output: $(head -3 "$(outfile_for "$d")" 2>/dev/null | tr '\n' ' ')"
fi

# --- S-POLICY: only the POLICY file is staged. It newly registers rules/od2.md as
# on-demand, but that file (already committed) carries no reserved-token frontmatter.
# A checker that validates only the supplied paths sees a syntactically fine policy
# and passes. ---
CASE_N=$((CASE_N + 1)); d="$BASE/stg-pol$CASE_N"
fx_base "$d"
wr "$d/rules/od2.md" <<'EOF'
---
paths:
  - "docs/**"
---

# Registered on-demand later, but never annotated
EOF
write_policy "$d" '["rules/od.md"]' '["rules/plain.md"]'
git_commit_all "$d"
write_policy "$d" '["rules/od.md","rules/od2.md"]' '["rules/plain.md"]'
git -C "$d" add hooks/lib/rules-injection-policy.js >/dev/null 2>&1
pol_rc="$(run_checker_files "$d" "hooks/lib/rules-injection-policy.js")"
pol_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$pol_rc" != "1" ]; then
    fail "S-POLICY: staging only the policy that registers an un-annotated rule must exit 1, got $pol_rc"
elif ! printf '%s' "$pol_out" | grep -q 'rules/od2.md'; then
    fail "S-POLICY: exit 1 but the diagnostic never names rules/od2.md — output: $(printf '%s' "$pol_out" | head -3 | tr '\n' ' ')"
else
    pass "S-POLICY: a policy-only stage still validates the newly registered rule"
fi

# --- S-COMMITTED: the violation lives in an ALREADY COMMITTED file (orphan marker)
# and is not in the staged set at all; the stage carries one unrelated rule. C2 is a
# tree-wide invariant, so the checker must still report it. ---
CASE_N=$((CASE_N + 1)); d="$BASE/stg-cmt$CASE_N"
fx_base "$d"
wr "$d/rules/orphan.md" <<EOF
---
paths:
  - "tests/**"
---
$MARKER

# Marker without the token — committed, never staged again
EOF
git_commit_all "$d"
printf '\n<!-- unrelated edit -->\n' >> "$d/rules/cond.md"
git -C "$d" add rules/cond.md >/dev/null 2>&1
cmt_rc="$(run_checker_files "$d" "rules/cond.md")"
cmt_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$cmt_rc" != "1" ]; then
    fail "S-COMMITTED: an orphan marker outside the staged set must still exit 1, got $cmt_rc"
elif ! printf '%s' "$cmt_out" | grep -q 'ORPHAN_ON_DEMAND_MARKER'; then
    fail "S-COMMITTED: exit 1 but ORPHAN_ON_DEMAND_MARKER absent — output: $(printf '%s' "$cmt_out" | head -3 | tr '\n' ' ')"
else
    pass "S-COMMITTED: a tree-wide violation outside the staged set is still detected"
fi

# --- S-ONE-RULE: exactly one rule file is staged and that file is the violating one.
# This is the case an "only supplied files" implementation does handle, so it pins the
# behaviour from the other side. ---
CASE_N=$((CASE_N + 1)); d="$BASE/stg-one$CASE_N"
fx_base "$d"; git_commit_all "$d"
wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---

# Marker removed in this single-file change
EOF
git -C "$d" add rules/od.md >/dev/null 2>&1
one_rc="$(run_checker_files "$d" "rules/od.md")"
one_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$one_rc" = "1" ] && printf '%s' "$one_out" | grep -q 'MISSING_ON_DEMAND_MARKER'; then
    pass "S-ONE-RULE: staging just the violating rule reports MISSING_ON_DEMAND_MARKER"
else
    fail "S-ONE-RULE: want exit 1 + MISSING_ON_DEMAND_MARKER, got $one_rc — output: $(printf '%s' "$one_out" | head -3 | tr '\n' ' ')"
fi
