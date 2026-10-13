#!/usr/bin/env bash
# feature-2527-local-head-state.sh — #2527: a MERGED forge answer stands only for the local HEAD.
# Tests: hooks/lib/forge/pr-state.js, hooks/lib/forge/merge-state.js
# Tags: scope:issue-specific, workflow, release-phase, forge, pr-state, issue-2527
# TL2: calls stateForLocalHead / mergeStateForLocalHead in-process against fixture git repos
# (real `git rev-parse HEAD`); no forge CLI is involved.
# TL3 gap (not caught here): the head commit a real gh / glab reports for a branch name that
# was reused after an earlier PR merged; tests/hooks/feature-2527-forge-head-wiring.sh covers
# the wiring with stubbed CLIs only.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

LH_TMP="$(make_tmp)"
readonly LH_TMP
trap 'cd / || true; rm -rf "$LH_TMP"' EXIT
harness_isolate "$LH_TMP/iso"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
cd "$LH_TMP" || exit 1

LH_ROOT="$(np "$SCRIPT_CHECKOUT_ROOT")"
export LH_ROOT
# git must not walk up from a fixture dir that is no repo into some enclosing checkout.
export GIT_CEILING_DIRECTORIES="$LH_TMP"

check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }

REPO="$LH_TMP/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config core.autocrlf false
printf 'one\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m one
FIRST="$(git -C "$REPO" rev-parse HEAD)"
printf 'two\n' >> "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m two
HEAD_OID="$(git -C "$REPO" rev-parse HEAD)"
REPO_M="$(np "$REPO")"
OTHER_OID="1111111111111111111111111111111111111111"

UNBORN="$LH_TMP/unborn"
harness_git_init "$UNBORN"
UNBORN_M="$(np "$UNBORN")"
mkdir -p "$LH_TMP/plain"
PLAIN_M="$(np "$LH_TMP/plain")"
MISSING_M="$(np "$LH_TMP")/does-not-exist"

# slh <repoDir> <state> <head-json|undefined> — stateForLocalHead's answer.
IFS= read -r -d '' SLH_JS <<'JS' || true
const { stateForLocalHead } = require(process.env.LH_ROOT + "/hooks/lib/forge/pr-state.js");
const [repo, state, headJson] = process.argv.slice(1);
const head = headJson === "undefined" ? undefined : JSON.parse(headJson);
try { console.log(String(stateForLocalHead(repo, state, head))); } catch (e) { console.log("THROW:" + e.message); }
JS
slh() { run_with_timeout 30 node -e "$SLH_JS" "$1" "$2" "$3" 2>&1; }

# mslh <repoDir> <state> <head-json|undefined> — mergeStateForLocalHead over a fully populated
# answer: "state|number|mergeState|url|error|same=<returned the very answer object>".
IFS= read -r -d '' MSLH_JS <<'JS' || true
const ms = require(process.env.LH_ROOT + "/hooks/lib/forge/merge-state.js");
const [repo, state, headJson] = process.argv.slice(1);
const head = headJson === "undefined" ? undefined : JSON.parse(headJson);
const answer = { state, number: "42", mergeState: "CLEAN", url: "https://github.com/example/repo/pull/42", error: "" };
try {
  const r = ms.mergeStateForLocalHead(repo, answer, head);
  console.log([r.state, r.number, r.mergeState, r.url, r.error, "same=" + (r === answer)].join("|"));
} catch (e) { console.log("THROW:" + e.message); }
JS
mslh() { run_with_timeout 30 node -e "$MSLH_JS" "$1" "$2" "$3" 2>&1; }

case_begin "sanity: the fixture has two distinct commits" "hooks/lib/forge/pr-state.js"
if [[ "$HEAD_OID" =~ ^[0-9a-f]{40,64}$ ]]; then pass "local HEAD is a commit id"; else fail "local HEAD is a commit id" "got=[$HEAD_OID]"; fi
if [[ "$FIRST" =~ ^[0-9a-f]{40,64}$ && "$FIRST" != "$HEAD_OID" ]]; then pass "earlier commit differs from HEAD"; else fail "earlier commit differs from HEAD" "first=[$FIRST] head=[$HEAD_OID]"; fi
case_end

case_begin "A1 MERGED with a head commit other than the local HEAD -> NONE" "hooks/lib/forge/pr-state.js"
check "unrelated commit id" "$(slh "$REPO_M" MERGED "\"$OTHER_OID\"")" "NONE"
check "an earlier commit of the same branch" "$(slh "$REPO_M" MERGED "\"$FIRST\"")" "NONE"
check "a prefix of the local HEAD is not the local HEAD" "$(slh "$REPO_M" MERGED "\"${HEAD_OID:0:12}\"")" "NONE"
case_end

case_begin "A2 MERGED with the local HEAD as head commit -> MERGED" "hooks/lib/forge/pr-state.js"
check "exact match" "$(slh "$REPO_M" MERGED "\"$HEAD_OID\"")" "MERGED"
check "upper-case hex" "$(slh "$REPO_M" MERGED "\"${HEAD_OID^^}\"")" "MERGED"
check "surrounding whitespace and newline" "$(slh "$REPO_M" MERGED "\"  $HEAD_OID\\n\"")" "MERGED"
check "upper-case with CRLF" "$(slh "$REPO_M" MERGED "\"\\t${HEAD_OID^^}\\r\\n\"")" "MERGED"
case_end

case_begin "A3 MERGED with a head commit but an unreadable local HEAD -> UNKNOWN" "hooks/lib/forge/pr-state.js"
check "repoDir does not exist" "$(slh "$MISSING_M" MERGED "\"$HEAD_OID\"")" "UNKNOWN"
check "repoDir is not a git repo" "$(slh "$PLAIN_M" MERGED "\"$HEAD_OID\"")" "UNKNOWN"
check "repo without a commit (unborn HEAD)" "$(slh "$UNBORN_M" MERGED "\"$HEAD_OID\"")" "UNKNOWN"
case_end

case_begin "A4 a forge that reported no head commit is taken at its word" "hooks/lib/forge/pr-state.js"
check "empty string" "$(slh "$REPO_M" MERGED '""')" "MERGED"
check "undefined" "$(slh "$REPO_M" MERGED undefined)" "MERGED"
check "null" "$(slh "$REPO_M" MERGED null)" "MERGED"
check "whitespace only" "$(slh "$REPO_M" MERGED '"  \n"')" "MERGED"
check "undefined + unreadable HEAD: HEAD is never consulted" "$(slh "$MISSING_M" MERGED undefined)" "MERGED"
case_end

case_begin "A5 every state other than MERGED passes through unchanged" "hooks/lib/forge/pr-state.js"
for st in OPEN NONE UNKNOWN CLOSED; do
  check "$st + mismatched head" "$(slh "$REPO_M" "$st" "\"$OTHER_OID\"")" "$st"
  check "$st + unreadable HEAD" "$(slh "$MISSING_M" "$st" "\"$OTHER_OID\"")" "$st"
done
case_end

FULL="42|CLEAN|https://github.com/example/repo/pull/42|"
case_begin "A6 mergeStateForLocalHead: an unchanged state returns the answer itself" "hooks/lib/forge/merge-state.js"
check "MERGED + matching head" "$(mslh "$REPO_M" MERGED "\"$HEAD_OID\"")" "MERGED|$FULL|same=true"
check "MERGED + no head reported" "$(mslh "$REPO_M" MERGED undefined)" "MERGED|$FULL|same=true"
check "OPEN + mismatched head" "$(mslh "$REPO_M" OPEN "\"$OTHER_OID\"")" "OPEN|$FULL|same=true"
check "CLOSED + mismatched head" "$(mslh "$REPO_M" CLOSED "\"$OTHER_OID\"")" "CLOSED|$FULL|same=true"
case_end

case_begin "A6 mergeStateForLocalHead: a demotion to NONE clears number, mergeState and url" "hooks/lib/forge/merge-state.js"
check "MERGED + unrelated head" "$(mslh "$REPO_M" MERGED "\"$OTHER_OID\"")" "NONE|||||same=false"
check "MERGED + earlier commit" "$(mslh "$REPO_M" MERGED "\"$FIRST\"")" "NONE|||||same=false"
case_end

case_begin "A6 mergeStateForLocalHead: an unreadable HEAD answers the unknownMergeState shape" "hooks/lib/forge/merge-state.js"
check "repoDir does not exist" "$(mslh "$MISSING_M" MERGED "\"$HEAD_OID\"")" "UNKNOWN||||local HEAD unreadable|same=false"
check "unborn HEAD" "$(mslh "$UNBORN_M" MERGED "\"$HEAD_OID\"")" "UNKNOWN||||local HEAD unreadable|same=false"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
