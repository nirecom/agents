# Group K: idempotency — a second --apply is a clean no-op (#2081)
# Tests: bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, idempotency, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# The nightly cron re-runs against a tree the previous pass may already have
# swept. After the first --apply removes the orphan case block, the file holds
# only surviving cases (verdict alive), so the second pass must remove nothing,
# stage nothing beyond the first pass, and surface no git error.

if ! require_fn trp_case_refcount_verdict "K0"; then return 0; fi

K_REPO="$(make_repo)"
add_src "$K_REPO" "bin/k-live.sh"
add_raw "$K_REPO" "cc-partial-k.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/k-live.sh, bin/k-dead.sh
# Tags: TL2, scope:common
case_begin "keep" "bin/k-live.sh"
echo keep-k-marker
case_end
case_begin "drop" "bin/k-dead.sh"
echo drop-k-marker
case_end
EOF
commit_repo "$K_REPO" "group-k idempotency fixture"

K_STUB="$TMPDIR_BASE/k-stub"
install_gh_mock "$K_STUB"
export MOCK_ISSUES=""

# ── K1: first --apply removes the orphan case block ─────────────────────────
run_in_repo "$K_REPO" "$K_STUB" "$AUDIT_COMMON" --apply --format text
K1_OUT="$OUT"; K1_RC="$RC"
if printf '%s\n' "$K1_OUT" | grep -qE "CASE_REMOVED: tests/cc-partial-k\.sh"; then
    pass "K1 first pass removes the orphan case block"
else
    fail "K1 expected a CASE_REMOVED line on first pass (out=<<$K1_OUT>> rc=$K1_RC)"
fi
if printf '%s\n' "$(cat "$K_REPO/tests/cc-partial-k.sh")" | grep -q "drop-k-marker"; then
    fail "K1b orphan case block survived the first pass"
else
    pass "K1b orphan case block gone after first pass"
fi
K_STATE_AFTER_1="$(git -C "$K_REPO" status --porcelain | sort)"
_K_BODY_AFTER_1="$(cat "$K_REPO/tests/cc-partial-k.sh")"

# ── K2: second --apply over the swept tree is a clean no-op ─────────────────
run_in_repo "$K_REPO" "$K_STUB" "$AUDIT_COMMON" --apply --format text
K2_OUT="$OUT"; K2_RC="$RC"; K2_ERR="$ERR"

assert_eq "K2 second pass removes nothing more" "0" \
    "$(count_lines "$K2_OUT" CASE_REMOVED)"
assert_eq "K2b second pass exits 1 (no findings, not an error)" "1" "$K2_RC"
assert_eq "K2c file content byte-identical after the second pass" \
    "$_K_BODY_AFTER_1" "$(cat "$K_REPO/tests/cc-partial-k.sh")"
assert_eq "K2d index unchanged by the second pass" \
    "$K_STATE_AFTER_1" "$(git -C "$K_REPO" status --porcelain | sort)"

if printf '%s\n' "$K2_ERR" | grep -qiE "fatal:|did not match any files|pathspec"; then
    fail "K2e second pass surfaced a git error (err=<<$K2_ERR>>)"
else
    pass "K2e second pass surfaces no git error"
fi

unset MOCK_ISSUES _K_BODY_AFTER_1
