#!/bin/bash
# tests/feature-worktree-start-non-interactive/d6-fallback-cascade.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/scan-outbound.sh
# Tags: worktree, start, outbound-scan, fallback, TL2, scope:issue-specific

# B19 — the D6 outbound-scan fallback cascade of derive-worktree-name.sh.
#   B19a: the primary name is rejected; the rebuilt <issue>-worktree-<ts> is re-scanned.
#   B19b: the rebuilt name is rejected too; the issue prefix is dropped and announced.
#   B19c: an ERE that also rejects every `worktree` value still yields a name —
#         the last tier is emitted unconditionally rather than re-scanned.
#   B19d: the same breakage in its production shape, driven by the real private-name
#         checker instead of the stand-in scanner.

# [F1] Three tiers, first two scanned:
#   tier 0  slugified task name                        -> scanned
#   tier 1  "${ISSUE:+${ISSUE}-}worktree-${DISAMBIG}"  -> scanned (embeds $ISSUE)
#   tier 2  "worktree-${DISAMBIG}"                     -> NOT scanned, always emitted
# Tier 2 carries no caller/title/remote text, so a scan there could only over-match
# and emit no name at all; the invariant is "a name is ALWAYS constructible"
# (#1910), and B19b/B19c/B19d keep the deleted re-scan from creeping back.

# Split out of scan-gate-and-locale.sh (>300 lines), which keeps B16/B18; this file
# owns the stand-in-scanner seam. Part of the
# feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# --- B19 [F3]: the D6 fallback name is itself re-scanned --------------------
# D6 rebuilds "<issue>-worktree-<ts>" when the name fails the scan; the rebuilt
# value still embeds $ISSUE so it must be re-scanned, and a second failure drops
# the prefix. The real scanner (B16) cannot fail a derived name whose source text
# passes, so this file uses a stand-in AGENTS_CONFIG_DIR whose scan-outbound.sh
# logs every value and rejects a per-case ERE — the log makes the scan *sequence*
# observable ("re-scanned" vs "assumed safe").
D6_CFG="$FIXTURE/d6-cfg"
mkdir -p "$D6_CFG/bin" "$D6_CFG/hooks/lib"
# parse-closes-issues resolves its lib as <cfg>/hooks/lib/, so both halves are copied;
# the issue number is what the fail-safe prefix-drop tier is about.
cp "$AGENTS_DIR/bin/parse-closes-issues" "$D6_CFG/bin/parse-closes-issues"
# scan_clean() also shells out to check-private-repo-name.js (D0's REPO_NAME gate runs
# through the same scan_clean() as every other D6 tier) — without a copy here, D0 would
# fail closed on a missing script before any of the stand-in scanner logic below runs.
cp "$AGENTS_DIR/bin/check-private-repo-name.js" "$D6_CFG/bin/check-private-repo-name.js"
# The whole hooks/lib/ rather than parse-closes-issues.js alone: check-private-repo-name.js
# resolves its matcher as <cfg>/hooks/lib/is-private-repo.js and fail-OPENS (exit 0) when
# that require throws, so a partial copy would leave the private-name half of scan_clean()
# silently dead — B19d, which drives the cascade through that half, would pass vacuously.
# is-private-repo.js has lib-local requires of its own, so the directory goes in whole.
# B19a-B19c are unaffected: they run under setup_fixture's empty declared list, where an
# armed checker and a fail-open one are indistinguishable by construction.
cp -r "$AGENTS_DIR/hooks/lib/." "$D6_CFG/hooks/lib/"
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
# [F1] B19b/tier2-not-scanned — the deliberate non-scan, asserted as such: the last
# value handed to the scanner is the tier-1 candidate, and the emitted tier-2 name
# comes after it, unscanned. A re-introduced tier-2 scan turns this red.
B19B_LAST="$(tail -1 "$D6_LOG")"
if printf '%s' "$B19B_LAST" | grep -qE "^4242-worktree-$TS_RE\$" && [ "$B19B_LAST" != "$B19B_TN" ]; then
    pass "B19b/tier2-not-scanned: the last value scanned is the tier-1 candidate — the emitted tier-2 name is deliberately never handed to the scanner"
else
    fail "B19b/tier2-not-scanned: expected the tier-1 value 4242-worktree-<ts> to be the last scanned value, not the emitted name (last='$B19B_LAST', tn='$B19B_TN')"
fi
# [F1] Direct evidence rather than positional evidence. "Not last" would still be
# satisfied if tier 2 were scanned somewhere earlier in the run (e.g. by a future
# pre-validation pass); "absent from the log entirely" is the property the source
# actually promises, and it is what a reader checking the deleted re-scan will look for.
if grep -qxF "$B19B_TN" "$D6_LOG"; then
    fail "B19b/tier2-absent: the emitted tier-2 name reached the scanner at least once (tn='$B19B_TN', log='$(cat "$D6_LOG")')"
else
    pass "B19b/tier2-absent: the emitted tier-2 name appears nowhere in the scan log — it is never scanned at all"
fi

# --- B19c [F1]: a scanner that rejects every `worktree` value must still yield a name
# Regression guard for the breakage F1 fixed: re-scanning tier 2 made this input
# rc=1 with no name at all. Contract now: rc=0 with full three-line stdout.
# The ERE rejects the title slug and every `worktree` value, but neither
# REPO_NAME (`d6-repo`) nor the raw title (`Zeta ...`, capitalized).
: > "$D6_LOG"
printf '%s\n' 'zeta|worktree' > "$D6_REJECT"
export AGENTS_CONFIG_DIR="$D6_CFG"
run_derive B19c --intent "$INTENT_D6" --repo-dir "$D6_REPO"
export AGENTS_CONFIG_DIR="$D6_SAVED_CFG"

B19C_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B19C_TN" | grep -qE "^worktree-$TS_RE\$" \
    && [ "$(branch_type)" = 'feature' ] && [ "$(repo_name)" = 'd6-repo' ]; then
    pass "B19c: a scanner rejecting every 'worktree' value still yields a name — the unscanned tier 2 is emitted with the full stdout contract ($B19C_TN)"
else
    fail "B19c: expected rc=0 with TASK_NAME=worktree-<14-digit UTC ts>, BRANCH_TYPE=feature, REPO_NAME=d6-repo (rc=$RC, out='$OUT', err='$ERR')"
fi
# Asserted positively, not merely as "rc happens to be 0": that diagnostic is the
# fingerprint of the deleted refusal branch, so its reappearance is the earliest signal
# that the tier-2 re-scan came back even if some other path kept rc at 0.
if [[ "$ERR" != *'refusing to emit a name'* ]]; then
    pass "B19c/no-refusal: the removed 'refusing to emit a name' branch is not reachable from the D6 cascade any more"
else
    fail "B19c/no-refusal: the D6 refusal diagnostic reappeared on stderr (err='$ERR')"
fi
B19C_SCANS="$(grep -c '[^[:space:]]' "$D6_LOG")"
# 4 = REPO_NAME (D0) + the title (D2) + D6 tier 0 + D6 tier 1. It was 5 while tier 2
# was re-scanned; the drop to 4 IS the change, so the count is asserted exactly rather
# than as a lower bound — a 5th scan means tier 2 is being scanned again.
if [ "$B19C_SCANS" -eq 4 ]; then
    pass "B19c/tiers: exactly the two scanned D6 tiers reach the scanner (4 scans in total; tier 2 adds none)"
else
    fail "B19c/tiers: expected 4 scans across the D6 cascade (scans=$B19C_SCANS, log='$(cat "$D6_LOG")')"
fi

# --- B19d [F1]: the same breakage in its production shape -------------------
# Reproduces the reported bug against the real matcher, not a stub ERE: the other
# half of scan_clean() — the private-repo-name checker — where a private repo named
# `worktree` made every tier match and /worktree-start permanently unusable.

# List entries: `worktree` (kills both scanned tiers) and the fixture repo's own
# basename (kills the D2 repo-name fallback at D6). The latter is reachable only
# because D0a excludes it from the REPO_NAME gates — hence the origin remote below.
# The full list still reaches the title scan and D6 tiers (split pinned by B21h).
# The stand-in scan-outbound.sh stays with an empty reject ERE, so every rejection
# is attributable to the private-name checker alone.
: > "$D6_LOG"
: > "$D6_REJECT"
D6_F1_REPO="$FIXTURE/d6-f1-repo"
mkdir -p "$D6_F1_REPO"
git -C "$D6_F1_REPO" init -q >/dev/null 2>&1
git -C "$D6_F1_REPO" config core.hooksPath /dev/null
git -C "$D6_F1_REPO" remote add origin https://github.com/acme-org/d6-f1-repo.git
# A title that slugifies to nothing forces the D2 repo-name fallback, which is what
# puts the repo's own name into the composed task name for D6 to reject.
INTENT_D6F1="$FIXTURE/d6-f1-intent.md"
write_intent "$INTENT_D6F1" '!!! @@@' '- #4242: d6 tier-2 emission'
# Exported INTO the script — that inbound contract is unchanged by F3. What changed is
# only the OUTBOUND direction: the script no longer re-exports either variable, and the
# list now reaches the checker over stdin (asserted directly in env-nonexposure.sh).
PRIVATE_REPO_NAMES_CACHE="$(printf 'worktree\nd6-f1-repo')"
export AGENTS_CONFIG_DIR="$D6_CFG"
run_derive B19d --intent "$INTENT_D6F1" --repo-dir "$D6_F1_REPO"
export AGENTS_CONFIG_DIR="$D6_SAVED_CFG"
PRIVATE_REPO_NAMES_CACHE=''

B19D_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B19D_TN" | grep -qE "^worktree-$TS_RE\$" \
    && [[ "$ERR" != *'refusing to emit a name'* ]]; then
    pass "B19d/production-shape: a private-name list containing 'worktree' no longer makes /worktree-start unnameable — tier 2 is emitted ($B19D_TN)"
else
    fail "B19d/production-shape: expected rc=0 with TASK_NAME=worktree-<14-digit UTC ts> and no refusal diagnostic (rc=$RC, out='$OUT', err='$ERR')"
fi
# Self-check on the fixture, not a second copy of the assertion above: if the checker
# had fail-opened (missing hooks/lib/, wrong stdin wiring) nothing would have been
# rejected, the run would have emitted `4242-d6-f1-repo`, and the case above would have
# passed for the wrong reason — a green that proves nothing.
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
