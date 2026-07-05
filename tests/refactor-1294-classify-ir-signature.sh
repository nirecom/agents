#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/patterns.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/universal-target-allow.js, hooks/enforce-worktree.js, hooks/lib/bash-write-patterns/segment-utils.js
# Tags: worktree, classify, ir, gh-write, pwsh-alias, canary-3, canary-3-followup, scope:issue-specific
#
# L2 broad integration test for issue #1294 (canary-3):
#   - isGhWriteIR(ir) predicate in patterns.js
#   - mi/ci alias support in patterns.js and collectBashWriteTargets
#   - classify(ir|string) shim in classify.js
#   - isEverySegmentExcluded IR traversal in bash-write-scope.js
#
# L2 subprocess coverage (this file):
#   - enforce-worktree.js dispatch: invoked as subprocess with test payloads
#     to verify it does not crash and returns valid JSON decisions.
#     Full allow/block semantics not checked here (depends on live session state).
#
# L3 gap (what this test does NOT catch):
#   - Real hook registration and firing in a live claude -p session
#     (enforce-worktree.js wired to PreToolUse with actual tool input routing)
#   - Allow-chain end-to-end: standard.js → bash-write-scope.js → session-scope
#     check → decision with real WIP/worktree state
#   - The enforce-worktree.js subprocess section below only checks valid-JSON + no-crash.
#     Full allow/block semantics depend on live session state (real WIP/scope roots).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
#   bin/check-verification-gate.sh category: hook-registration
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# JS bridges — each shells out to node once. Command string is passed as
# process.argv[1] so shell quoting of the node -e source stays clean.
# ---------------------------------------------------------------------------

is_gh_write_ir() {
  ( cd "$REPO" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {isGhWriteIR} = require("./hooks/lib/bash-write-patterns/patterns");
    if (typeof isGhWriteIR !== "function") { process.stdout.write("MISSING"); process.exit(0); }
    process.stdout.write(String(isGhWriteIR(parse(process.argv[1]))));
  ' "$1" ) 2>/dev/null
}

is_gh_write_ir_raw() {
  # Accepts a pre-serialized IR JSON string (argv[1]) to test the predicate
  # against a synthetic IR where rawText="" — proves ir.segments drive result.
  ( cd "$REPO" && node -e '
    const {isGhWriteIR} = require("./hooks/lib/bash-write-patterns/patterns");
    if (typeof isGhWriteIR !== "function") { process.stdout.write("MISSING"); process.exit(0); }
    const ir = JSON.parse(process.argv[1]);
    process.stdout.write(String(isGhWriteIR(ir)));
  ' "$1" ) 2>/dev/null
}

classify_ir() {
  ( cd "$REPO" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {classify} = require("./hooks/lib/bash-write-patterns/classify");
    process.stdout.write(classify(parse(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

classify_str() {
  ( cd "$REPO" && node -e '
    const {classify} = require("./hooks/lib/bash-write-patterns/classify");
    process.stdout.write(classify(process.argv[1]));
  ' "$1" ) 2>/dev/null
}

collect_write_targets_ir() {
  # Returns "HAS_TARGETS" when IR-based collectBashWriteTargets returns non-null targets.
  ( cd "$REPO" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {collectBashWriteTargets} = require("./hooks/enforce-worktree/bash-write-scope");
    const ir = parse(process.argv[1]);
    const result = collectBashWriteTargets(ir);
    const hasTargets = result && Array.isArray(result.targets) && result.targets !== null && result.targets.length > 0;
    process.stdout.write(hasTargets ? "HAS_TARGETS" : "NO_TARGETS");
  ' "$1" ) 2>/dev/null
}

collect_write_targets_str() {
  # Same but with raw string — tests backward compat.
  ( cd "$REPO" && node -e '
    const {collectBashWriteTargets} = require("./hooks/enforce-worktree/bash-write-scope");
    const result = collectBashWriteTargets(process.argv[1]);
    const hasTargets = result && Array.isArray(result.targets) && result.targets !== null && result.targets.length > 0;
    process.stdout.write(hasTargets ? "HAS_TARGETS" : "NO_TARGETS");
  ' "$1" ) 2>/dev/null
}

get_targets_ir() {
  # Returns comma-separated actual target paths from IR-based collectBashWriteTargets.
  # Used to verify specific path values (not just HAS_TARGETS/NO_TARGETS).
  ( cd "$REPO" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {collectBashWriteTargets} = require("./hooks/enforce-worktree/bash-write-scope");
    const ir = parse(process.argv[1]);
    const result = collectBashWriteTargets(ir);
    if (result && Array.isArray(result.targets) && result.targets.length > 0) {
      process.stdout.write(result.targets.join(","));
    } else {
      process.stdout.write("NONE");
    }
  ' "$1" ) 2>/dev/null
}

check_universal_allow() {
  # argv[1]=toolName argv[2]=cmd argv[3]=scopeRoot argv[4]=repoRoot argv[5]="ir"|""
  # Calls checkUniversalTargetAllow; when argv[5]="ir" passes parsed IR as 5th arg.
  ( cd "$REPO" && node -e '
    const {checkUniversalTargetAllow} = require("./hooks/enforce-worktree/universal-target-allow");
    const toolName = process.argv[1];
    const cmd = process.argv[2];
    const scopeRoot = process.argv[3];
    const repoRoot = process.argv[4] || null;
    const useIR = process.argv[5] === "ir";
    const toolInput = {command: cmd};
    const sessionRoots = scopeRoot ? new Set([scopeRoot]) : new Set();
    const callArgs = [toolName, toolInput, sessionRoots, repoRoot];
    if (useIR) {
      const {parse} = require("./hooks/lib/command-ir");
      callArgs.push(parse(cmd));
    }
    const result = checkUniversalTargetAllow(...callArgs);
    process.stdout.write(result.verdict);
  ' "$1" "$2" "$3" "$4" "${5:-}" ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# Section C5 — isGhWriteIR direct regression
# ---------------------------------------------------------------------------
echo "=== Section C5: isGhWriteIR(ir) — gh write predicates ==="

# Table-driven: 8 gh write (true) + 1 env-prefix (true) + 4 negative (false).
# canonical while IFS='|' read -r pattern from skills/_shared/test-design.md.
while IFS='|' read -r name cmd want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  got="$(is_gh_write_ir "$cmd")"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# name|cmd|want
C5.1_gh_pr_merge|gh pr merge origin/main|true
C5.2_gh_issue_delete|gh issue delete 123|true
C5.3_gh_repo_delete|gh repo delete myrepo|true
C5.4_gh_release_create|gh release create v1.0|true
C5.5_gh_api_X_DELETE|gh api -X DELETE /repos/o/r/issues/1|true
C5.6_gh_issue_create|gh issue create -t test -b body|true
C5.7_gh_api_PUT_contents|gh api PUT repos/o/r/contents/file.txt|true
C5.8_gh_api_POST_git_blobs|gh api POST repos/o/r/git/blobs|true
C5.8b_gh_api_PATCH_refs|gh api PATCH repos/o/r/git/refs/heads/main|true
C5.9_env_prefix_gh_pr_merge|env MSYS_NO_PATHCONV=1 gh pr merge origin/main|true
C5.9b_env_editor_gh_not_gh|env EDITOR=gh vim|false
C5.10_gh_pr_create|gh pr create|false
C5.11_gh_issue_comment|gh issue comment 1 -b msg|false
C5.12_gh_pr_list|gh pr list|false
C5.13_echo_not_gh|echo hello|false
TABLE

# WRITE_PATTERNS independence: minimal IR with rawText="" must still return true
# (proves ir.segments/argv drive the result, not rawText regex)
assert_eq "C5.14 IR independence (rawText='')" "true" "$(is_gh_write_ir_raw '{
  "segments":[{"cmd0":"gh","argv":["pr","merge","origin/main"],"redirects":[],"kind":"simple","rawText":"gh pr merge origin/main"}],
  "cmd0":"gh","argv":["pr","merge","origin/main"],"redirects":[],"kind":"simple",
  "rawText":"","separators":[],"parseFailure":false
}')"

# ---------------------------------------------------------------------------
# Section C5 — pwsh aliases: collectBashWriteTargets IR traversal
# ---------------------------------------------------------------------------
echo ""
echo "=== Section C5: pwsh aliases — collectBashWriteTargets(ir) ==="

# Each pwsh alias must produce non-null targets from the IR-based extractor.
# Tests both IR path (post-#1294) and string path (backward compat).
assert_eq "C5.15 sc alias targets (ir)"     "HAS_TARGETS" "$(collect_write_targets_ir "sc out.txt 'x'")"
assert_eq "C5.16 ac alias targets (ir)"     "HAS_TARGETS" "$(collect_write_targets_ir "ac append.txt 'x'")"
assert_eq "C5.17 ni alias targets (ir)"     "HAS_TARGETS" "$(collect_write_targets_ir 'ni newfile.txt')"
assert_eq "C5.18 ri alias targets (ir)"     "HAS_TARGETS" "$(collect_write_targets_ir 'ri oldfile.txt')"
assert_eq "C5.19 mi alias targets (ir)"     "HAS_TARGETS" "$(collect_write_targets_ir 'mi src.txt dst.txt')"
assert_eq "C5.20 ci alias targets (ir)"     "HAS_TARGETS" "$(collect_write_targets_ir 'ci src.txt dst.txt')"

# Full PowerShell cmdlet forms (backward compat — string path)
assert_eq "C5.21 Set-Content targets (str)"   "HAS_TARGETS" "$(collect_write_targets_str "Set-Content out.txt 'x'")"
assert_eq "C5.22 Remove-Item targets (str)"   "HAS_TARGETS" "$(collect_write_targets_str 'Remove-Item oldfile.txt')"

# Positive-Allow (#1065) regression: cp must produce targets (non-empty result)
assert_eq "C5.23 cp targets (str, #1065)"     "HAS_TARGETS" "$(collect_write_targets_str 'cp src dst')"

# Target path precision: mi src.txt dst.txt must list dst.txt as the write target,
# not src.txt. Fails pre-#1294 (mi not yet in patterns).
assert_eq "C5.24 mi → dst.txt is write target (ir)" "dst.txt" "$(get_targets_ir 'mi src.txt dst.txt')"

# ci alias: same precision check as C5.24 — destination must be the write target.
assert_eq "C5.24b ci → dst.txt is write target (ir)" "dst.txt" "$(get_targets_ir 'ci src.txt dst.txt')"

# Fail-closed: malformed/unterminated cmd → parseFailure IR → must return NO_TARGETS.
# Malformed input must never produce spurious write targets that bypass the hook.
assert_eq "C5.25 parseFailure → NO_TARGETS (ir)" "NO_TARGETS" "$(collect_write_targets_ir 'echo "unterminated')"

# ---------------------------------------------------------------------------
# Section — checkUniversalTargetAllow IR param (backward-compat parity)
# universal-target-allow.js is listed in # Tests: frontmatter. Verify:
#   1. Non-Bash tool → abstain (basic gate independent of IR)
#   2. Empty sessionRoots → abstain (scope gate independent of IR)
#   3. str call and IR call produce the same verdict (backward-compat parity)
# ---------------------------------------------------------------------------
echo ""
echo "=== Section: checkUniversalTargetAllow IR parity ==="

# Non-Bash tool must always abstain regardless of IR.
assert_eq "UnivAllow non-Bash → abstain" "abstain" "$(check_universal_allow 'Edit' 'cp x y' '/tmp/scope' '/tmp/scope')"

# Empty sessionRoots must abstain (scope not configured).
assert_eq "UnivAllow empty scope → abstain" "abstain" "$(check_universal_allow 'Bash' 'echo hello' '' '')"

# IR/str parity on read command (abstain both paths).
_ua_str="$(check_universal_allow 'Bash' 'echo hello' '/tmp/scope' '/tmp/scope')"
_ua_ir="$(check_universal_allow 'Bash' 'echo hello' '/tmp/scope' '/tmp/scope' 'ir')"
assert_eq "UnivAllow IR==str parity (echo)" "$_ua_str" "$_ua_ir"

# Non-abstain parity: cp with target OUTSIDE scope → "allow" on both paths.
# Uses cp which already produces targets (C5.23). /outside/dst.txt ∉ /tmp/scope → allow.
_ua_str_allow="$(check_universal_allow 'Bash' 'cp src.txt /outside/dst.txt' '/tmp/scope' '/tmp/scope')"
_ua_ir_allow="$(check_universal_allow 'Bash' 'cp src.txt /outside/dst.txt' '/tmp/scope' '/tmp/scope' 'ir')"
assert_eq "UnivAllow cp outside scope → allow (str)" "allow" "$_ua_str_allow"
assert_eq "UnivAllow IR==str parity (cp outside scope)" "$_ua_str_allow" "$_ua_ir_allow"

# ---------------------------------------------------------------------------
# Section — classify(ir|string) IR shim
# ---------------------------------------------------------------------------
echo ""
echo "=== Section: classify(ir|string) shim ==="

assert_eq "classify IR echo read"        "read"  "$(classify_ir 'echo hello')"
assert_eq "classify IR rm write"         "write" "$(classify_ir 'rm -rf /tmp/x')"
# parseFailure → write (fail-closed contract)
assert_eq "classify IR parseFailure"     "write" "$(classify_ir 'echo \"unterminated')"
# String path still works (backward compat)
assert_eq "classify str echo read"       "read"  "$(classify_str 'echo hello')"
assert_eq "classify str rm write"        "write" "$(classify_str 'rm -rf /tmp/x')"

# mi and ci aliases must be "write" post-#1294 (currently "read" — expected failure until implemented)
assert_eq "classify IR mi write"         "write" "$(classify_ir 'mi src.txt dst.txt')"
assert_eq "classify IR ci write"         "write" "$(classify_ir 'ci src.txt dst.txt')"

# ---------------------------------------------------------------------------
# Section — isEverySegmentExcluded IR traversal
# ---------------------------------------------------------------------------
echo ""
echo "=== Section: isEverySegmentExcluded IR traversal ==="

every_seg_excluded() {
  # argv[1]=cmd argv[2]=patterns_json (e.g. '["*.txt"]')
  ( cd "$REPO" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {isEverySegmentExcluded} = require("./hooks/enforce-worktree/bash-write-scope");
    const cmd = process.argv[1];
    const patterns = JSON.parse(process.argv[2]);
    // Post-#1294: accepts ir or string. Test with IR object.
    const ir = parse(cmd);
    process.stdout.write(String(isEverySegmentExcluded(ir, null, patterns)));
  ' "$1" "$2" ) 2>/dev/null
}

every_seg_excluded_str() {
  ( cd "$REPO" && node -e '
    const {isEverySegmentExcluded} = require("./hooks/enforce-worktree/bash-write-scope");
    const cmd = process.argv[1];
    const patterns = JSON.parse(process.argv[2]);
    process.stdout.write(String(isEverySegmentExcluded(cmd, null, patterns)));
  ' "$1" "$2" ) 2>/dev/null
}

# All segments match → true
assert_eq "EverySegExcl all match (ir)"   "true"  "$(every_seg_excluded 'echo x > /tmp/test.txt && rm /tmp/other.txt' '["*.txt"]')"
# One segment does NOT match → false
assert_eq "EverySegExcl one non-match (ir)" "false" "$(every_seg_excluded 'echo x > /tmp/test.txt && rm /tmp/other.sh' '["*.txt"]')"
# Backward compat: string path still works
assert_eq "EverySegExcl all match (str)"  "true"  "$(every_seg_excluded_str 'echo x > /tmp/test.txt && rm /tmp/other.txt' '["*.txt"]')"
assert_eq "EverySegExcl one non-match (str)" "false" "$(every_seg_excluded_str 'echo x > /tmp/test.txt && rm /tmp/other.sh' '["*.txt"]')"
# Zero segments (parse("") → empty IR): fail-closed → false. Fails pre-#1294.
assert_eq "EverySegExcl empty segments (ir)" "false" "$(every_seg_excluded '' '["*.txt"]')"

# ---------------------------------------------------------------------------
# Section — classify(ir) vs classify(str) behavioral parity
# IR migration must not change the classification verdict for any input.
# Parity is verified without asserting what the verdict IS — only that ir=str.
# ---------------------------------------------------------------------------
echo ""
echo "=== Section: classify(ir) / classify(str) parity (IR migration regression) ==="

classify_parity() {
  local name="$1" cmd="$2"
  local ir_result str_result
  ir_result="$(classify_ir "$cmd")"
  str_result="$(classify_str "$cmd")"
  assert_eq "$name (ir==str)" "$str_result" "$ir_result"
}

classify_parity "parity echo read"           "echo hello"
classify_parity "parity rm write"            "rm -rf /tmp/x"
classify_parity "parity env-prefix gh"       "env MSYS_NO_PATHCONV=1 gh pr merge origin/main"
classify_parity "parity cmd-subst echo-gh"  'echo "$(gh pr merge)"'
classify_parity "parity bash interp"         "bash -c 'rm /tmp/x'"
classify_parity "parity pipeline rm"         "ls | rm /tmp/x"

# isGhWriteIR fail-closed: parseFailure IR must return false (classify handles it as "write")
assert_eq "isGhWriteIR parseFailure → false" "false" "$(is_gh_write_ir_raw '{
  "segments":[],"cmd0":"","argv":[],"redirects":[],
  "kind":"simple","rawText":"echo \"unterminated","separators":[],"parseFailure":true
}')"

# ---------------------------------------------------------------------------
# Section — enforce-worktree.js subprocess dispatch (L2)
# Invokes the hook as a subprocess with test payloads.
# Verifies: no crash + valid JSON decision returned.
# Full allow/block semantics not asserted — depends on live session state.
# ---------------------------------------------------------------------------
echo ""
echo "=== Section: enforce-worktree.js subprocess dispatch (no-crash L2) ==="

hook_no_crash() {
  # Returns exit code 0 if hook outputs valid JSON (no crash), 1 otherwise.
  # Protocol: {} = approve (no decision field), {"decision":"block",...} = block.
  local output
  output="$( ( cd "$REPO" && node hooks/enforce-worktree.js <<< "$1" 2>/dev/null ) )"
  echo "$output" | node -e 'let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{try{JSON.parse(d); process.exit(0);}catch(e){process.exit(1);}})' 2>/dev/null
}

for tc_name in "gh pr merge" "echo hello" "mi src.txt dst.txt"; do
  payload="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$tc_name\"},\"session_id\":\"test-1294\"}"
  assert_eq "dispatch_no_crash_$(echo "$tc_name" | tr ' ' '_')" "valid_json" \
    "$(hook_no_crash "$payload" && echo valid_json || echo crashed_or_invalid)"
done

# ---------------------------------------------------------------------------
# Section C6 — sourced from sibling file (file-split rule: HARD >500 lines)
# ---------------------------------------------------------------------------
# shellcheck source=./refactor-1294-classify-ir-signature/c6-resolve-effective-command.sh
. "$(dirname "$0")/refactor-1294-classify-ir-signature/c6-resolve-effective-command.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================================="
echo "TOTAL: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
