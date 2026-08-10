#!/bin/bash
# tests/feature-worktree-start-non-interactive/d6-fallback-cascade.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/scan-outbound.sh
# Tags: worktree, start, outbound-scan, fallback, TL2, scope:issue-specific
# B19 — the D6 outbound-scan fallback cascade of derive-worktree-name.sh.
#   B19a: the primary name is rejected; the rebuilt <issue>-worktree-<ts> is re-scanned.
#   B19b: the rebuilt name is rejected too; the issue prefix is dropped and announced.
#   B19c: every tier is rejected; the script refuses to emit a name at all.
# Split out of scan-gate-and-locale.sh (file-split WARN at >300 lines) — the scan-gate
# file keeps the real-scanner cases (B16) and the locale pins (B18); this one owns the
# stand-in-scanner seam that makes the D6 scan *sequence* observable.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# --- B19 [F3]: the D6 fallback name is itself re-scanned --------------------
# D6 rebuilds "<issue>-worktree-<ts>" when the emitted name fails the outbound scan.
# The rebuilt value still embeds $ISSUE, so it must pass the gate too rather than be
# assumed safe; a second failure drops the issue prefix entirely.
#
# B16 drives the real scanner, which can only reject values that carry a real
# private-info pattern — it cannot make the *derived* name fail while the source text
# passes. So D6 gets a stand-in AGENTS_CONFIG_DIR (the same seam B17 uses in
# scan-gate-and-locale.sh) whose
# scan-outbound.sh logs every value it is handed and rejects the ones matching a
# per-case ERE. The log is what makes the scan *sequence* observable: asserting only
# the final name cannot distinguish "re-scanned and accepted" from "assumed safe".
D6_CFG="$FIXTURE/d6-cfg"
mkdir -p "$D6_CFG/bin" "$D6_CFG/hooks/lib"
# parse-closes-issues resolves its lib as <cfg>/hooks/lib/, so both halves are copied;
# the issue number is what the fail-safe prefix-drop tier is about.
cp "$AGENTS_DIR/bin/parse-closes-issues" "$D6_CFG/bin/parse-closes-issues"
cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$D6_CFG/hooks/lib/parse-closes-issues.js"
# scan_clean() also shells out to check-private-repo-name.js (D0's REPO_NAME gate runs
# through the same scan_clean() as every other D6 tier) — without a copy here, D0 would
# fail closed on a missing script before any of the stand-in scanner logic below runs.
cp "$AGENTS_DIR/bin/check-private-repo-name.js" "$D6_CFG/bin/check-private-repo-name.js"
# bin/is-github-dotcom-remote is deliberately NOT provided: its absence makes the D4
# gh label lookup a no-op, so BRANCH_TYPE stays title-derived and no network is touched.
D6_LOG="$FIXTURE/d6-scan-log.txt"
D6_REJECT="$D6_CFG/reject-re"
cat > "$D6_CFG/bin/scan-outbound.sh" <<STUB
#!/bin/bash
# Stand-in scanner: record every scanned value, reject the ones matching this case's ERE.
d6_value="\$(cat)"
printf '%s\n' "\$d6_value" >> "$D6_LOG"
d6_re="\$(cat "$D6_REJECT" 2>/dev/null)"
[ -n "\$d6_re" ] || exit 0
printf '%s' "\$d6_value" | grep -qE "\$d6_re" && exit 1
exit 0
STUB
chmod +x "$D6_CFG/bin/scan-outbound.sh"

INTENT_D6="$FIXTURE/d6-intent.md"
write_intent "$INTENT_D6" 'Zeta gamma delta epsilon' '- #4242: d6 rescan'
D6_TITLE_SLUG="4242-zeta-gamma-delta-epsilon"
D6_SAVED_CFG="$AGENTS_CONFIG_DIR"
# A fixed-name repo dir rather than $FIXTURE itself: D0 now scans REPO_NAME, and the
# per-case reject ERE must not be able to match a random mktemp basename by accident
# (a `4242` substring in the temp name would abort the run at D0 instead).
D6_REPO="$FIXTURE/d6-repo"
mkdir -p "$D6_REPO"

# B19a: only the primary name is rejected — the rebuilt fallback is scanned and kept.
: > "$D6_LOG"
printf '%s\n' "^$D6_TITLE_SLUG\$" > "$D6_REJECT"
export AGENTS_CONFIG_DIR="$D6_CFG"
run_derive B19a --intent "$INTENT_D6" --repo-dir "$D6_REPO"
export AGENTS_CONFIG_DIR="$D6_SAVED_CFG"

B19A_TN="$(task_name)"
B19A_SCANS="$(grep -c '[^[:space:]]' "$D6_LOG")"
B19A_LAST="$(tail -1 "$D6_LOG")"
if [ "$RC" -eq 0 ] && printf '%s' "$B19A_TN" | grep -qE "^4242-worktree-$TS_RE\$"; then
    pass "B19a: a task name failing the D6 gate is replaced by <issue>-worktree-<ts> ($B19A_TN)"
else
    fail "B19a: expected TASK_NAME=4242-worktree-<14-digit UTC ts> (rc=$RC, tn='$B19A_TN', err='$ERR')"
fi
# 4 scans, in order: REPO_NAME (D0, emitted on stdout line 3) + the intent title (D2)
# + the rejected primary name (D6) + the rebuilt one. The D2 repo-name-fallback scan
# does not fire on this path — slugify(title) is non-empty here.
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
# Without the re-scan this case would emit an unscanned 4242-prefixed name.
: > "$D6_LOG"
printf '%s\n' '4242' > "$D6_REJECT"
export AGENTS_CONFIG_DIR="$D6_CFG"
run_derive B19b --intent "$INTENT_D6" --repo-dir "$D6_REPO"
export AGENTS_CONFIG_DIR="$D6_SAVED_CFG"

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
# [A3] Losing the issue prefix costs the caller its traceability back to the issue, so
# the drop must be announced — silently emitting a differently-shaped name would leave
# the operator to discover it from the branch name later.
if [[ "$ERR" == *'dropping the issue prefix'* && "$ERR" == *'no longer traceable to an issue'* ]]; then
    pass "B19b/stderr: the prefix drop is announced together with the traceability it costs"
else
    fail "B19b/stderr: expected the prefix-drop diagnostic naming the lost traceability (err='$ERR')"
fi
# The third D6 call site: the prefix-less name is scanned too, rather than asserted
# clean. "Every emitted name passed the scan" has to hold on this path as well.
if [ "$(tail -1 "$D6_LOG")" = "$B19B_TN" ]; then
    pass "B19b/rescan3: the prefix-less fallback was itself scanned last, immediately before being emitted"
else
    fail "B19b/rescan3: the emitted prefix-less name was not the last value scanned (last='$(tail -1 "$D6_LOG")', tn='$B19B_TN')"
fi

# --- B19c [A3]: all three D6 tiers rejected — refuse to emit any name -------
# The terminal branch of the cascade. Without it the script would either emit an
# unscanned name or loop; the contract is a hard rc=1 with nothing on stdout.
# The ERE rejects both the title-derived slug and every `worktree-` fallback, but
# neither REPO_NAME (`d6-repo`) nor the raw title (`Zeta ...`, capitalized).
: > "$D6_LOG"
printf '%s\n' 'zeta|worktree' > "$D6_REJECT"
export AGENTS_CONFIG_DIR="$D6_CFG"
run_derive B19c --intent "$INTENT_D6" --repo-dir "$D6_REPO"
export AGENTS_CONFIG_DIR="$D6_SAVED_CFG"

if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] \
    && [[ "$ERR" == *'refusing to emit a name'* ]]; then
    pass "B19c: when every D6 fallback tier fails the scan the script emits nothing and exits 1"
else
    fail "B19c: expected rc=1, empty stdout, and the 'refusing to emit a name' diagnostic (rc=$RC, out='$OUT', err='$ERR')"
fi
B19C_SCANS="$(grep -c '[^[:space:]]' "$D6_LOG")"
# 5 = REPO_NAME (D0) + the title (D2) + all three D6 tiers.
if [ "$B19C_SCANS" -eq 5 ]; then
    pass "B19c/tiers: all three D6 fallback tiers were scanned before the refusal (5 scans in total)"
else
    fail "B19c/tiers: expected 5 scans across the full D6 cascade (scans=$B19C_SCANS, log='$(cat "$D6_LOG")')"
fi

report_shape d6
finish
