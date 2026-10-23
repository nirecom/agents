# G-series (#2308) — GitLab forge cases, CPR-ORTH mirror of the GitHub F-series.
# Sourced by feature-325-find-pr-by-marker.sh (uses its FIND_SCRIPT, pass/fail,
# run_with_timeout). Forge is forced with a fake bin/detect-forge-type in a fake
# script checkout; glab is a mock keyed by GL_MOCK_*.

# setup_tmp_gl: fake detect-forge-type (gitlab) + glab mock; SHIM_PROJECT picks
# the resolved project path (empty = unresolvable). GL_MOCK_CLOSED_BY /
# GL_MOCK_MARKER hold pre-jq'd `<iid>\t<sha>` lines (real tab), empty = miss.
setup_tmp_gl() {
    unset SHIM_PROJECT GL_MOCK_EXIT GL_MOCK_CLOSED_BY GL_MOCK_MARKER
    TMP="$(mktemp -d)"
    FAKE_SCRIPT_CHECKOUT_ROOT="$TMP/fake-script-checkout-root"
    mkdir -p "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues" "$TMP/glmockbin"
    GL_FIND_SCRIPT="$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/find-pr-by-marker.sh"
    cp "$FIND_SCRIPT" "$GL_FIND_SCRIPT"
    cat > "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/detect-forge-type" <<'NODE'
"use strict";
const argv = process.argv;
function arg(n){const i=argv.indexOf(n);return i>=0&&i+1<argv.length?argv[i+1]:null;}
const field = arg("--field");
if (field === "type") process.stdout.write("gitlab\n");
else if (field === "project") process.stdout.write((process.env.SHIM_PROJECT === undefined ? "acme/widgets" : process.env.SHIM_PROJECT) + "\n");
else process.stdout.write("\n");
NODE
    export GL_LOG="$TMP/glab.log"
    : > "$GL_LOG"
    cat > "$TMP/glmockbin/glab" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GL_LOG"
# GL_MOCK_EXIT simulates a glab API failure (auth/network): the call is logged
# (so callers can prove glab WAS queried) then exits non-zero before any output.
[ -n "${GL_MOCK_EXIT:-}" ] && exit "$GL_MOCK_EXIT"
case "$*" in
    *closed_by*) [ -n "${GL_MOCK_CLOSED_BY:-}" ] && printf '%s\n' "$GL_MOCK_CLOSED_BY"; exit 0 ;;
    *merge_requests*) [ -n "${GL_MOCK_MARKER:-}" ] && printf '%s\n' "$GL_MOCK_MARKER"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TMP/glmockbin/glab"
    _GL_OLDPATH="$PATH"
    export PATH="$TMP/glmockbin:$PATH"
}

teardown_tmp_gl() {
    export PATH="$_GL_OLDPATH"
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
    unset FAKE_SCRIPT_CHECKOUT_ROOT GL_FIND_SCRIPT GL_LOG SHIM_PROJECT GL_MOCK_CLOSED_BY GL_MOCK_MARKER GL_MOCK_EXIT TMP
}

# run_find_gl [--repo <slug>] <N>: run under the gitlab setup; parses PR_NUMBER /
# MERGE_COMMIT like run_find and exposes FIND_ERR.
run_find_gl() {
    local out rc
    out=$(run_with_timeout 15 bash "$GL_FIND_SCRIPT" "$@" 2>/tmp/find_gl_err.$$)
    rc=$?
    FIND_ERR=$(cat /tmp/find_gl_err.$$ 2>/dev/null)
    rm -f /tmp/find_gl_err.$$
    FIND_OUT="$out"
    unset PR_NUMBER MERGE_COMMIT
    eval "$out" 2>/dev/null
    FIND_PR_NUMBER="${PR_NUMBER:-}"
    FIND_MERGE_COMMIT="${MERGE_COMMIT:-}"
    return $rc
}

GL_CB=$(printf '3\tsha1230')   # closed_by primary line
GL_MK=$(printf '5\tsha4560')   # marker fallback line

# --- G1 (mirror F2): gitlab primary closed_by hit → PR 3 / sha1230.
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ] && [ "$FIND_MERGE_COMMIT" = "sha1230" ]; then
    pass "G1: gitlab primary closed_by hit → PR 3 sha1230"
else
    fail "G1: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G2 (mirror F1): primary empty → marker fallback across merged MRs → PR 5.
setup_tmp_gl
GL_MOCK_MARKER="$GL_MK" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "5" ] && [ "$FIND_MERGE_COMMIT" = "sha4560" ]; then
    pass "G2: gitlab marker fallback when closed_by empty → PR 5 sha4560"
else
    fail "G2: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G3 (mirror F3): primary miss + fallback empty → exit 1 "no MR".
setup_tmp_gl
run_find_gl 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$FIND_ERR" | grep -qi "no MR"; then
    pass "G3: gitlab primary miss + fallback empty → exit 1 (no MR)"
else
    fail "G3: rc=$RC err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G4 (mirror F7): closed_by primary wins over a stale marker MR.
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" GL_MOCK_MARKER="$GL_MK" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ] && [ "$FIND_MERGE_COMMIT" = "sha1230" ]; then
    pass "G4: gitlab closed_by primary wins over marker fallback"
else
    fail "G4: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G5 (gitlab edge): project path unresolvable → exit 1, glab never queried.
setup_tmp_gl
SHIM_PROJECT="" GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl 42; RC=$?
if [ "$RC" -eq 1 ] && echo "$FIND_ERR" | grep -qi "could not resolve GitLab project" && [ ! -s "$GL_LOG" ]; then
    pass "G5: gitlab unresolvable project → exit 1, glab not called"
else
    fail "G5: rc=$RC err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

# --- G6 (gitlab edge): cross-repo --repo mismatch → exit 2, glab never queried.
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl --repo other/project 42; RC=$?
if [ "$RC" -eq 2 ] && echo "$FIND_ERR" | grep -qi "does not support cross-repo" && [ ! -s "$GL_LOG" ]; then
    pass "G6: gitlab cross-repo --repo mismatch → exit 2, glab not called"
else
    fail "G6: rc=$RC err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

# --- G7 (gitlab edge): --repo equal to the resolved project is accepted and the
# primary lookup still runs (proves the guard rejects only a MISMATCH).
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl --repo acme/widgets 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ]; then
    pass "G7: gitlab --repo matching the project is accepted → PR 3"
else
    fail "G7: rc=$RC pr=$FIND_PR_NUMBER err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G8 (mirror F6, ORTH): non-numeric N rejected BEFORE forge detection → exit
# 1, no shell injection, and glab is never invoked (numeric guard precedes forge).
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_with_timeout 15 bash "$GL_FIND_SCRIPT" "42; touch /tmp/G8_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/G8_INJECT ] && [ ! -s "$GL_LOG" ]; then
    pass "G8: gitlab non-numeric N → exit 1 before forge detection, glab not called"
else
    fail "G8: rc=$RC inject=$([ -f /tmp/G8_INJECT ] && echo yes || echo no) gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
    rm -f /tmp/G8_INJECT 2>/dev/null
fi
teardown_tmp_gl

# --- G9 (gitlab edge): glab API hard failure (non-zero exit, e.g. auth/network).
# The script wraps every glab call in `... 2>/dev/null) || VAR=""`, so a non-zero
# glab degrades to the same not-found path — exit 1 "no MR" — WITHOUT crashing
# under `set -uo pipefail`. glab MUST have been queried (log non-empty), which
# distinguishes this from G5 (unresolvable project → glab never called).
setup_tmp_gl
GL_MOCK_EXIT=1 GL_MOCK_CLOSED_BY="$GL_CB" GL_MOCK_MARKER="$GL_MK" run_find_gl 42; RC=$?
if [ "$RC" -eq 1 ] && echo "$FIND_ERR" | grep -qi "no MR" && [ -s "$GL_LOG" ]; then
    pass "G9: gitlab glab API failure (non-zero exit) → exit 1 (no MR), glab was queried"
else
    fail "G9: rc=$RC err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

# --- G10 (gitlab edge): nested-namespace project path (3+ segments) is URL-encoded
# so `/` → `%2F` before interpolation into `glab api projects/<path>/...`. Proves
# the script encodes subgroup paths correctly (a raw `/` would address the wrong
# REST endpoint). The primary closed_by lookup still resolves PR 3.
setup_tmp_gl
SHIM_PROJECT="group/sub/project" GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ] && grep -q "projects/group%2Fsub%2Fproject/issues/42/closed_by" "$GL_LOG" 2>/dev/null; then
    pass "G10: gitlab subgroup project path encoded group%2Fsub%2Fproject → PR 3"
else
    fail "G10: rc=$RC pr=$FIND_PR_NUMBER err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl
