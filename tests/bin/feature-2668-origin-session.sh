#!/bin/bash
# Tests: bin/github-issues/lib/origin-session.sh, bin/github-issues/issue-create.sh, bin/github-issues/clarify-commit-scope.sh, bin/find-peer
# Tags: TL2, scope:issue-specific, issue-2668, origin-session, issue-create, clarify-intent, scan-outbound, security, gitlab, test-lang-exception:e2e
set -u

# #2668: the origin-session marker. Assumed API of lib/origin-session.sh: origin_session_marker <sid>
# prints "<!-- origin-session: <sid> -->". issue-create.sh appends it as the last body line before
# the outbound scan (--origin-session, else bin/resolve-session-id; rc 2 / 3 -> warn, no marker);
# clarify-commit-scope.sh Path C appends it from --session-id. The reader side is FP6 of
# tests/bin/feature-2668-find-peer.js; OS7 is GitLab. gh / glab are PATH-first mocks, no real forge.

# # TL3 gap
#   - A real gh / glab issue create and the hidden rendering of the HTML comment on the forge are
#     not exercised; closest-to-action mitigation: verification (a) of the detail plan, by hand.
#   - GitLab writer: the repo has no GitLab issue-create entry (detail plan scope change 6), so no
#     test can catch a GitLab path that forgets the marker; OS7 checks the read-back side only.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-entry-sandbox.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR" "$TMPROOT/neutral" "$TMPROOT/mock-bin"
export ISSUE_CREATE_SKIP_SCHEMA=1

SID="5ca9b10c-0000-4000-8000-000000002668"
ALT="a1700000-0000-4000-8000-000000000001"
MARKER="<!-- origin-session: $SID -->"
CO="$TMPROOT/co"

# A copy of this checkout, so resolve-session-id and is-github-dotcom-remote can be stubbed. The copy
# takes tracked files only; untracked new bin files of the change under test are added on top.
script_checkout_fixture_copy "$CO" bin hooks || exit 1
node_entry_sandbox_copy "$CO" bin/scan-outbound.sh || exit 1
while IFS= read -r f; do
    [ -n "$f" ] && [ ! -e "$CO/$f" ] && mkdir -p "$CO/$(dirname "$f")" && cp -p "$SCRIPT_CHECKOUT_ROOT/$f" "$CO/$f"
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files --others --exclude-standard -- bin hooks)
printf '#!/usr/bin/env bash\nexit 1\n' > "$CO/bin/is-github-dotcom-remote"
printf '#!/usr/bin/env bash\ntouch "$MOCK_LOG_DIR/rsi-called"\n[ "${RSI_STUB_RC:-2}" = 0 ] && { printf "%%s" "$RSI_STUB_OUT"; exit 0; }\nexit "${RSI_STUB_RC:-2}"\n' > "$CO/bin/resolve-session-id"
chmod +x "$CO/bin/is-github-dotcom-remote" "$CO/bin/resolve-session-id"
: > "$CO/.private-info-allowlist"
: > "$CO/.private-info-blocklist"

# gh mock: logs argv; issue create saves the posted body (--body value or --body-file content).
cat > "$TMPROOT/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$1 ${2:-}" in
  "auth status") echo "scopes: 'project', 'repo'"; exit 0 ;;
  "issue create")
    prev=""
    for a in "$@"; do
      case "$prev" in
        --body) printf '%s\n' "$a" > "$MOCK_LOG_DIR/posted-body" ;;
        --body-file) cat "$a" > "$MOCK_LOG_DIR/posted-body" ;;
      esac
      prev="$a"
    done
    echo "https://github.com/nirecom/agents/issues/999"; exit 0 ;;
esac
exit 0
MOCKGH
chmod +x "$TMPROOT/mock-bin/gh"
MOCK_BIN="$TMPROOT/mock-bin"
command -v cygpath >/dev/null 2>&1 && MOCK_BIN="$(cygpath -u "$MOCK_BIN")"
export PATH="$MOCK_BIN:$PATH"
if ! [ "$(command -v gh 2>/dev/null)" -ef "$MOCK_BIN/gh" ]; then
    echo "FATAL: gh does not resolve to the mock; aborting before any real gh call"
    exit 1
fi

CASE_N=0
new_case() {
    CASE_N=$((CASE_N + 1))
    export MOCK_LOG_DIR="$TMPROOT/case-$CASE_N"
    mkdir -p "$MOCK_LOG_DIR"
    : > "$MOCK_LOG_DIR/gh-calls.log"
    : > "$CO/.private-info-blocklist"
    unset RSI_STUB_RC RSI_STUB_OUT
}
created() { grep -q '^gh issue create' "$MOCK_LOG_DIR/gh-calls.log"; }
posted() { cat "$MOCK_LOG_DIR/posted-body" 2>/dev/null; }
marker_count() { posted | grep -c '<!-- origin-session: '; }
last_line() { posted | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1; }
ERR=""
run_ic() {
    RC=0
    ( cd "$TMPROOT/neutral" && run_with_timeout 60 bash "$CO/bin/github-issues/issue-create.sh" --title "clean title" "$@" ) >"$MOCK_LOG_DIR/out" 2>"$MOCK_LOG_DIR/err" || RC=$?
    ERR="$(head -c 600 "$MOCK_LOG_DIR/err")"
}
state() { printf 'rc=%s created=%s body=[%s] err=[%s]' "$RC" "$(created && echo y || echo n)" "$(posted)" "$ERR"; }

case_begin "OS1 origin_session_marker prints the one-line marker and never a broken comment" "bin/github-issues/lib/origin-session.sh"
LIB="$CO/bin/github-issues/lib/origin-session.sh"
if [ ! -f "$LIB" ]; then
    fail "OS1: bin/github-issues/lib/origin-session.sh is missing"
else
    OUT="$( . "$LIB"; origin_session_marker "$SID" )"
    assert_eq "$OUT" "$MARKER"
    for bad in "x -->evil" "$(printf 'a\nb')" "" "a b"; do
        OUT="$( . "$LIB"; origin_session_marker "$bad" 2>/dev/null )"
        if [ -z "$OUT" ] || printf '%s' "$OUT" | grep -qxE '<!-- origin-session: [A-Za-z0-9_-]+ -->'; then
            pass "OS1: an unsafe sid [$bad] gives no marker or a well-formed one"
        else
            fail "OS1: an unsafe sid [$bad] gave [$OUT]"
        fi
    done
fi
case_end

case_begin "OS2 issue-create --origin-session appends the marker as the last body line" "bin/github-issues/issue-create.sh"
new_case
run_ic --body "ordinary body" --origin-session "$SID"
if [ "$RC" -eq 0 ] && created && [ "$(last_line)" = "$MARKER" ] && [ "$(marker_count)" -eq 1 ] && posted | grep -q '^ordinary body'; then
    pass "OS2: --body + --origin-session -> body kept, marker last, once"
else
    fail "OS2: --body: $(state)"
fi
new_case
BF="$MOCK_LOG_DIR/body.md"
printf 'file body line\n' > "$BF"
run_ic --body-file "$BF" --origin-session "$SID"
if [ "$RC" -eq 0 ] && created && [ "$(last_line)" = "$MARKER" ] && [ "$(marker_count)" -eq 1 ] && posted | grep -q '^file body line'; then
    pass "OS2: --body-file + --origin-session -> body kept, marker last, once"
else
    fail "OS2: --body-file: $(state)"
fi
assert_eq "$(cat "$BF")" "file body line"
case_end

case_begin "OS3 without --origin-session the marker comes from resolve-session-id; rc 2 / 3 warn and create" "bin/github-issues/issue-create.sh"
new_case
export RSI_STUB_RC=0 RSI_STUB_OUT="$ALT"
run_ic --body "ordinary body"
if [ "$RC" -eq 0 ] && created && [ "$(last_line)" = "<!-- origin-session: $ALT -->" ]; then
    pass "OS3: resolver rc 0 -> marker of the resolved id"
else
    fail "OS3: resolver rc 0: $(state)"
fi
for rc in 2 3; do
    new_case
    export RSI_STUB_RC="$rc"
    run_ic --body "ordinary body"
    if [ "$RC" -eq 0 ] && created && [ "$(marker_count)" -eq 0 ] && [ -e "$MOCK_LOG_DIR/rsi-called" ] && printf '%s' "$ERR" | grep -qiE 'origin[- ]session'; then
        pass "OS3: resolver rc $rc -> warning, issue created without a marker"
    else
        fail "OS3: resolver rc $rc: $(state)"
    fi
done
case_end

case_begin "OS4 the marker is inside the scanned stream, and a scan block still blocks" "bin/github-issues/issue-create.sh"
new_case
printf 'origin-session: 5ca9b10c\n' > "$CO/.private-info-blocklist"
run_ic --body "ordinary body" --origin-session "$SID"
if [ "$RC" -eq 1 ] && ! created; then
    pass "OS4: a blocklist hit on the marker alone blocks -> the marker is added before the scan"
else
    fail "OS4: marker scanned: $(state)"
fi
new_case
run_ic --body "ordinary body" --origin-session "$SID"
if [ "$RC" -eq 0 ] && created; then
    pass "OS4: the marker itself passes the real scanner with empty lists"
else
    fail "OS4: marker passes: $(state)"
fi
new_case
run_ic --body "leak 10.0.0.1 here" --origin-session "$SID"
if [ "$RC" -eq 1 ] && ! created; then
    pass "OS4: a private address in the body still blocks with a marker"
else
    fail "OS4: scan block: $(state)"
fi
case_end

case_begin "OS5 a malformed --origin-session never injects text after the comment" "bin/github-issues/issue-create.sh"
new_case
run_ic --body "ordinary body" --origin-session "x -->evil"
if [ ! -f "$LIB" ]; then
    fail "OS5: bin/github-issues/lib/origin-session.sh is missing (an unknown-argument refusal proves nothing)"
elif ! created || ! posted | grep -q -- '-->evil'; then
    pass "OS5: an injected '-->' sid is refused or neutralized"
else
    fail "OS5: injection: $(state)"
fi
new_case
run_ic --body "ordinary body" --origin-session
if [ "$RC" -ne 0 ] && ! created && ! printf '%s' "$ERR" | grep -q 'unknown argument'; then
    pass "OS5: --origin-session without a value -> non-zero, no issue"
else
    fail "OS5: no value: $(state)"
fi
case_end

case_begin "OS6 clarify-commit-scope Path C appends the marker of --session-id" "bin/github-issues/clarify-commit-scope.sh"
write_intent() {
    mkdir -p "$TMPROOT/plans"
    printf '# Tracking issue\n\n**Title:** Add peer lookup\n\n## Issues\n\n## Background / Motivation\nBACKGROUND_MARKER: peers.%s\n\n## Scope\nSCOPE_MARKER: find-peer.\n' "$1" > "$TMPROOT/plans/${SID}-intent.md"
}
run_ccs() {
    RC=0
    ( cd "$TMPROOT/neutral" && run_with_timeout 60 bash "$CO/bin/github-issues/clarify-commit-scope.sh" --session-id "$SID" --plans-dir "$TMPROOT/plans" --issues "" ) >"$MOCK_LOG_DIR/out" 2>"$MOCK_LOG_DIR/err" || RC=$?
    ERR="$(head -c 600 "$MOCK_LOG_DIR/err")"
}
new_case
write_intent ""
run_ccs
if [ "$RC" -eq 0 ] && created && [ "$(last_line)" = "$MARKER" ] && [ "$(marker_count)" -eq 1 ] && posted | grep -q BACKGROUND_MARKER; then
    pass "OS6: Path C -> Background kept, marker of --session-id last, once"
else
    fail "OS6: Path C: $(state)"
fi
new_case
write_intent " host 10.0.0.1 leak"
run_ccs
if [ "$RC" -eq 2 ] && ! created; then
    pass "OS6: Path C scan block still blocks with a marker"
else
    fail "OS6: Path C block: $(state)"
fi
case_end

# GitLab read-back only (see the TL3 gap): `glab api .../issues/42` serves a fixture body ending in
# the marker format of the detail plan as .description; bin/find-peer --role origin must resolve it.
cat > "$TMPROOT/mock-bin/glab" <<'MOCKGLAB'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >> "$MOCK_LOG_DIR/glab-calls.log"
f="$MOCK_LOG_DIR/glab-body"
command -v cygpath >/dev/null 2>&1 && f="$(cygpath -m "$f")"
case "$*" in
  "api "*"issues/42"*)
    [ -f "$f" ] || exit 1
    node -e 'const fs=require("fs");process.stdout.write(JSON.stringify({iid:42,description:fs.readFileSync(process.argv[1],"utf8")}))' "$f"; exit 0 ;;
esac
exit 1
MOCKGLAB
chmod +x "$TMPROOT/mock-bin/glab"
case_begin "OS7 GitLab: find-peer --role origin reads the marker from the glab issue description" "bin/find-peer"
new_case
GL_REPO="$TMPROOT/gl-repo"
harness_git_init "$GL_REPO"
git -C "$GL_REPO" remote add origin "git@gitlab.com:acme/widgets.git"
printf -- '- [r1] #42 T [%s] session=%s\n' "${SID:0:8}" "$SID" > "$MOCK_LOG_DIR/agents.txt"
printf 'GitLab body\n\n%s\n' "$MARKER" > "$MOCK_LOG_DIR/glab-body"
RC=0
# Windows node spawns glab shell-less and resolves only .exe / .com, so the extensionless bash mock
# is invisible there; use the node-binary fake of feature-2668-find-peer/fake-cli.js instead.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) OS7_WIN=1 ;; *) OS7_WIN=0 ;; esac
if [ "$OS7_WIN" -eq 1 ]; then
    FAKE_JS="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2668-find-peer/fake-cli.js")"
    FAKE_DIR="$TMPROOT/fake-cli"
    FAKE_LOG="$MOCK_LOG_DIR/fake-cli.log"
    node -e 'require(process.argv[1]).fakeCliDir(process.argv[2])' "$FAKE_JS" "$(cygpath -m "$FAKE_DIR")"
    GL_JSON="$(node -e 'const fs=require("fs");process.stdout.write(JSON.stringify({iid:42,description:fs.readFileSync(process.argv[1],"utf8")}))' "$(cygpath -m "$MOCK_LOG_DIR/glab-body")")"
    OUT="$( cd "$GL_REPO" && export PATH="$(cygpath -u "$FAKE_DIR"):$PATH" NODE_OPTIONS="--require \"$FAKE_JS\"" FAKE_CLI_LOG="$(cygpath -m "$FAKE_LOG")" FAKE_GLAB_STDOUT="$GL_JSON" FAKE_GH_STATUS=1 && run_with_timeout 60 "$CO/bin/find-peer" --issue 42 --role origin --agents-file "$MOCK_LOG_DIR/agents.txt" 2>"$MOCK_LOG_DIR/err" )" || RC=$?
    grep '"cmd":"glab"' "$FAKE_LOG" 2>/dev/null | grep '"api"' | grep -q 'issues/42' && printf 'glab api issues/42\n' >> "$MOCK_LOG_DIR/glab-calls.log"
    grep -q '"cmd":"gh"' "$FAKE_LOG" 2>/dev/null && printf 'gh (fake)\n' >> "$MOCK_LOG_DIR/gh-calls.log"
else
    OUT="$( cd "$GL_REPO" && run_with_timeout 60 "$CO/bin/find-peer" --issue 42 --role origin --agents-file "$MOCK_LOG_DIR/agents.txt" 2>"$MOCK_LOG_DIR/err" )" || RC=$?
fi
OUT="$(printf '%s' "$OUT" | tr -d '\r')"
if [ -e "$CO/bin/find-peer" ] && [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'ROLE=origin' && printf '%s\n' "$OUT" | grep -qx "SESSION_ID=$SID" && grep -q '^glab api .*issues/42' "$MOCK_LOG_DIR/glab-calls.log" && [ ! -s "$MOCK_LOG_DIR/gh-calls.log" ]; then
    pass "OS7: find-peer reads the origin marker via glab api; gh is never called"
else
    fail "OS7: rc=$RC out=[$OUT] glab=[$(cat "$MOCK_LOG_DIR/glab-calls.log" 2>/dev/null)] gh=[$(cat "$MOCK_LOG_DIR/gh-calls.log")] err=[$(head -c 400 "$MOCK_LOG_DIR/err")]"
fi
case_end

[ "$FAIL" -eq 0 ]
