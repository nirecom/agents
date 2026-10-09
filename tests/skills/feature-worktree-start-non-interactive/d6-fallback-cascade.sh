#!/bin/bash
# tests/skills/feature-worktree-start-non-interactive/d6-fallback-cascade.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/scan-outbound.sh
# Tags: worktree, start, outbound-scan, fallback, TL2, scope:issue-specific
# B19 — the D6 fallback cascade (tiers 0/1 scanned, tier 2 emitted unscanned); contract: the D6 section of derive-worktree-name.sh.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# Stand-in checkout: its scan-outbound.sh logs every scanned value and rejects a per-case ERE (see helpers.sh derive_copy_into).
D6_CFG="$FIXTURE/d6-cfg"
mkdir -p "$D6_CFG/bin" "$D6_CFG/hooks/lib"
cp "$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/parse-closes-issues" "$D6_CFG/bin/parse-closes-issues"
cp "$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/check-private-repo-name.js" "$D6_CFG/bin/check-private-repo-name.js"
# The whole hooks/lib/: check-private-repo-name.js fail-opens when its matcher cannot be required, which would make B19d vacuous.
cp -r "$_HELPERS_SCRIPT_CHECKOUT_ROOT/hooks/lib/." "$D6_CFG/hooks/lib/"
# bin/is-github-dotcom-remote is deliberately absent: the D4 gh label lookup becomes a no-op.
D6_LOG="$FIXTURE/d6-scan-log.txt"
D6_REJECT="$D6_CFG/reject-re"
cat > "$D6_CFG/bin/scan-outbound.sh" <<STUB
#!/bin/bash
d6_value="\$(cat)"
printf '%s\n' "\$d6_value" >> "$D6_LOG"
d6_re="\$(cat "$D6_REJECT" 2>/dev/null)"
[ -n "\$d6_re" ] || exit 0
printf '%s' "\$d6_value" | grep -qE "\$d6_re" && exit 1
exit 0
STUB
chmod +x "$D6_CFG/bin/scan-outbound.sh"
derive_copy_into "$D6_CFG"

INTENT_D6="$FIXTURE/d6-intent.md"
write_intent "$INTENT_D6" 'Zeta gamma delta epsilon' '- #4242: d6 rescan'
D6_TITLE_SLUG="4242-zeta-gamma-delta-epsilon"
# A fixed-name repo dir: D0 scans REPO_NAME, and a random mktemp basename could match a case's reject ERE.
D6_REPO="$FIXTURE/d6-repo"
mkdir -p "$D6_REPO"

# B19a: only the primary name is rejected — the rebuilt fallback is scanned and kept.
: > "$D6_LOG"
printf '%s\n' "^$D6_TITLE_SLUG\$" > "$D6_REJECT"
run_derive_in "$D6_CFG" B19a --intent "$INTENT_D6" --repo-dir "$D6_REPO"

B19A_TN="$(task_name)"
B19A_SCANS="$(grep -c '[^[:space:]]' "$D6_LOG")"
B19A_LAST="$(tail -1 "$D6_LOG")"
if [ "$RC" -eq 0 ] && printf '%s' "$B19A_TN" | grep -qE "^4242-worktree-$TS_RE\$"; then
    pass "B19a: a task name failing the D6 gate is replaced by <issue>-worktree-<ts> ($B19A_TN)"
else
    fail "B19a: expected TASK_NAME=4242-worktree-<14-digit UTC ts> (rc=$RC, tn='$B19A_TN', err='$ERR')"
fi
# 4 scans in order: REPO_NAME (D0), the title (D2), the rejected primary name (D6), the rebuilt one.
if [ "$B19A_SCANS" -eq 4 ] && [ "$(head -1 "$D6_LOG")" = "d6-repo" ] \
    && [ "$B19A_LAST" = "$B19A_TN" ]; then
    pass "B19a/rescan: REPO_NAME is scanned first and the rebuilt fallback name is itself scanned before being emitted"
else
    fail "B19a/rescan: expected 4 scans starting on REPO_NAME and ending on the emitted name (scans=$B19A_SCANS, first='$(head -1 "$D6_LOG")', last='$B19A_LAST', tn='$B19A_TN')"
fi
if [[ "$ERR" == *'derived task name failed the outbound scan'* && "$ERR" != *"$D6_TITLE_SLUG"* ]]; then
    pass "B19a/stderr: the D6 diagnostic names the reason without echoing the blocked value"
else
    fail "B19a/stderr: expected the D6 scan diagnostic and no blocked value on stderr (err='$ERR')"
fi

# B19b: the rebuilt name is rejected too — the fail-safe tier drops the issue prefix.
: > "$D6_LOG"
printf '%s\n' '4242' > "$D6_REJECT"
run_derive_in "$D6_CFG" B19b --intent "$INTENT_D6" --repo-dir "$D6_REPO"

B19B_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B19B_TN" | grep -qE "^worktree-$TS_RE\$"; then
    pass "B19b: a rebuilt fallback that also fails the scan drops the issue prefix ($B19B_TN)"
else
    fail "B19b: expected TASK_NAME=worktree-<14-digit UTC ts> with no issue prefix (rc=$RC, tn='$B19B_TN', err='$ERR')"
fi
if grep -qE "^4242-worktree-$TS_RE\$" "$D6_LOG"; then
    pass "B19b/rescan: the issue-prefixed fallback was scanned, not assumed safe"
else
    fail "B19b/rescan: the rebuilt 4242-worktree-<ts> value never reached the scanner (log='$(cat "$D6_LOG")')"
fi
if [[ "$ERR" == *'dropping the issue prefix'* && "$ERR" == *'no longer traceable to an issue'* ]]; then
    pass "B19b/stderr: the prefix drop is announced together with the traceability it costs"
else
    fail "B19b/stderr: expected the prefix-drop diagnostic naming the lost traceability (err='$ERR')"
fi
# The last scanned value is the tier-1 candidate; a re-introduced tier-2 scan turns this red.
B19B_LAST="$(tail -1 "$D6_LOG")"
if printf '%s' "$B19B_LAST" | grep -qE "^4242-worktree-$TS_RE\$" && [ "$B19B_LAST" != "$B19B_TN" ]; then
    pass "B19b/tier2-not-scanned: the last value scanned is the tier-1 candidate — the emitted tier-2 name is deliberately never handed to the scanner"
else
    fail "B19b/tier2-not-scanned: expected the tier-1 value 4242-worktree-<ts> to be the last scanned value, not the emitted name (last='$B19B_LAST', tn='$B19B_TN')"
fi
if grep -qxF "$B19B_TN" "$D6_LOG"; then
    fail "B19b/tier2-absent: the emitted tier-2 name reached the scanner at least once (tn='$B19B_TN', log='$(cat "$D6_LOG")')"
else
    pass "B19b/tier2-absent: the emitted tier-2 name appears nowhere in the scan log — it is never scanned at all"
fi

# B19c: an ERE rejecting the title slug and every `worktree` value (not REPO_NAME, not the raw title) must still yield a name.
: > "$D6_LOG"
printf '%s\n' 'zeta|worktree' > "$D6_REJECT"
run_derive_in "$D6_CFG" B19c --intent "$INTENT_D6" --repo-dir "$D6_REPO"

B19C_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B19C_TN" | grep -qE "^worktree-$TS_RE\$" \
    && [ "$(branch_type)" = 'feature' ] && [ "$(repo_name)" = 'd6-repo' ]; then
    pass "B19c: a scanner rejecting every 'worktree' value still yields a name — the unscanned tier 2 is emitted with the full stdout contract ($B19C_TN)"
else
    fail "B19c: expected rc=0 with TASK_NAME=worktree-<14-digit UTC ts>, BRANCH_TYPE=feature, REPO_NAME=d6-repo (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$ERR" != *'refusing to emit a name'* ]]; then
    pass "B19c/no-refusal: the removed 'refusing to emit a name' branch is not reachable from the D6 cascade any more"
else
    fail "B19c/no-refusal: the D6 refusal diagnostic reappeared on stderr (err='$ERR')"
fi
B19C_SCANS="$(grep -c '[^[:space:]]' "$D6_LOG")"
# Exactly 4 (D0, D2, D6 tier 0, D6 tier 1): a 5th scan means tier 2 is being scanned again.
if [ "$B19C_SCANS" -eq 4 ]; then
    pass "B19c/tiers: exactly the two scanned D6 tiers reach the scanner (4 scans in total; tier 2 adds none)"
else
    fail "B19c/tiers: expected 4 scans across the D6 cascade (scans=$B19C_SCANS, log='$(cat "$D6_LOG")')"
fi

# B19d: the same breakage driven by the real private-name checker; the origin remote makes D0a exclude the repo's own name.
: > "$D6_LOG"
: > "$D6_REJECT"
D6_F1_REPO="$FIXTURE/d6-f1-repo"
mkdir -p "$D6_F1_REPO"
git -C "$D6_F1_REPO" init -q >/dev/null 2>&1
git -C "$D6_F1_REPO" config core.hooksPath /dev/null
git -C "$D6_F1_REPO" remote add origin https://github.com/acme-org/d6-f1-repo.git
# A title that slugifies to nothing forces the D2 repo-name fallback.
INTENT_D6F1="$FIXTURE/d6-f1-intent.md"
write_intent "$INTENT_D6F1" '!!! @@@' '- #4242: d6 tier-2 emission'
PRIVATE_REPO_NAMES_CACHE="$(printf 'worktree\nd6-f1-repo')"
run_derive_in "$D6_CFG" B19d --intent "$INTENT_D6F1" --repo-dir "$D6_F1_REPO"
PRIVATE_REPO_NAMES_CACHE=''

B19D_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B19D_TN" | grep -qE "^worktree-$TS_RE\$" \
    && [[ "$ERR" != *'refusing to emit a name'* ]]; then
    pass "B19d/production-shape: a private-name list containing 'worktree' no longer makes /worktree-start unnameable — tier 2 is emitted ($B19D_TN)"
else
    fail "B19d/production-shape: expected rc=0 with TASK_NAME=worktree-<14-digit UTC ts> and no refusal diagnostic (rc=$RC, out='$OUT', err='$ERR')"
fi
# Fixture self-check: a fail-opened checker would emit 4242-d6-f1-repo and pass the case above for the wrong reason.
if [[ "$ERR" == *'derived task name failed the outbound scan'* \
    && "$ERR" == *'dropping the issue prefix'* ]]; then
    pass "B19d/armed: both scanned tiers were genuinely rejected by the private-name checker (the tier-2 emission above is real, not a fail-open)"
else
    fail "B19d/armed: expected the D6 tier-0 and tier-1 rejection diagnostics — the checker may have fail-opened (err='$ERR')"
fi
if grep -qxF "$B19D_TN" "$D6_LOG"; then
    fail "B19d/tier2-absent: the emitted tier-2 name was handed to the scanner (tn='$B19D_TN', log='$(cat "$D6_LOG")')"
else
    pass "B19d/tier2-absent: the emitted tier-2 name never reaches either half of scan_clean()"
fi

report_shape d6
finish
