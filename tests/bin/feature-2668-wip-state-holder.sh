#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-holder.sh, bin/github-issues/wip-state/gitlab.sh, bin/find-peer
# Tags: TL2, scope:issue-specific, issue-2668, wip-state, holder, forge, gitlab, github, test-lang-exception:e2e
set -u

# #2668: the read-only verb `wip-state.sh holder <N>` prints the raw WIP holder session id (empty
# when there is none) and exits 1 when the read fails. GitHub reuses the cmd-check query (mocked by
# tests/agents/feature-wip-state/setup.sh); GitLab returns the id only for exactly one wip-fp:*
# label. WH3 runs bin/find-peer on the GitHub mock end to end (GitLab end to end: find-peer.js FP8).

# # TL3 gap
#   - A real Projects v2 board and a real GitLab label set are not read; closest-to-action
#     mitigation: verification (a) of the detail plan, run by hand before release.
#   - The ListAgents text fed to --agents-file is a placeholder shape until verification (b)
#     saves real output as a fixture (C1, known gap).

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

TARGET="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh"
TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
. "$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-wip-state/setup.sh"

HOLDER="b0de1234-0000-4000-8000-000000002668"
READER="7eade700-0000-4000-8000-000000000001"

make_origin_repo() { # <dir> <url>
    harness_git_init "$1"
    git -C "$1" remote add origin "$2"
}
OUT=""
RC=0
run_holder() { # <repo> <arg...>
    local repo="$1"; shift
    RC=0
    OUT="$( cd "$repo" && run_with_timeout 60 bash "$TARGET" holder "$@" 2>"$TMPROOT/err" )" || RC=$?
    OUT="${OUT%$'\r'}"
}
err() { head -c 400 "$TMPROOT/err" 2>/dev/null; }

case_begin "WH1 GitHub: holder prints the Projects v2 session-id text of the item" "bin/github-issues/wip-state/cmd-holder.sh"
for row in "present|PVTI_existing|$HOLDER||$HOLDER|0" "empty field|PVTI_existing||||0" "no item||$HOLDER|||0" "graphql failure|PVTI_existing|$HOLDER|graphql||1"; do
    IFS='|' read -r label item fp failmode want wantrc <<<"$row"
    setup_mock
    export CLAUDE_CODE_SESSION_ID="$READER"
    export GH_MOCK_PROJECT_ITEM_ID="$item" GH_MOCK_STATUS="In Progress" GH_MOCK_FINGERPRINT="$fp" GH_MOCK_FAIL="$failmode"
    make_origin_repo "$TMP/repo" "https://github.com/nirecom/agents.git"
    run_holder "$TMP/repo" 42
    if [ "$RC" -eq "$wantrc" ] && [ "$OUT" = "$want" ]; then
        pass "WH1 $label: rc $wantrc, stdout [$want]"
    else
        fail "WH1 $label: rc=$RC out=[$OUT] want rc $wantrc [$want] err=[$(err)]"
    fi
    teardown_mock
done
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing" GH_MOCK_FINGERPRINT="$HOLDER"
make_origin_repo "$TMP/repo" "https://github.com/nirecom/agents.git"
run_holder "$TMP/repo" abc
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [ -e "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state/cmd-holder.sh" ]; then
    pass "WH1 a non-numeric issue number -> non-zero, no holder"
else
    fail "WH1 non-numeric: rc=$RC out=[$OUT] (cmd-holder.sh present: $([ -e "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state/cmd-holder.sh" ] && echo y || echo n))"
fi
teardown_mock
case_end

case_begin "WH4 GitHub: holder is empty unless the item status is In Progress" "bin/github-issues/wip-state/cmd-holder.sh"
for st in "Todo" "Done"; do
    setup_mock
    export CLAUDE_CODE_SESSION_ID="$READER"
    export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing" GH_MOCK_STATUS="$st" GH_MOCK_FINGERPRINT="$HOLDER" GH_MOCK_FAIL=""
    make_origin_repo "$TMP/repo" "https://github.com/nirecom/agents.git"
    run_holder "$TMP/repo" 42
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
        pass "WH4 status $st: rc 0, empty holder"
    else
        fail "WH4 status $st: rc=$RC out=[$OUT] want rc 0 [] err=[$(err)]"
    fi
    teardown_mock
done
case_end

# WH3 runs find-peer from a copy of bin/ and hooks/ whose destination-policy.js is rewritten per
# row (assumed shape {DESTINATION_KIND, FROM_REPLY_VERIFIED}), so the branch is an input.
CO="$TMPROOT/co"
script_checkout_fixture_copy "$CO" bin hooks || exit 1
while IFS= read -r f; do
    [ -n "$f" ] && [ ! -e "$CO/$f" ] && mkdir -p "$CO/$(dirname "$f")" && cp -p "$SCRIPT_CHECKOUT_ROOT/$f" "$CO/$f"
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files --others --exclude-standard -- bin hooks)
FIND_PEER="$CO/bin/find-peer"
set_policy() { # <DESTINATION_KIND>
    mkdir -p "$CO/bin/find-peer.d"
    printf '"use strict";\nmodule.exports = { DESTINATION_KIND: "%s", FROM_REPLY_VERIFIED: false };\n' "$1" > "$CO/bin/find-peer.d/destination-policy.js"
}
kv() { printf '%s\n' "$OUT" | tr -d '\r' | sed -n "s/^$1=//p" | head -n 1; }
HOLDER_NAME="#42 T [${HOLDER:0:8}]"
case_begin "WH3 GitHub: bin/find-peer --issue reads the Projects v2 holder and prints a sendable DESTINATION" "bin/find-peer"
# label|fingerprint|gh failure|branch|rc|ROLE|SESSION_ID|DESTINATION|DESTINATION_KIND|REASON
for row in \
    "present, branch session-id|$HOLDER||session-id|0|working|$HOLDER|$HOLDER|session-id|" \
    "present, branch ref|$HOLDER||ref|0|working|$HOLDER|r1|ref|" \
    "present, branch name|$HOLDER||name|0|working|$HOLDER|$HOLDER_NAME [r1]|name|" \
    "empty field|||session-id|3|||||no-holder" \
    "graphql failure|$HOLDER|graphql|session-id|7|||||forge-read-failed"; do
    IFS='|' read -r label fp failmode branch wantrc wantrole wantsid wantdest wantkind wantreason <<<"$row"
    set_policy "$branch"
    setup_mock
    export CLAUDE_CODE_SESSION_ID="$READER"
    export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing" GH_MOCK_STATUS="In Progress" GH_MOCK_FINGERPRINT="$fp" GH_MOCK_FAIL="$failmode"
    make_origin_repo "$TMP/repo" "https://github.com/nirecom/agents.git"
    printf -- '- [r1] %s session=%s\n' "$HOLDER_NAME" "$HOLDER" > "$TMP/agents.txt"
    RC=0
    OUT="$( cd "$TMP/repo" && run_with_timeout 60 "$FIND_PEER" --issue 42 --agents-file "$TMP/agents.txt" 2>"$TMPROOT/err" )" || RC=$?
    got="rc=$RC ROLE=[$(kv ROLE)] SESSION_ID=[$(kv SESSION_ID)] DESTINATION=[$(kv DESTINATION)] DESTINATION_KIND=[$(kv DESTINATION_KIND)] REASON=[$(kv REASON)]"
    want="rc=$wantrc ROLE=[$wantrole] SESSION_ID=[$wantsid] DESTINATION=[$wantdest] DESTINATION_KIND=[$wantkind] REASON=[$wantreason]"
    if [ -e "$FIND_PEER" ] && [ "$got" = "$want" ]; then
        pass "WH3 $label: $want"
    else
        fail "WH3 $label: got $got want $want err=[$(err)]"
    fi
    teardown_mock
done
case_end

# GitLab: glab answers `issue view N --json labels` from GLAB_LABELS (comma list), or fails when
# GLAB_FAIL=1; gh logs and fails, so a GitHub fallback shows up in its log.
GL_BIN="$TMPROOT/gl-bin"
mkdir -p "$GL_BIN"
cat > "$GL_BIN/glab" <<'GLABEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GL_LOG"
[ "${GLAB_FAIL:-0}" = 1 ] && { echo "glab: failed" >&2; exit 1; }
case "$*" in
  *"--json labels"*)
    body="" ; IFS=',' read -r -a ls <<<"${GLAB_LABELS:-}"
    case "${GLAB_STYLE:-compact}" in
      spaced) for l in "${ls[@]}"; do [ -n "$l" ] && body="${body:+$body, }{\"name\": \"$l\"}"; done
              echo "{\"labels\": [$body]}" ;;
      pretty) printf '{\n  "labels": [\n'; i=0
              for l in "${ls[@]}"; do [ -n "$l" ] || continue; [ "$i" -gt 0 ] && printf ',\n'
                  printf '    {\n      "name": "%s"\n    }' "$l"; i=$((i+1)); done
              printf '\n  ]\n}\n' ;;
      *) for l in "${ls[@]}"; do [ -n "$l" ] && body="${body:+$body,}{\"name\":\"$l\"}"; done
         echo "{\"labels\":[$body]}" ;;
    esac ;;
  *) echo "" ;;
esac
exit 0
GLABEOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_LOG"\nexit 1\n' > "$GL_BIN/gh"
chmod +x "$GL_BIN/glab" "$GL_BIN/gh"
export GL_LOG="$TMPROOT/glab.log" GH_LOG="$TMPROOT/gh.log"
command -v cygpath >/dev/null 2>&1 && GL_BIN="$(cygpath -u "$GL_BIN")"
export PATH="$GL_BIN:$PATH"
export AGENTS_MAIN_ROOT="$TMPROOT/fake-main-root"
mkdir -p "$AGENTS_MAIN_ROOT"
export CLAUDE_CODE_SESSION_ID="$READER"
GL_REPO="$TMPROOT/gl-repo"
make_origin_repo "$GL_REPO" "git@gitlab.com:acme/widgets.git"

case_begin "WH2 GitLab: holder is the id of exactly one wip-fp label" "bin/github-issues/wip-state/gitlab.sh"
for row in "no wip-fp label|status:wip||0" "one wip-fp label|status:wip,wip-fp:$HOLDER|$HOLDER|0" "two wip-fp labels|status:wip,wip-fp:$HOLDER,wip-fp:$READER||1" "a failed label read|FAIL||1"; do
    IFS='|' read -r label labels want wantrc <<<"$row"
    : > "$GL_LOG"
    : > "$GH_LOG"
    if [ "$labels" = FAIL ]; then export GLAB_FAIL=1 GLAB_LABELS=""; else export GLAB_FAIL=0 GLAB_LABELS="$labels"; fi
    run_holder "$GL_REPO" 42
    if [ "$RC" -eq "$wantrc" ] && [ "$OUT" = "$want" ] && grep -q -- '42' "$GL_LOG" && [ ! -s "$GH_LOG" ]; then
        pass "WH2 $label: rc $wantrc, stdout [$want], glab read, gh never called"
    else
        fail "WH2 $label: rc=$RC out=[$OUT] want rc $wantrc [$want] glab=[$(cat "$GL_LOG")] gh=[$(cat "$GH_LOG")] err=[$(err)]"
    fi
done
case_end

case_begin "WH5 GitLab: holder parses labels JSON with whitespace and pretty-printing" "bin/github-issues/wip-state/gitlab.sh"
for style in spaced pretty; do
    : > "$GL_LOG"
    : > "$GH_LOG"
    export GLAB_FAIL=0 GLAB_STYLE="$style" GLAB_LABELS="status:wip,wip-fp:$HOLDER"
    run_holder "$GL_REPO" 42
    if [ "$RC" -eq 0 ] && [ "$OUT" = "$HOLDER" ]; then
        pass "WH5 $style JSON: rc 0, stdout [$HOLDER]"
    else
        fail "WH5 $style JSON: rc=$RC out=[$OUT] want rc 0 [$HOLDER] err=[$(err)]"
    fi
done
unset GLAB_STYLE
case_end

[ "$FAIL" -eq 0 ]
