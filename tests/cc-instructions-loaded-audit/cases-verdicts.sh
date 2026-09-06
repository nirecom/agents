# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, instructions-loaded, classifier, table-driven, TL2, scope:common
#
# Verdict classification: 4 verdicts x 3 load_reason variants, plus the named
# edge cases the detail plan calls out by hand.

echo ""
echo "=== verdict classification (verdict x load_reason) ==="

CASE_N=0
while IFS='|' read -r name relpath lr want; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; relpath="${relpath//[[:space:]]/}"
    lr="${lr//[[:space:]]/}"; want="${want//[[:space:]]/}"
    CASE_N=$((CASE_N + 1))
    sid="tblsid$CASE_N"
    fp="$(node_path "$REPO/$relpath")"
    res="$(fire "$sid" "$fp" "$lr")"
    rc="${res%%|*}"; sout="${res#*|}"
    got="$(read_field "$sid" "$fp" verdict)"
    if [ "$rc" != "0" ]; then
        fail "$name: hook exited $rc (must always be 0)"
    elif [ -n "$sout" ]; then
        fail "$name: stdout must be empty, got '$sout'"
    elif [ "$got" != "$want" ]; then
        fail "$name: want verdict $want, got $got"
    else
        pass "$name (verdict=$got, stdout empty, exit 0)"
    fi
done <<'TABLE'
ok-conditional-lr-absent   | rules/ok-conditional.md | OMIT               | ok
ok-conditional-lr-null     | rules/ok-conditional.md | null               | ok
ok-conditional-lr-glob     | rules/ok-conditional.md | "path_glob_match"  | ok
missing-lr-absent          | rules/missing.md        | OMIT               | S-MISSING
missing-lr-null            | rules/missing.md        | null               | S-MISSING
missing-lr-glob            | rules/missing.md        | "path_glob_match"  | S-MISSING
malformed-lr-absent        | rules/malformed.md      | OMIT               | S-MALFORMED
malformed-lr-null          | rules/malformed.md      | null               | S-MALFORMED
malformed-lr-glob          | rules/malformed.md      | "path_glob_match"  | S-MALFORMED
leak-lr-absent             | rules/leak.md           | OMIT               | S-LEAK
leak-lr-null               | rules/leak.md           | null               | S-LEAK
leak-lr-glob               | rules/leak.md           | "path_glob_match"  | S-LEAK
TABLE

# --- E1 (independent, named): load_reason=path_glob_match must NOT downgrade S-LEAK.
# This is the fail-open hole the detail plan calls out in 3-4: if the reserved real
# path is ever created, the loader reports a "legitimate" glob match and an
# AND-conditioned predicate would silently stop detecting the leak.
E1_SID="e1leakglob"
E1_FP="$(node_path "$REPO/rules/leak.md")"
fire "$E1_SID" "$E1_FP" '"path_glob_match"' >/dev/null
e1_verdict="$(read_field "$E1_SID" "$E1_FP" verdict)"
e1_reason="$(read_field "$E1_SID" "$E1_FP" load_reason)"
if [ "$e1_verdict" = "S-LEAK" ] && [ "$e1_reason" = "path_glob_match" ]; then
    pass "E1: load_reason=path_glob_match still yields S-LEAK and is recorded as a diagnostic"
else
    fail "E1: want verdict=S-LEAK load_reason=path_glob_match, got verdict=$e1_verdict load_reason=$e1_reason"
fi

# --- E2: ok-listed (no paths: but in EXPECTED_UNCONDITIONAL) is NOT S-MISSING ---
E2_SID="e2listed"
E2_FP="$(node_path "$REPO/rules/ok-listed.md")"
fire "$E2_SID" "$E2_FP" OMIT >/dev/null
e2="$(read_field "$E2_SID" "$E2_FP" verdict)"
[ "$e2" = "ok" ] && pass "E2: paths-less rule listed in EXPECTED_UNCONDITIONAL classifies ok" \
    || fail "E2: want ok for a listed unconditional rule, got $e2"

# --- E3: non-rules file_path is always ok ---
E3_SID="e3nonrule"
E3_FP="$(node_path "$REPO/docs/not-a-rule.md")"
fire "$E3_SID" "$E3_FP" '"path_glob_match"' >/dev/null
e3="$(read_field "$E3_SID" "$E3_FP" verdict)"
[ "$e3" = "ok" ] && pass "E3: file_path outside rules/**/*.md classifies ok" \
    || fail "E3: want ok for a non-rules path, got $e3"

# --- U1/U2: the `unreadable` verdict, both error shapes. Why separate: the classifier reads the file's ON-DISK
# frontmatter, so every verdict above assumes the read succeeds. When it doesn't, the hook must neither guess a
# verdict nor take the session down — it records `unreadable` and stays fail-open (exit 0, empty stdout), because a
# hook that can fail a turn is worse than one that occasionally can't tell. The two shapes reach the same catch via
# different syscall errors, both real: a rules-root path that no longer exists (ENOENT — a rule deleted/renamed
# between the loader's read and the hook's), and a DIRECTORY read as a file (EISDIR on POSIX, ENOTDIR/EPERM on
# Windows — a subdirectory named .md, or a path assembled one segment short). CPR-ORTH: same class, so both get
# a case. Each asserts all three halves — verdict, exit 0, empty stdout — because an `unreadable` receipt from
# a hook that also crashed the turn would be a regression. ---
unreadable_case() {
    local label="$1" sid="$2" abspath="$3" res rc sout got
    local fp
    fp="$(node_path "$abspath")"
    res="$(fire "$sid" "$fp" OMIT)"
    rc="${res%%|*}"; sout="${res#*|}"
    got="$(read_field "$sid" "$fp" verdict)"
    if [ "$rc" != "0" ]; then
        fail "$label: hook exited $rc — an audit hook must stay fail-open (exit 0) when it cannot read the file"
    elif [ -n "$sout" ]; then
        fail "$label: stdout must be empty, got '$sout'"
    elif [ "$got" != "unreadable" ]; then
        fail "$label: want verdict 'unreadable', got '$got'"
    else
        pass "$label (verdict=unreadable, stdout empty, exit 0)"
    fi
}

# (a) ENOENT: a rules-root path that was never created.
unreadable_case "U1: a nonexistent file under a rules root classifies unreadable" \
    "u1enoent" "$REPO/rules/never-created.md"

# (b) EISDIR / ENOTDIR: a DIRECTORY whose name ends in .md, so it passes the
# rules/**/*.md shape test and only fails at the read.
mkdir -p "$REPO/rules/a-directory.md"
if [ -d "$REPO/rules/a-directory.md" ]; then
    unreadable_case "U2: a directory read as a rule file classifies unreadable" \
        "u2eisdir" "$REPO/rules/a-directory.md"
else
    fail "U2: could not create the directory fixture $REPO/rules/a-directory.md — the EISDIR shape is UNVERIFIED"
fi

# --- UF3 (issue #2218 Step 10/13): the emergency-flush rule against the REAL policy and the REAL
# rules tree. Every case above grades a fixture tree, which can only prove the classifier works;
# this one is the registration itself — a rule the session must receive without earning it by glob
# is `ok` only while the policy that ships names it. Swapping the policy pin (and restoring it) is
# the whole setup: the hook reads it from the environment. ---
UF3_SID="uf3flush"
UF3_FP="$(node_path "$AGENTS_DIR/rules/handoff-emergency-flush.md")"
UF3_SAVED_POLICY="$RULES_INJECTION_POLICY"
UF3_SAVED_PROJECT="$CLAUDE_PROJECT_DIR"
RULES_INJECTION_POLICY="$(node_path "$AGENTS_DIR/hooks/lib/rules-injection-policy.js")"
# The project dir moves with the policy: toRulesKey() derives the rules root from
# it, so leaving it on the fixture tree would classify the real path as "not a
# rules file" and return a vacuous ok.
CLAUDE_PROJECT_DIR="$(node_path "$AGENTS_DIR")"
fire "$UF3_SID" "$UF3_FP" OMIT >/dev/null
uf3="$(read_field "$UF3_SID" "$UF3_FP" verdict)"
RULES_INJECTION_POLICY="$UF3_SAVED_POLICY"
CLAUDE_PROJECT_DIR="$UF3_SAVED_PROJECT"
if [ "$uf3" = "ok" ]; then
    pass "UF3: rules/handoff-emergency-flush.md classifies ok against the shipped policy — registered unconditional, no paths: needed"
else
    fail "UF3: want ok for rules/handoff-emergency-flush.md against the shipped policy, got '$uf3' — issue #2218 Step 10 registers it in EXPECTED_UNCONDITIONAL and Step 14 authors the file; write_code has not run"
fi

# --- UF4 (positive control for UF3): `ok` is ALSO E3's verdict for "not a rules file", so
# UF3 going green while the CLAUDE_PROJECT_DIR/RULES_INJECTION_POLICY swap has silently stopped
# taking effect would be indistinguishable from a real pass. Fire the identical swapped
# environment against a real ON-DEMAND rule instead: rules/test.md ships with the reserved
# `paths: [".on-demand-only/never-match"]` glob (see classify()'s ON_DEMAND_TOKEN branch), so a
# fire against it — meaning the hook reports it loaded anyway — must classify S-LEAK. Only a
# verdict other than "ok"/"unreadable" here proves the real rules tree, not a fixture, was read. ---
UF4_SID="uf4realondemand"
UF4_FP="$(node_path "$AGENTS_DIR/rules/test.md")"
UF4_SAVED_POLICY="$RULES_INJECTION_POLICY"
UF4_SAVED_PROJECT="$CLAUDE_PROJECT_DIR"
RULES_INJECTION_POLICY="$(node_path "$AGENTS_DIR/hooks/lib/rules-injection-policy.js")"
CLAUDE_PROJECT_DIR="$(node_path "$AGENTS_DIR")"
fire "$UF4_SID" "$UF4_FP" OMIT >/dev/null
uf4="$(read_field "$UF4_SID" "$UF4_FP" verdict)"
RULES_INJECTION_POLICY="$UF4_SAVED_POLICY"
CLAUDE_PROJECT_DIR="$UF4_SAVED_PROJECT"
if [ "$uf4" = "S-LEAK" ]; then
    pass "UF4: rules/test.md (a real on-demand rule) classifies S-LEAK under the identical swapped environment — the swap is proven live, so UF3's ok is not vacuous"
else
    fail "UF4: want S-LEAK for rules/test.md under the swapped environment, got '$uf4' — if this is 'ok' the swap silently stopped classifying the real rules tree and UF3 would be a vacuous pass"
fi
