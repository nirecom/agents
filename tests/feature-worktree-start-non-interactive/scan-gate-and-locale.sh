#!/bin/bash
# lang-check: ignore — intentional non-ASCII/CJK test fixture data (locale disambiguation / slugify robustness cases for issue #1910), not a comment-language violation
# tests/feature-worktree-start-non-interactive/scan-gate-and-locale.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/scan-outbound.sh
# Tags: worktree, start, outbound-scan, locale, TL2, scope:issue-specific
# B16-B18 — the three previously uncovered derive-worktree-name.sh behaviors:
#   B16: D3a scan_clean() gate — text that fails bin/scan-outbound.sh never reaches
#        the task name, and the diagnostic never echoes the offending value.
#   B17: D3b disambiguator() — a pure UTC timestamp; the session id is deliberately
#        not consulted (a local session must not be correlated to a public branch).
#   B18: LC_ALL pinning — slugify() and the D5 bracket-class validation are pinned to
#        LC_ALL=C, so a non-C ambient locale cannot change the derived name.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# A value the real bin/scan-outbound.sh rejects as a hard violation ([IPv4]).
# Any private-info pattern would do; an RFC1918 address is the cheapest one that
# does not require a repo-local .private-info-blocklist. It is assembled at run
# time so this test file does not itself trip the outbound scan on commit.
LEAK="$(printf '%s.%s.%s.%s' 192 168 1 1)"

# --- B16a: an intent title that fails the scan is not embedded --------------
# --repo-dir is pinned to a clean fixture repo so the post-scan fallback slug is
# deterministic (the repo basename) rather than whatever repo the suite runs in.
CLEAN_REPO="$FIXTURE/scan-clean-repo"
mkdir -p "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q >/dev/null 2>&1
git -C "$CLEAN_REPO" config core.hooksPath /dev/null

INTENT_B16="$FIXTURE/b16-intent.md"
write_intent "$INTENT_B16" "Rotate creds on host $LEAK before release" '- #1910: scan gate'
run_derive B16a --intent "$INTENT_B16" --repo-dir "$CLEAN_REPO"
B16A_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$B16A_TN" = "1910-scan-clean-repo" ]; then
    pass "B16a: a title failing the outbound scan is replaced by the repo-name fallback ($B16A_TN)"
else
    fail "B16a: expected TASK_NAME=1910-scan-clean-repo, free of the offending title (rc=$RC, tn='$B16A_TN')"
fi
if [[ "$ERR" == *'using a non-descriptive name instead'* && "$ERR" == *'outbound scan'* ]]; then
    pass "B16a/stderr: the fallback diagnostic names the outbound scan as the reason"
else
    fail "B16a/stderr: expected the 'using a non-descriptive name instead' scan diagnostic (err='$ERR')"
fi
if [[ "$B16A_TN" == *"$LEAK"* || "$B16A_TN" == *192* || "$ERR" == *"$LEAK"* ]]; then
    fail "B16a/leak: the offending value survived into the task name or stderr (tn='$B16A_TN', err='$ERR')"
else
    pass "B16a/leak: the offending value is never embedded nor echoed"
fi

# --- B16b: a --headless label that fails the scan falls back to 'worktree' ---
run_derive B16b --intent "$ABSENT_INTENT" --headless "deploy-to-$LEAK"
B16B_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B16B_TN" | grep -qE "^worktree-$TS_RE\$"; then
    pass "B16b: a --headless label failing the scan yields the non-descriptive worktree-<ts> ($B16B_TN)"
else
    fail "B16b: expected TASK_NAME=worktree-<14-digit UTC ts> (rc=$RC, tn='$B16B_TN')"
fi
if [[ "$ERR" == *'using a non-descriptive name instead'* && "$ERR" != *"$LEAK"* ]]; then
    pass "B16b/stderr: the headless diagnostic reports the fallback without echoing the label"
else
    fail "B16b/stderr: expected the fallback diagnostic and no raw label on stderr (err='$ERR')"
fi

# --- B16c [N2]: a repo name that fails the scan fails CLOSED at D0 ----------
# REPO_NAME is itself an emitted value (stdout line 3), so D0 scans it before anything
# downstream can use it. A repo directory named after an RFC1918 host is exactly the
# case that gate exists for: the run aborts rather than degrading to a fallback slug,
# because there is no safe REPO_NAME left to emit. The diagnostic is a fixed literal —
# a value that failed the scan is never echoed, not even to explain the refusal.
LEAK_REPO="$FIXTURE/host-$LEAK"
mkdir -p "$LEAK_REPO"
git -C "$LEAK_REPO" init -q >/dev/null 2>&1
git -C "$LEAK_REPO" config core.hooksPath /dev/null
INTENT_B16C="$FIXTURE/b16c-intent.md"
write_intent "$INTENT_B16C" '！！！＠＠＠' ''
run_derive B16c --intent "$INTENT_B16C" --repo-dir "$LEAK_REPO"
if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] \
    && [[ "$ERR" == *'the repository directory name failed the outbound scan'* ]]; then
    pass "B16c: a repo directory name failing the outbound scan fails closed at D0 (rc=1, nothing emitted)"
else
    fail "B16c: expected rc=1 with the D0 scan-failure diagnostic and no emitted values (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$OUT" == *"$LEAK"* || "$ERR" == *"$LEAK"* ]]; then
    fail "B16c/leak: the offending repo name reached stdout or stderr (out='$OUT', err='$ERR')"
else
    pass "B16c/leak: the offending repo name is never echoed on stdout or stderr"
fi

# --- B17: disambiguator() is a pure UTC timestamp ---------------------------
# The suffix must be `date -u +%Y%m%d%H%M%S` and nothing else. resolve-session-id is
# broken two ways at once — on PATH, and inside a stand-in AGENTS_CONFIG_DIR — so a
# suffix that still brackets wall-clock UTC proves the session id is not consulted.
FAKE_CFG="$FIXTURE/fake-cfg"
mkdir -p "$FAKE_CFG/bin"
cp "$AGENTS_DIR/bin/scan-outbound.sh" "$FAKE_CFG/bin/scan-outbound.sh"
# scan_clean() also shells out to check-private-repo-name.js (D0's REPO_NAME gate runs
# through the same scan_clean() as the title/label gates) — without a copy here, D0
# would fail closed on a missing script rather than exercising the disambiguator this
# case is actually about.
cp "$AGENTS_DIR/bin/check-private-repo-name.js" "$FAKE_CFG/bin/check-private-repo-name.js"
cat > "$FAKE_CFG/bin/resolve-session-id" <<'STUB'
#!/bin/sh
printf 'resolve-session-id: deliberately broken\n' >&2
exit 1
STUB
chmod +x "$FAKE_CFG/bin/resolve-session-id"
B17_STUBDIR="$FIXTURE/b17-stub"
mkdir -p "$B17_STUBDIR"
cp "$FAKE_CFG/bin/resolve-session-id" "$B17_STUBDIR/resolve-session-id"

B17_SID="b17sessionidmarker"
B17_BEFORE="$(date -u +%Y%m%d%H%M%S)"
B17_SAVED_PATH="$PATH"
B17_SAVED_CFG="$AGENTS_CONFIG_DIR"
PATH="$B17_STUBDIR:$PATH"
export AGENTS_CONFIG_DIR="$FAKE_CFG"
export CLAUDE_CODE_SESSION_ID="$B17_SID"
run_derive B17 --intent "$ABSENT_INTENT" --headless timestamp-probe
unset CLAUDE_CODE_SESSION_ID
export AGENTS_CONFIG_DIR="$B17_SAVED_CFG"
PATH="$B17_SAVED_PATH"
B17_AFTER="$(date -u +%Y%m%d%H%M%S)"

B17_TN="$(task_name)"
B17_SUFFIX="${B17_TN##*-}"
if [ "$RC" -eq 0 ] && printf '%s' "$B17_TN" | grep -qE "^timestamp-probe-$TS_RE\$"; then
    pass "B17/shape: the disambiguator suffix is a 14-digit value ($B17_TN)"
else
    fail "B17/shape: expected TASK_NAME=timestamp-probe-<14 digits> with a broken resolve-session-id (rc=$RC, tn='$B17_TN', err='$ERR')"
fi
if [ -n "$B17_SUFFIX" ] && [ "$B17_SUFFIX" \> "$B17_BEFORE" -o "$B17_SUFFIX" = "$B17_BEFORE" ] \
    && { [ "$B17_SUFFIX" \< "$B17_AFTER" ] || [ "$B17_SUFFIX" = "$B17_AFTER" ]; }; then
    pass "B17/clock: the suffix brackets wall-clock UTC ($B17_BEFORE <= $B17_SUFFIX <= $B17_AFTER)"
else
    fail "B17/clock: expected $B17_BEFORE <= suffix <= $B17_AFTER (suffix='$B17_SUFFIX')"
fi
if [[ "$B17_TN" == *"$B17_SID"* ]]; then
    fail "B17/no-sid: the task name carries the session id ($B17_TN)"
else
    pass "B17/no-sid: the session id never appears in the derived task name"
fi
if grep -n 'disambiguator()' -A 3 "$SCRIPT" | grep -qF 'resolve-session-id'; then
    fail "B17/source: disambiguator() still shells out to resolve-session-id"
else
    pass "B17/source: disambiguator() does not shell out to resolve-session-id"
fi

# --- B18: LC_ALL pinning ----------------------------------------------------
# Mechanism first: slugify(), D4's title lowercasing, and the D5 validation subshell
# must each pin LC_ALL=C themselves, because case folding and bracket-class matching
# are locale-sensitive.
#
# Every mechanism pin below is anchored to the function or section that owns the line.
# A whole-file grep is unusable here: the file carries several LC_ALL=C pins and two
# `tr 'A-Z' 'a-z'` sites, so a file-wide match can be satisfied by a line the assertion
# was never about — and an equivalent refactor inside one function can break a pin that
# has nothing to do with it (a single-subshell rewrite of slugify() is exactly what
# retired the old `LC_ALL=C sed` literal).
B18_SLUGIFY="$(extract_fn slugify "$SCRIPT")"
if [ -z "$B18_SLUGIFY" ]; then
    fail "B18/slugify-pin: slugify() body not found in derive-worktree-name.sh"
    fail "B18/slugify-sed: slugify() body not found in derive-worktree-name.sh"
else
    # (a) the locale pin — wherever inside the body it is applied (per-stage prefix
    #     or one `export LC_ALL=C` covering the whole pipeline subshell).
    if printf '%s\n' "$B18_SLUGIFY" | grep -qF 'LC_ALL=C'; then
        pass "B18/slugify-pin: slugify()'s own body pins LC_ALL=C"
    else
        fail "B18/slugify-pin: slugify()'s body carries no LC_ALL=C pin"
    fi
    # (b) the sed stage the pin has to cover — asserted separately so reordering the
    #     pipeline cannot break the locale assertion and vice versa.
    if printf '%s\n' "$B18_SLUGIFY" | grep -qE '(^|[^[:alnum:]_])sed([^[:alnum:]_]|$)'; then
        pass "B18/slugify-sed: slugify() runs at least one sed stage inside that body"
    else
        fail "B18/slugify-sed: slugify()'s body invokes no sed stage"
    fi
fi

# D4 lowercases the title before the keyword match. `tr 'A-Z' 'a-z'` also occurs inside
# slugify(), so this must be scoped to the D4 section — a file-wide grep would keep
# passing after D4's own lowercasing line was deleted.
B18_D4="$(extract_section '# --- D4:' '# --- D5:' "$SCRIPT")"
if [ -z "$B18_D4" ]; then
    fail "B18/d4-tr-pin: the D4 branch-type section was not found in derive-worktree-name.sh"
elif printf '%s\n' "$B18_D4" | grep -qF "LC_ALL=C tr 'A-Z' 'a-z'"; then
    pass "B18/d4-tr-pin: D4 lowercases the title with an LC_ALL=C-pinned tr"
else
    fail "B18/d4-tr-pin: the D4 section does not lowercase the title via LC_ALL=C tr 'A-Z' 'a-z'"
fi

# Scoped to the D5 section itself (not a whole-file grep): D0's safe_component()
# and D4's title-lowercasing pipeline also carry `export LC_ALL=C` lines, so an
# unscoped match could pass on either of those even if D5's own pin were removed.
B18_D5="$(extract_section '# --- D5:' '# --- D6:' "$SCRIPT")"
if [ -z "$B18_D5" ]; then
    fail "B18/d5-pin: the D5 output-validation section was not found in derive-worktree-name.sh"
elif printf '%s\n' "$B18_D5" | grep -qE '^[[:space:]]*export LC_ALL=C'; then
    pass "B18/d5-pin: the D5 validation block exports LC_ALL=C for its bracket classes"
else
    fail "B18/d5-pin: the D5 validation block does not export LC_ALL=C"
fi

# Behaviorally: the same input under a UTF-8 locale must derive the same name as
# under LC_ALL=C. Full-width input is the discriminating case — an unpinned bracket
# class would keep multibyte characters instead of collapsing them away.
B18_LOCALE=""
for cand in ja_JP.utf8 ja_JP.UTF-8 en_US.utf8 en_US.UTF-8 C.utf8 C.UTF-8; do
    if locale -a 2>/dev/null | grep -qxF "$cand"; then B18_LOCALE="$cand"; break; fi
done
if [ -z "$B18_LOCALE" ]; then
    pass "B18/behavior: SKIP — no UTF-8 locale available on this host (mechanism asserted above)"
else
    B18_LABEL='Ｆｕｌｌ Width MIXED ｎａｍｅ'
    LC_ALL=C run_derive B18/c --intent "$ABSENT_INTENT" --headless "$B18_LABEL"
    B18_C="$(task_name)"; B18_C_RC="$RC"
    LC_ALL="$B18_LOCALE" run_derive B18/utf8 --intent "$ABSENT_INTENT" --headless "$B18_LABEL"
    B18_U="$(task_name)"; B18_U_RC="$RC"
    # Strip the timestamp suffix: only the slug half is locale-sensitive.
    B18_C_SLUG="${B18_C%-*}"
    B18_U_SLUG="${B18_U%-*}"
    if [ "$B18_C_RC" -eq 0 ] && [ "$B18_U_RC" -eq 0 ] && [ -n "$B18_C_SLUG" ] \
        && [ "$B18_C_SLUG" = "$B18_U_SLUG" ]; then
        pass "B18/behavior: LC_ALL=$B18_LOCALE derives the same slug as LC_ALL=C ($B18_U_SLUG)"
    else
        fail "B18/behavior: slug diverged under LC_ALL=$B18_LOCALE (C='$B18_C_SLUG' rc=$B18_C_RC, utf8='$B18_U_SLUG' rc=$B18_U_RC)"
    fi
    if [ "$B18_U_RC" -eq 0 ] && printf '%s' "$B18_U" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'; then
        pass "B18/d5: D5 validation accepts the derived name under a non-C locale ($B18_U)"
    else
        fail "B18/d5: expected a D5-valid task name under LC_ALL=$B18_LOCALE (rc=$B18_U_RC, tn='$B18_U')"
    fi
fi


report_shape scan-locale
finish
