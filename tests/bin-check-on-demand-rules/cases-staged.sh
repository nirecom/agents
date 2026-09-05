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
fx_stage "$d" rules/cond.md
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
fx_stage "$d" hooks/lib/rules-injection-policy.js
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
fx_stage "$d" rules/cond.md
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
fx_stage "$d" rules/od.md
one_rc="$(run_checker_files "$d" "rules/od.md")"
one_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$one_rc" = "1" ] && printf '%s' "$one_out" | grep -q 'MISSING_ON_DEMAND_MARKER'; then
    pass "S-ONE-RULE: staging just the violating rule reports MISSING_ON_DEMAND_MARKER"
else
    fail "S-ONE-RULE: want exit 1 + MISSING_ON_DEMAND_MARKER, got $one_rc — output: $(printf '%s' "$one_out" | head -3 | tr '\n' ' ')"
fi

# --- checkStagedArgs (bin/lib/check-on-demand-rules.js:449-469): the reject/accept
# table for the STAGED-ARGUMENT traversal guard. This is the CPR-ORTH sibling of the
# declaration-value traversal covered in cases-containment.sh T0-T2: same shape (a
# path-like string handed to the checker as attacker-influenced DATA, never followed),
# but the value here arrives as a --staged CLI argument instead of a policy field.
# checkStagedArgs never stats the argument, so the table below uses bare strings —
# some naming real fixture files, some naming nothing at all — and asserts purely on
# whether OUT_OF_ROOT_STAGED_PATH is emitted for that exact argument.
echo ""
echo "=== checkStagedArgs: staged-path traversal guard (accept/reject table) ==="

CASE_N=$((CASE_N + 1)); d="$BASE/stg-trav$CASE_N"
fx_base "$d"; git_commit_all "$d"
SA_ABS_INSIDE="$(node_path "$d/rules/cond.md")"
# A real target OUTSIDE this fixture's root but still inside $BASE, so the absolute
# path is well-formed and points at something that exists — mirrors CT_OUTSIDE in
# cases-containment.sh: a traversal case whose target doesn't exist would also pass
# on a checker that resolves outside the tree and simply finds nothing there.
SA_OUTSIDE_DIR="$BASE/stg-trav-outside"
mkdir -p "$SA_OUTSIDE_DIR"
printf '# outside the checked root\n' > "$SA_OUTSIDE_DIR/escapee.md"
SA_ABS_OUTSIDE="$(node_path "$SA_OUTSIDE_DIR/escapee.md")"

sa_assert() {
    local label="$1" arg="$2" want="$3" rc out line
    rc="$(run_checker_files "$d" "$arg")"
    out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
    line="$(printf '%s\n' "$out" | grep -F 'OUT_OF_ROOT_STAGED_PATH' | grep -F "$arg" | head -1)"
    if [ "$want" = "yes" ]; then
        if [ -n "$line" ] && [ "$rc" = "1" ]; then
            pass "$label"
        else
            fail "$label — want OUT_OF_ROOT_STAGED_PATH naming '$arg' and exit 1, got rc=$rc — output: $(printf '%s' "$out" | head -4 | tr '\n' ' ')"
        fi
    else
        if [ -z "$line" ] && [ "$rc" = "0" ]; then
            pass "$label"
        else
            fail "$label — legit staged path '$arg' must exit 0 with no OUT_OF_ROOT_STAGED_PATH, got rc=$rc — output: $(printf '%s' "$out" | head -4 | tr '\n' ' ')"
        fi
    fi
}

# SA-rel-inside / SA-abs-inside: the allow side (Pattern 4, classifier both directions)
# — a legit staged path, relative and absolute, must not be flagged.
sa_assert "SA-rel-inside: a plain in-root relative path is accepted"          "rules/cond.md"                "no"
sa_assert "SA-abs-inside: an absolute in-root path is accepted"              "$SA_ABS_INSIDE"                "no"
# SA-dotdot-substring: '..' as a SUBSTRING of a filename (not a path segment) must not
# false-positive — the guard splits on path separators before comparing to '..'.
sa_assert "SA-dotdot-substring: '..' inside a filename, not a path segment, is accepted" "rules/foo..bar.md" "no"

# SA-dotdot-prefix / SA-dotdot-embedded: a literal '..' path SEGMENT, leading or
# embedded, must be refused regardless of position.
sa_assert "SA-dotdot-prefix: a leading '../' staged path is rejected"        "../stg-trav-outside/escapee.md" "yes"
sa_assert "SA-dotdot-embedded: an embedded '..' segment is rejected"         "rules/../../stg-trav-outside/escapee.md" "yes"
# SA-bs-dotdot-prefix / SA-bs-dotdot-embedded / SA-bs-dotdot-mixed: the CPR-ORTH
# backslash siblings of the two cases above. checkStagedArgs splits on BOTH separators
# (arg.split(/[\\/]/)), so a Windows-style '..\' traversal must be refused exactly like
# its '../' twin — on every host, since the split is string-level, not platform-level.
sa_assert "SA-bs-dotdot-prefix: a leading '..\\' staged path is rejected"     "..\\stg-trav-outside\\escapee.md" "yes"
sa_assert "SA-bs-dotdot-embedded: an embedded '..' backslash segment is rejected" "rules\\..\\..\\stg-trav-outside\\escapee.md" "yes"
sa_assert "SA-bs-dotdot-mixed: mixed '/' and '\\' separators are rejected"    "rules/..\\../stg-trav-outside/escapee.md" "yes"
# SA-bs-dotdot-substring: the allow side of the backslash branch — '..' as a substring
# of a backslash-separated filename is not a segment and must not false-positive.
sa_assert "SA-bs-dotdot-substring: '..' inside a backslash-separated filename is accepted" "rules\\foo..bar.md" "no"

# SA-abs-outside: an absolute path that resolves outside the checked root is rejected
# even though the file it names really exists (CT-outside's contract, staged-arg side).
sa_assert "SA-abs-outside: an absolute path outside the root is rejected"    "$SA_ABS_OUTSIDE" "yes"
# SA-drive-outside: a Windows drive-letter absolute path is refused by the same
# path.isAbsolute()-or-drive-letter branch, independent of host platform.
sa_assert "SA-drive-outside: a drive-letter absolute path is rejected"       "C:\\Windows\\System32\\evil.md" "yes"
# SA-tilde: a leading '~' is refused unconditionally — it never resolves relative to
# the checked root, so treating it as in-root would be a silent home-directory escape.
sa_assert "SA-tilde: a leading '~' staged path is rejected"                  "~/secrets.md" "yes"
