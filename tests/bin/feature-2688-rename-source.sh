#!/usr/bin/env bash
# tests/bin/feature-2688-rename-source.sh
# Tests: bin/lib/run-tests-baseline-rename.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, rename, missing-at-base, scope:issue-specific, pwsh-not-required, TL2
#
# #2688 T3 - rename source. When a test renamed on the branch is absent at base, find the old path
# via git rename detection and run the old path on the base side (detail gets -via-rename:<old>). A plain addition
# (not a rename), or a rename whose source is absent at base, stays missing-at-base (pending).
# TL3 gap: renames right at the similarity threshold are left to git's default (50%) and not covered here.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

BASELINE_CLI="$SCRIPT_CHECKOUT_ROOT/bin/run-tests-baseline"
RENAME_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-rename.sh"

TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
export WORKFLOW_STATE_DIR="$(np "$TMPROOT/iso/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$TMPROOT/iso/plans")"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$TMPROOT/transcripts" "$TMPROOT/home" "$TMPROOT/cwd"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
HOME="$(np "$TMPROOT/home")"
export HOME USERPROFILE="$HOME"
export RUN_ALL_CACHE_DIR="$TMPROOT/cache-default"
mkdir -p "$RUN_ALL_CACHE_DIR"
export DEFAULT_BRANCHES=main
unset RTB_BUDGET_TOTAL
AGENTS_WIN="$(np "$SCRIPT_CHECKOUT_ROOT")"

SEED_JS="$TMPROOT/seed.js"
cat > "$SEED_JS" <<'JSCODE'
"use strict";
// argv: agents sid path - pending + fail + failing_tests [path] + exit 1.
const [agents, sid, p] = process.argv.slice(2);
const a = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });
try {
  require(agents + "/hooks/workflow-state/state-io/events").appendEvents(sid, [
    { kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" },
    a("run_outcome", "fail"), a("failing_tests", [p]), a("unrunnable_count", 0), a("failing_test_exits", { [p]: 1 })]);
} catch (e) { process.stderr.write("seed-error: " + e.message + "\n"); process.exit(1); }
JSCODE

READ_JS="$TMPROOT/read.js"
cat > "$READ_JS" <<'JSCODE'
"use strict";
try {
  const s = require(process.argv[2] + "/hooks/workflow-state").readState(process.argv[3]);
  const v = s && s.steps && s.steps.run_tests ? s.steps.run_tests[process.argv[4]] : undefined;
  process.stdout.write(v === undefined || v === null ? "(absent)" : (typeof v === "string" ? v : JSON.stringify(v)));
} catch (err) { process.stdout.write("(absent)"); }
JSCODE

ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }
field() { run_with_timeout 20 node "$(np "$READ_JS")" "$AGENTS_WIN" "$1" "$2" 2>/dev/null || echo "(absent)"; }
has_line() { case "$RTB_OUT" in *"$2"*) pass "$1" ;; *) fail "$1" "missing [$2] in: $RTB_OUT" ;; esac; }
lacks_line() { case "$RTB_OUT" in *"$2"*) fail "$1" "unexpected [$2] in: $RTB_OUT" ;; *) pass "$1" ;; esac; }
present() { [ -e "$2" ] && pass "$1" || fail "$1" "absent: $2"; }

# body <marker> - a test that creates the marker and exits 1, with many shared lines so rename detection kicks in.
body() {
  printf '#!/usr/bin/env bash\n# fixture test for #2688 rename detection\n# line a\n# line b\n# line c\n# line d\n'
  printf 'touch "%s"\nexit 1\n' "$1"
}

repo_init() {
  harness_git_init "$1"
  git -C "$1" config core.hooksPath /dev/null
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name T
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.autocrlf false
  git -C "$1" symbolic-ref HEAD refs/heads/main
  mkdir -p "$1/tests/bin" "$1.marks"
  printf 'keep\n' > "$1/tests/bin/README"
}
commit_all() { git -C "$1" add -A; git -C "$1" commit -q -m "$2"; }

rtb() {
  RTB_RC=0
  RTB_OUT="$(cd "$TMPROOT/cwd" && env RUN_ALL_CACHE_DIR="$(np "$1.cache")" bash "$RWT" 120 \
    bash "$BASELINE_CLI" --session "$2" --worktree "$(np "$1")" --per-test-timeout 10 2>&1)" || RTB_RC=$?
}

case_begin "rename-lib-present" "bin/lib/run-tests-baseline-rename.sh"
[ -f "$RENAME_LIB" ] && pass "run-tests-baseline-rename.sh exists" \
  || fail "run-tests-baseline-rename.sh exists" "missing (not implemented yet)"
case_end

case_begin "renamed-test-runs-its-old-path-at-base" "bin/lib/run-tests-baseline-rename.sh"
R="$TMPROOT/ren"; repo_init "$R"; mkdir -p "$R.cache"
body "$(np "$R.marks")/old-at-base" > "$R/tests/bin/old-t.sh"; chmod +x "$R/tests/bin/old-t.sh"
commit_all "$R" base
git -C "$R" checkout -q -b feature
git -C "$R" mv tests/bin/old-t.sh tests/bin/new-t.sh
body "$(np "$R.marks")/new-on-branch" > "$R/tests/bin/new-t.sh"
commit_all "$R" rename
S="rn-ren-$$"
run_with_timeout 30 node "$(np "$SEED_JS")" "$AGENTS_WIN" "$S" tests/bin/new-t.sh >/dev/null 2>&1 || fail "fixture: seed $S"
rtb "$R" "$S"
ck "rename: exit 0 (preexisting via the old path)" 0 "$RTB_RC"
present "rename: the old path ran at base" "$R.marks/old-at-base"
has_line "rename: preexisting line for the new path" "BASELINE: preexisting tests/bin/new-t.sh"
has_line "rename: detail names the old path" "-via-rename:tests/bin/old-t.sh"
ck "rename: completion_basis" "baseline-preexisting" "$(field "$S" completion_basis)"
case_end

case_begin "added-test-without-rename-stays-pending" "bin/lib/run-tests-baseline-rename.sh"
R="$TMPROOT/add"; repo_init "$R"; mkdir -p "$R.cache"
commit_all "$R" base
git -C "$R" checkout -q -b feature
body "$(np "$R.marks")/added" > "$R/tests/bin/added.sh"; chmod +x "$R/tests/bin/added.sh"
commit_all "$R" add
S="rn-add-$$"
run_with_timeout 30 node "$(np "$SEED_JS")" "$AGENTS_WIN" "$S" tests/bin/added.sh >/dev/null 2>&1 || fail "fixture: seed $S"
rtb "$R" "$S"
ck "add: exit 1 (pending)" 1 "$RTB_RC"
has_line "add: missing-at-base line" "missing-at-base"
lacks_line "add: no rename detail" "-via-rename:"
ck "add: run_tests stays pending" "pending" "$(field "$S" status)"
case_end

case_begin "rename-source-absent-at-base-stays-pending" "bin/lib/run-tests-baseline-rename.sh"
R="$TMPROOT/mid"; repo_init "$R"; mkdir -p "$R.cache"
commit_all "$R" base
git -C "$R" checkout -q -b feature
body "$(np "$R.marks")/mid" > "$R/tests/bin/mid.sh"; chmod +x "$R/tests/bin/mid.sh"
commit_all "$R" add-mid
git -C "$R" mv tests/bin/mid.sh tests/bin/final.sh
commit_all "$R" rename-mid
S="rn-mid-$$"
run_with_timeout 30 node "$(np "$SEED_JS")" "$AGENTS_WIN" "$S" tests/bin/final.sh >/dev/null 2>&1 || fail "fixture: seed $S"
rtb "$R" "$S"
ck "mid: exit 1 (pending)" 1 "$RTB_RC"
has_line "mid: missing-at-base line" "missing-at-base"
lacks_line "mid: no rename detail" "-via-rename:"
ck "mid: run_tests stays pending" "pending" "$(field "$S" status)"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
