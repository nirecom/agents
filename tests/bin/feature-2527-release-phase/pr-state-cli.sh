#!/usr/bin/env bash
# pr-state-cli.sh — #2527: bin/workflow/pr-state answers PR_STATE / PR_NUMBER for /deliver.
# Tests: bin/workflow/pr-state, hooks/workflow-gate/gh-detect.js, hooks/lib/forge/github.js, hooks/lib/forge/gitlab.js, hooks/lib/forge/stub.js
# Tags: scope:issue-specific, workflow, release-phase, pr-state, forge, gh-stub, glab-stub
# TL2: spawns the real pr-state CLI against a fixture repo whose origin selects the forge
# (github.com -> gh, gitlab.com -> glab, any other host -> stub); gh / glab are node-copy stubs
# answered by fake-forge.js, so no network is reached.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a real gh / glab against a live PR or MR (auth, JSON field names
# of the installed CLI version); the stubs answer from fake-forge.js.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
rp_setup
trap rp_teardown EXIT
rp_fake_forge "$RP_TMP/forgebin" gh glab
PR_STATE_CLI="$RP_SCRIPT_CHECKOUT_ROOT/bin/workflow/pr-state"
GH_URL="https://github.com/example/repo.git"
GL_URL="https://gitlab.com/example/repo.git"

# prs <args...> — pr-state stdout plus RC=<exit>; stderr goes to $RP_TMP/prs.err.
prs() {
  local out rc
  out="$(run_with_timeout 60 node "$PR_STATE_CLI" "$@" 2>"$RP_TMP/prs.err")"
  rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}
use_origin() { git -C "$RP_REPO" remote set-url origin "$1"; }

# Rows: <name> | <origin> | <FAKE_FORGE_STATE> | <want PR_STATE> | <want PR_NUMBER>.
# Both forges read a non-zero exit as NONE only with the CLI's no-PR/MR stderr; any other
# failure (FAIL exit 2, FAIL1 exit 1 + other stderr) is UNKNOWN (fail-closed).
case_begin "pr-state: state and number per forge answer (table)" "bin/workflow/pr-state"
while IFS='|' read -r name origin st want_state want_num; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; origin="${origin//[[:space:]]/}"; st="${st//[[:space:]]/}"
  want_state="${want_state//[[:space:]]/}"; want_num="${want_num//[[:space:]]/}"
  if [ "$origin" = "gitlab" ]; then use_origin "$GL_URL"; else use_origin "$GH_URL"; fi
  out="$(FAKE_FORGE_STATE="$st" prs --repo "$RP_REPO_M")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: PR_STATE" "$(field "$out" PR_STATE)" "$want_state"
  check "$name: PR_NUMBER" "$(field "$out" PR_NUMBER)" "$want_num"
done <<'TABLE'
gh-open            | github | OPEN      | OPEN    | 42
gh-merged          | github | MERGED    | MERGED  | 42
gh-closed          | github | CLOSED    | CLOSED  | 42
gh-lowercase-open  | github | open      | OPEN    | 42
gh-none            | github | NONE      | NONE    |
gh-fail            | github | FAIL      | UNKNOWN |
gh-exit1-other     | github | FAIL1     | UNKNOWN |
gh-malformed-json  | github | MALFORMED | UNKNOWN |
gh-empty-output    | github | EMPTY     | UNKNOWN |
gh-unknown-state   | github | DRAFT     | UNKNOWN | 42
gl-open            | gitlab | OPEN      | OPEN    | 42
gl-merged          | gitlab | MERGED    | MERGED  | 42
gl-closed          | gitlab | CLOSED    | CLOSED  | 42
gl-locked          | gitlab | LOCKED    | CLOSED  | 42
gl-none            | gitlab | NONE      | NONE    |
gl-empty-output    | gitlab | EMPTY     | UNKNOWN |
gl-malformed       | gitlab | MALFORMED | UNKNOWN |
gl-unknown-state   | gitlab | weird     | UNKNOWN |
gl-fail            | gitlab | FAIL      | UNKNOWN |
gl-exit1-other     | gitlab | FAIL1     | UNKNOWN |
TABLE
case_end

# Forge modules called in-process: exit 1 is NONE only with the no-PR/MR stderr, for both
# prStateForBranch and prForBranch (gh / glab are the fake-forge node-copy stubs on PATH).
forge_call() {
  local js
  IFS= read -r -d '' js <<'JS'
const [mod, fn, repo] = process.argv.slice(1);
const M = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/lib/forge/" + mod + ".js");
const F = M[mod === "github" ? "codehostGithub" : "codehostGitlab"];
if (!F || typeof F[fn] !== "function") { console.log("NO_FN"); process.exit(0); }
const r = F[fn](repo);
console.log(typeof r === "string" ? r : r.state + "#" + r.number);
JS
  FAKE_FORGE_STATE="$4" run_with_timeout 60 node -e "$js" "$1" "$2" "$3" 2>&1
}
case_begin "forge modules: exit 1 + no-PR stderr -> NONE, exit 1 + other stderr -> UNKNOWN" "hooks/lib/forge/github.js"
use_origin "$GH_URL"
check "github prStateForBranch no-PR" "$(forge_call github prStateForBranch "$RP_REPO_M" NONE)" "NONE"
check "github prStateForBranch other exit 1" "$(forge_call github prStateForBranch "$RP_REPO_M" FAIL1)" "UNKNOWN"
check "github prForBranch no-PR" "$(forge_call github prForBranch "$RP_REPO_M" NONE)" "NONE#"
check "github prForBranch other exit 1" "$(forge_call github prForBranch "$RP_REPO_M" FAIL1)" "UNKNOWN#"
use_origin "$GL_URL"
check "gitlab prStateForBranch no-MR" "$(forge_call gitlab prStateForBranch "$RP_REPO_M" NONE)" "NONE"
check "gitlab prStateForBranch other exit 1" "$(forge_call gitlab prStateForBranch "$RP_REPO_M" FAIL1)" "UNKNOWN"
check "gitlab prForBranch no-MR" "$(forge_call gitlab prForBranch "$RP_REPO_M" NONE)" "NONE#"
check "gitlab prForBranch other exit 1" "$(forge_call gitlab prForBranch "$RP_REPO_M" FAIL1)" "UNKNOWN#"
case_end

case_begin "gitlab: exit 0 with empty stdout is UNKNOWN (fail-closed), never NONE" "hooks/lib/forge/gitlab.js"
use_origin "$GL_URL"
check "gitlab prStateForBranch exit 0 empty" "$(forge_call gitlab prStateForBranch "$RP_REPO_M" EMPTY)" "UNKNOWN"
check "gitlab prForBranch exit 0 empty" "$(forge_call gitlab prForBranch "$RP_REPO_M" EMPTY)" "UNKNOWN#"
: > "$RP_TMP/forge.log"
forge_call gitlab prForBranch "$RP_REPO_M" EMPTY >/dev/null
check "gitlab prForBranch exit 0 empty: no iid query" "$(grep -c 'iid' "$RP_TMP/forge.log")" "0"
case_end

case_begin "pr-state: github queries gh once in the --repo dir and passes the number through" "hooks/lib/forge/github.js"
use_origin "$GH_URL"
: > "$RP_TMP/forge.log"
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_NUMBER=2527 prs --repo "$RP_REPO_M")"
check "gh number 2527 passed through" "$(field "$out" PR_NUMBER)" "2527"
log="$(cat "$RP_TMP/forge.log")"
check_contains "gh ran pr view --json state,number" "$log" "gh pr view --json state,number"
check_contains "gh ran in the --repo dir" "$log" "$RP_REPO_M|gh"
check "exactly one gh call" "$(grep -c . "$RP_TMP/forge.log")" "1"
check_not_contains "pr-state never merges" "$log" "merge"
case_end

case_begin "pr-state: gitlab reads state then iid from glab in the --repo dir" "hooks/lib/forge/gitlab.js"
use_origin "$GL_URL"
: > "$RP_TMP/forge.log"
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_NUMBER=7 prs --repo "$RP_REPO_M")"
check "glab iid 7 passed through" "$(field "$out" PR_NUMBER)" "7"
log="$(cat "$RP_TMP/forge.log")"
check_contains "glab state query" "$log" "glab mr view --json state --jq .state"
check_contains "glab iid query" "$log" "glab mr view --json iid --jq .iid"
check_contains "glab ran in the --repo dir" "$log" "$RP_REPO_M|glab"
: > "$RP_TMP/forge.log"
out="$(FAKE_FORGE_STATE=NONE prs --repo "$RP_REPO_M")"
check "glab NONE: no iid query" "$(grep -c 'iid' "$RP_TMP/forge.log")" "0"
case_end

case_begin "pr-state: missing forge CLI answers UNKNOWN for both forges" "hooks/lib/forge/github.js"
use_origin "$GH_URL"
out="$(PATH="$RP_FORGE_PATH_BARE" FAKE_FORGE_STATE=OPEN prs --repo "$RP_REPO_M")"
check "no gh: exit 0" "$(field "$out" RC)" "0"
check "no gh: UNKNOWN" "$(field "$out" PR_STATE)" "UNKNOWN"
check "no gh: empty number" "$(field "$out" PR_NUMBER)" ""
use_origin "$GL_URL"
out="$(PATH="$RP_FORGE_PATH_BARE" FAKE_FORGE_STATE=OPEN prs --repo "$RP_REPO_M")"
check "no glab: exit 0" "$(field "$out" RC)" "0"
check "no glab: UNKNOWN" "$(field "$out" PR_STATE)" "UNKNOWN"
case_end

case_begin "pr-state: unknown host or no origin resolves the stub (UNKNOWN, no forge call)" "hooks/lib/forge/stub.js"
use_origin "https://example.com/acme/widgets.git"
: > "$RP_TMP/forge.log"
out="$(FAKE_FORGE_STATE=OPEN prs --repo "$RP_REPO_M")"
check "unknown host: UNKNOWN" "$(field "$out" PR_STATE)" "UNKNOWN"
check "unknown host: empty number" "$(field "$out" PR_NUMBER)" ""
check "unknown host: no forge CLI called" "$(grep -c . "$RP_TMP/forge.log")" "0"
git -C "$RP_REPO" remote remove origin
out="$(FAKE_FORGE_STATE=OPEN prs --repo "$RP_REPO_M")"
check "no origin: exit 0" "$(field "$out" RC)" "0"
check "no origin: UNKNOWN" "$(field "$out" PR_STATE)" "UNKNOWN"
git -C "$RP_REPO" remote add origin "$GH_URL"
out="$(FAKE_FORGE_STATE=OPEN prs --repo "$RP_TMP/does-not-exist")"
check "nonexistent --repo: exit 0" "$(field "$out" RC)" "0"
check "nonexistent --repo: UNKNOWN" "$(field "$out" PR_STATE)" "UNKNOWN"
case_end

case_begin "pr-state: --repo defaults to cwd and accepts an MSYS-form path" "bin/workflow/pr-state"
use_origin "$GH_URL"
out="$(cd "$RP_REPO" && FAKE_FORGE_STATE=MERGED prs)"
check "cwd default: MERGED" "$(field "$out" PR_STATE)" "MERGED"
out="$(FAKE_FORGE_STATE=CLOSED prs --repo "$RP_REPO")"
check "posix-form --repo: CLOSED" "$(field "$out" PR_STATE)" "CLOSED"
case_end

case_begin "pr-state: missing and invalid arguments exit 1 without a PR_STATE line" "bin/workflow/pr-state"
out="$(FAKE_FORGE_STATE=OPEN prs --repo)"
check "--repo without value: exit 1" "$(field "$out" RC)" "1"
check_not_contains "--repo without value: no PR_STATE" "$out" "PR_STATE="
check_contains "--repo without value: diagnostic" "$(cat "$RP_TMP/prs.err")" "--repo requires an argument"
out="$(FAKE_FORGE_STATE=OPEN prs --bogus)"
check "unknown flag: exit 1" "$(field "$out" RC)" "1"
check_not_contains "unknown flag: no PR_STATE" "$out" "PR_STATE="
check_contains "unknown flag: diagnostic" "$(cat "$RP_TMP/prs.err")" "unknown argument: --bogus"
out="$(FAKE_FORGE_STATE=OPEN prs --repo "$RP_REPO_M" extra)"
check "stray positional: exit 1" "$(field "$out" RC)" "1"
check_contains "stray positional: diagnostic" "$(cat "$RP_TMP/prs.err")" "unknown argument: extra"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
