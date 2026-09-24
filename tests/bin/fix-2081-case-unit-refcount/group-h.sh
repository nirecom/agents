# Group H: physical orphan-case-block removal (--apply helper) (#2081)
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/fix-2081-case-unit-refcount.sh
#
# On partial-orphan, trp_remove_orphan_cases rebuilds the file skipping ONLY the
# orphan cases' [begin,end] line ranges: surviving cases stay byte-for-byte, the
# result passes bash -n, file mode is preserved, and the file is git-added. The
# C4 global-state contract requires calling it right after the verdict.

if ! require_fn trp_case_refcount_verdict "H0a"; then return 0; fi
if ! require_fn trp_remove_orphan_cases "H0b"; then return 0; fi

# run_remove <repo> <rel> — verdict then removal, both in the repo CWD and in
# THIS shell so the TRP_CASE_* globals the removal reads are the verdict's.
run_remove() {
    local repo="$1" rel="$2" saved="$PWD"
    trp_case_refcount_verdict "$repo" "$rel" >/dev/null 2>&1
    cd "$repo" 2>/dev/null || return 2
    trp_remove_orphan_cases "$repo" "$rel" >/dev/null 2>&1
    local rc=$?
    cd "$saved" 2>/dev/null || true
    return $rc
}

H_REPO="$(make_repo)"
add_src "$H_REPO" "bin/h-live.sh"
# bin/h-dead.sh missing. The dropped case carries a C7 `|| true` suffix (H must
# still remove its whole block, end-suffix line included).
add_raw "$H_REPO" "h-partial.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/h-live.sh, bin/h-dead.sh
# Tags: TL2, scope:issue-specific
case_begin "keep" "bin/h-live.sh"
echo keep-body-marker
case_end
case_begin "drop" "bin/h-dead.sh"
echo drop-body-marker
case_end || true
EOF
chmod 0755 "$H_REPO/tests/h-partial.sh"
commit_repo "$H_REPO" "group-h partial-orphan fixture"

# Precondition: this is a partial-orphan (refcount 1, one orphan case).
run_verdict "$H_REPO" "tests/h-partial.sh"
assert_eq "H0c fixture is partial-orphan before removal" "partial-orphan" "${TRP_VERDICT:-x}"

_H_MODE_BEFORE="$(stat -c '%a' "$H_REPO/tests/h-partial.sh" 2>/dev/null || echo '?')"
run_remove "$H_REPO" "tests/h-partial.sh"

H_BODY="$(cat "$H_REPO/tests/h-partial.sh")"
if printf '%s' "$H_BODY" | grep -q "keep-body-marker"; then
    pass "H1 surviving case body preserved"
else
    fail "H1 surviving case body was lost (body=<<$H_BODY>>)"
fi
if printf '%s' "$H_BODY" | grep -qE 'drop-body-marker|case_begin "drop"'; then
    fail "H2 orphan case block was NOT fully removed (body=<<$H_BODY>>)"
else
    pass "H2 orphan case block (begin..end incl C7 suffix) fully removed"
fi

if bash -n "$H_REPO/tests/h-partial.sh" 2>/dev/null; then
    pass "H3 rewritten file passes bash -n"
else
    fail "H3 rewritten file is not syntactically valid"
fi

_H_MODE_AFTER="$(stat -c '%a' "$H_REPO/tests/h-partial.sh" 2>/dev/null || echo '?')"
assert_eq "H4 file mode preserved across atomic rewrite" "$_H_MODE_BEFORE" "$_H_MODE_AFTER"

assert_eq "H5 the rewritten file is staged (git add)" \
    "M  tests/h-partial.sh" "$(git -C "$H_REPO" status --porcelain -- tests/h-partial.sh)"

# H6 — the surviving case's own begin/end markers are both still present.
if printf '%s\n' "$H_BODY" | grep -qxF 'case_begin "keep" "bin/h-live.sh"' \
    && printf '%s\n' "$H_BODY" | grep -qxF 'case_end'; then
    pass "H6 surviving case markers intact"
else
    fail "H6 surviving case markers were disturbed (body=<<$H_BODY>>)"
fi

unset _H_MODE_BEFORE _H_MODE_AFTER

# ── C2 — non-contiguous multiple orphan blocks, both C7 suffix forms ─────────
# Two orphan cases separated by a surviving case (non-contiguous). One drops a
# `|| true` suffix, the other a `>/dev/null 2>&1 || rc2=$?` suffix. Every
# surviving block must remain byte-for-byte; both orphan blocks (begin..end incl
# their divergent C7 suffix line) must be gone.
HM_REPO="$(make_repo)"
add_src "$HM_REPO" "bin/hm-live.sh"
# bin/hm-dead1.sh and bin/hm-dead2.sh are absent → cases 2 and 4 are orphan.
add_raw "$HM_REPO" "hm-multi.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/hm-live.sh, bin/hm-dead1.sh, bin/hm-live.sh, bin/hm-dead2.sh
# Tags: TL2, scope:issue-specific
case_begin "keepA" "bin/hm-live.sh"
echo keepA-body-marker
case_end
case_begin "dropA" "bin/hm-dead1.sh"
echo dropA-body-marker
case_end || true
case_begin "keepB" "bin/hm-live.sh"
echo keepB-body-marker
case_end
case_begin "dropB" "bin/hm-dead2.sh"
echo dropB-body-marker
case_end >/dev/null 2>&1 || rc2=$?
EOF
commit_repo "$HM_REPO" "group-h non-contiguous multi-orphan fixture"

run_verdict "$HM_REPO" "tests/hm-multi.sh"
assert_eq "H7 fixture is partial-orphan (two survivors, two orphan cases)" \
    "partial-orphan" "${TRP_VERDICT:-x}"

run_remove "$HM_REPO" "tests/hm-multi.sh"
HM_BODY="$(cat "$HM_REPO/tests/hm-multi.sh")"

if printf '%s' "$HM_BODY" | grep -qE 'dropA-body-marker|dropB-body-marker|case_begin "dropA"|case_begin "dropB"'; then
    fail "H8 a non-contiguous orphan block was not fully removed (body=<<$HM_BODY>>)"
else
    pass "H8 both non-contiguous orphan blocks (both C7 suffix forms) removed"
fi

# Byte-preservation: the file must equal EXACTLY the two survivors in order, with
# the shebang and the (unmodified) `# Tests:` header preserved verbatim — down to
# the trailing newline. `$(...)` capture strips trailing newlines symmetrically,
# so it cannot prove byte equality; write the expected bytes to a file (printf
# '%s\n' terminates the last line, matching the fixture heredoc's final newline)
# and compare with cmp so any trailing-newline drift is caught.
HM_EXPECT_FILE="$HM_REPO/hm-multi.expect"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Tests: bin/hm-live.sh, bin/hm-dead1.sh, bin/hm-live.sh, bin/hm-dead2.sh' \
    '# Tags: TL2, scope:issue-specific' \
    'case_begin "keepA" "bin/hm-live.sh"' \
    'echo keepA-body-marker' \
    'case_end' \
    'case_begin "keepB" "bin/hm-live.sh"' \
    'echo keepB-body-marker' \
    'case_end' > "$HM_EXPECT_FILE"
if cmp -s "$HM_EXPECT_FILE" "$HM_REPO/tests/hm-multi.sh"; then
    pass "H9 surviving blocks byte-identical (both survivors in order, trailing newline incl)"
else
    fail "H9 surviving blocks NOT byte-for-byte preserved (diff: <<$(diff "$HM_EXPECT_FILE" "$HM_REPO/tests/hm-multi.sh" 2>&1)>>)"
fi

if bash -n "$HM_REPO/tests/hm-multi.sh" 2>/dev/null; then
    pass "H10 multi-orphan rewrite passes bash -n"
else
    fail "H10 multi-orphan rewrite is not syntactically valid"
fi

assert_eq "H11 multi-orphan rewrite staged" \
    "M  tests/hm-multi.sh" "$(git -C "$HM_REPO" status --porcelain -- tests/hm-multi.sh)"
