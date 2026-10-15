#!/usr/bin/env bash
# Tests: hooks/workflow-mark/branching-handler.js, hooks/workflow-mark/branching-reconcile.js, hooks/workflow-state/resolve-worktree-path.js
# Tags: scope:issue-specific, issue-2527, workflow-mark, branching-handler, delivery-path, delivery-reconcile, worktree, TL2
# TL2 (#2527 plan 3-13, judgments A / D): BRANCHING_COMPLETE through the real workflow-mark.js
# against real repos A / A-wt / A-wt2 / B / B-wt; a rejection leaves the state byte-identical
# even with a stale session_worktree recorded (only the sentinel's `worktree:` is reconciled).
# TL3 gap: a real Claude Code session emitting the sentinel from a linked worktree (its own
# cwd / CLAUDE_PROJECT_DIR wiring) is not exercised, only the hook process with an explicit
# input.cwd; the automatic post-push reset keeping the profile is not driven by a real push.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/feature-2527-step-table/_lib.sh"

s27_setup
trap 'cd /; git -C "$RC_A" worktree prune >/dev/null 2>&1; s27_teardown' EXIT
export ENFORCE_WORKTREE=on ENFORCE_WORKTREE_EXCLUDE=""

MARK_JS="$S27_SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"

# --- fixture repos: A (+ A-wt, A-wt2), B (+ B-wt), and a plain non-git directory ----------
rc_repo() { # <dir>
  harness_git_init "$1"
  git -C "$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed
}
rc_wt() { # <repo> <wt-dir> <branch>
  git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1
  git -C "$2" config core.hooksPath /dev/null
}
RC_A="$S27_TMP/A"; RC_B="$S27_TMP/B"
rc_repo "$RC_A"; rc_repo "$RC_B"
rc_wt "$RC_A" "$S27_TMP/A-wt" feature/rc-a
rc_wt "$RC_A" "$S27_TMP/A-wt2" feature/rc-a2
rc_wt "$RC_B" "$S27_TMP/B-wt" feature/rc-b
mkdir -p "$S27_TMP/nogit"
A="$(np "$RC_A")"; B="$(np "$RC_B")"
AWT="$(np "$S27_TMP/A-wt")"; AWT2="$(np "$S27_TMP/A-wt2")"; BWT="$(np "$S27_TMP/B-wt")"
NOGIT="$(np "$S27_TMP/nogit")"; MISSING="$(np "$S27_TMP/no-such-dir")"

PRE="workflow_init=complete;clarify_intent=complete;research=complete;outline=skipped;detail=skipped;branching_complete=pending"

# new_state <sid> [<stale session_worktree>]
new_state() {
  if [ -n "${2:-}" ]; then
    mk_state "{\"sid\":\"$1\",\"steps\":\"$PRE\",\"extra\":{\"session_worktree\":\"$2\"}}"
  else
    mk_state "{\"sid\":\"$1\",\"steps\":\"$PRE\"}"
  fi
}

# sentinel <sid> <repo-cwd> <command> — workflow-mark.js fed a successful Bash payload; the repo
# cwd is both input.cwd and CLAUDE_PROJECT_DIR, so resolveRepoCwd has one answer.
sentinel() {
  node -e 'process.stdout.write(JSON.stringify({ tool_name: "Bash", session_id: process.argv[1], cwd: process.argv[2],
    tool_input: { command: process.argv[3], description: "test" },
    tool_response: { exit_code: 0 } }))' "$1" "$2" "$3" \
    | CLAUDE_PROJECT_DIR="$2" run_with_timeout 60 node "$MARK_JS" 2>&1
}
bc() { sentinel "$1" "$2" "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $3>>\""; } # <sid> <repo-cwd> <decision>

# snap <sid> — BC=<branching_complete status>; DP/DPO/AMP/WT = raw top-level value, "-" when unset.
read -r -d '' SNAP_JS <<'JS' || true
const fs = require("fs");
const sid = process.env.RC_SID;
let raw; try { raw = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + sid + ".json", "utf8")); } catch (e) { out("BC", "<unreadable>"); process.exit(0); }
const core = req("hooks/workflow-state/state-io/core.js");
const st = core.readState(sid);
const bc = st && st.steps && st.steps.branching_complete;
const g = (k) => (raw[k] == null ? "-" : String(raw[k]));
out("BC", bc && bc.status ? bc.status : "<none>");
out("DP", g("delivery_path"));
out("DPO", g("delivery_path_origin"));
out("AMP", g("auto_merge_pr"));
out("WT", g("session_worktree"));
JS
snap() { RC_SID="$1" s27_node "$SNAP_JS"; }
statefile() { printf '%s/%s.json' "$WORKFLOW_STATE_DIR" "$1"; }

# reject_row <name> <sid> <repo-cwd> <decision> <reason-code> [<extra needle>]
# A stale A-wt2 is recorded first; the rejection must leave the state file byte-identical.
reject_row() {
  local name="$1" sid="$2" out
  new_state "$sid" "$AWT2"
  cp "$(statefile "$sid")" "$S27_TMP/$sid.before"
  out="$(bc "$sid" "$3" "$4")"
  check_contains "$name: rejection names $5" "$out" "$5"
  check_contains "$name: rejection gives the re-run sentinel" "$out" "WORKFLOW_BRANCHING_COMPLETE"
  [ -n "${6:-}" ] && check_contains "$name: rejection says [$6]" "$out" "$6"
  if cmp -s "$S27_TMP/$sid.before" "$(statefile "$sid")"; then
    pass "$name: state file byte-identical after the rejection"
  else
    fail "$name: state file changed on a rejection" "$(snap "$sid" | tr '\n' ' ')"
  fi
  RC_LAST_OUT="$out"
}

# ============================================================================================
case_begin "pass-pr-linked-worktree" "hooks/workflow-mark/branching-handler.js"
new_state rc-ok-pr
bc rc-ok-pr "$A" "branch: feature/rc-a worktree: $AWT" >/dev/null
o="$(snap rc-ok-pr)"
check "pr + A-wt: branching_complete complete" "$(field "$o" BC)" "complete"
check "pr + A-wt: delivery_path pull_request" "$(field "$o" DP)" "pull_request"
check "pr + A-wt: session_worktree is the declared A-wt" "$(field "$o" WT)" "$AWT"
case_end

case_begin "pass-pr-linked-worktree-over-stale-other-repo-record" "hooks/workflow-mark/branching-handler.js"
new_state rc-ok-stale "$BWT"
bc rc-ok-stale "$A" "branch: feature/rc-a worktree: $AWT" >/dev/null
o="$(snap rc-ok-stale)"
check "stale B-wt recorded: the declared A-wt still decides (complete)" "$(field "$o" BC)" "complete"
check "stale B-wt recorded: session_worktree replaced by A-wt" "$(field "$o" WT)" "$AWT"
case_end

case_begin "pass-direct-main" "hooks/workflow-mark/branching-handler.js"
new_state rc-ok-direct
ENFORCE_WORKTREE=off bc rc-ok-direct "$A" "main: direct work in the main checkout" >/dev/null
o="$(snap rc-ok-direct)"
check "direct + main: branching_complete complete" "$(field "$o" BC)" "complete"
check "direct + main: delivery_path direct" "$(field "$o" DP)" "direct"
case_end

# ============================================================================================
case_begin "reject-pr-no-worktree-then-fixed" "hooks/workflow-mark/branching-reconcile.js"
reject_row "pr no-worktree" rc-pr-nowt "$A" "branch: feature/rc-a" "no-worktree"
bc rc-pr-nowt "$A" "branch: feature/rc-a worktree: $AWT" >/dev/null
o="$(snap rc-pr-nowt)"
check "pr no-worktree: re-run with the worktree completes" "$(field "$o" BC)" "complete"
check "pr no-worktree: re-run records pull_request" "$(field "$o" DP)" "pull_request"
case_end

case_begin "reject-pr-worktree-missing" "hooks/workflow-mark/branching-reconcile.js"
reject_row "pr worktree-missing" rc-pr-missing "$A" "branch: feature/rc-a worktree: $MISSING" "worktree-missing"
case_end

case_begin "reject-pr-worktree-is-main" "hooks/workflow-mark/branching-reconcile.js"
reject_row "pr worktree-is-main" rc-pr-main "$A" "branch: main worktree: $A" "worktree-is-main"
case_end

case_begin "reject-pr-worktree-other-repo" "hooks/workflow-mark/branching-reconcile.js"
reject_row "pr worktree-other-repo" rc-pr-other "$A" "branch: feature/rc-b worktree: $BWT" "worktree-other-repo"
lc_out="$(printf '%s' "$RC_LAST_OUT" | tr '[:upper:]' '[:lower:]')"
check_contains "pr worktree-other-repo: shows the repo cwd's common dir" "$lc_out" "$(printf '%s' "$A/.git" | tr '[:upper:]' '[:lower:]')"
check_contains "pr worktree-other-repo: shows the declared worktree's common dir" "$lc_out" "$(printf '%s' "$B/.git" | tr '[:upper:]' '[:lower:]')"
case_end

case_begin "reject-pr-non-git-worktree" "hooks/workflow-mark/branching-reconcile.js"
reject_row "pr non-git worktree" rc-pr-nogit "$A" "branch: feature/rc-a worktree: $NOGIT" "worktree-is-main" "could not confirm"
case_end

case_begin "reject-pr-repo-unknown" "hooks/workflow-mark/branching-reconcile.js"
reject_row "pr repo-unknown" rc-pr-repounk "$NOGIT" "branch: feature/rc-a worktree: $AWT" "repo-unknown"
case_end

# ============================================================================================
# Judgment A: a direct delivery must not be declared from / into a linked worktree.
case_begin "reject-direct-cwd-linked-worktree" "hooks/workflow-mark/branching-reconcile.js"
ENFORCE_WORKTREE=off reject_row "direct cwd=A-wt" rc-d-cwd "$AWT" "branch: feature/rc-a" "direct-in-linked-worktree"
ENFORCE_WORKTREE=off bc rc-d-cwd "$A" "main: back in the main checkout" >/dev/null
check "direct cwd=A-wt: re-run from main completes" "$(field "$(snap rc-d-cwd)" BC)" "complete"
case_end

case_begin "reject-direct-worktree-off-marker-declares-linked" "hooks/workflow-mark/branching-reconcile.js"
MARKER_DIR="$(field "$(RC_SID=rc-d-marker s27_node 'out("D", req("hooks/workflow-state").getSessionStateDir(process.env.RC_SID));')" D)"
mkdir -p "$MARKER_DIR"; : > "$MARKER_DIR/rc-d-marker.worktree-off"
reject_row "WORKTREE_OFF + A-wt" rc-d-marker "$A" "branch: feature/rc-a worktree: $AWT" "direct-in-linked-worktree"
rm -f "$MARKER_DIR/rc-d-marker.worktree-off"
case_end

# ============================================================================================
# Profile write failure: the profile's updateTopLevel throws (preload) → step stays pending, no
# delivery_path / auto_merge_pr, re-run guidance; without the preload the re-run completes.
cat > "$S27_TMP/fail-profile.js" <<'JS'
"use strict";
const core = require(process.env.S27_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/state-io/core.js");
const orig = core.updateTopLevel;
const BOOM = "injected delivery-profile write failure";
core.updateTopLevel = function (sid, fn) {
  const probe = new Proxy({}, { set(t, k, v) {
    if (/^(delivery_path|auto_merge_pr)/.test(String(k))) throw new Error(BOOM);
    t[k] = v; return true;
  } });
  try { fn(probe); } catch (e) { if (e && e.message === BOOM) throw e; }
  return orig.apply(this, arguments);
};
JS
case_begin "profile-write-failure-keeps-step-pending" "hooks/workflow-mark/branching-handler.js"
new_state rc-pf
out="$(NODE_OPTIONS="--require $(np "$S27_TMP/fail-profile.js")" bc rc-pf "$A" "branch: feature/rc-a worktree: $AWT")"
o="$(snap rc-pf)"
check "profile failure: branching_complete stays pending" "$(field "$o" BC)" "pending"
check "profile failure: no delivery_path" "$(field "$o" DP)" "-"
check "profile failure: no auto_merge_pr" "$(field "$o" AMP)" "-"
check_contains "profile failure: says the profile was NOT recorded" "$out" "delivery profile NOT recorded"
check_contains "profile failure: gives re-run guidance" "$out" "Re-run"
bc rc-pf "$A" "branch: feature/rc-a worktree: $AWT" >/dev/null
o="$(snap rc-pf)"
check "profile failure: re-run without the fault completes" "$(field "$o" BC)" "complete"
check "profile failure: re-run records pull_request" "$(field "$o" DP)" "pull_request"
case_end

# ============================================================================================
# Reconcile exception: gitCommonDirOf throws (preload) → plan 3-13 rejects with `reconcile-error`
# and writes nothing, on an input that otherwise passes (pr + A-wt).
cat > "$S27_TMP/fail-gcd.js" <<'JS'
"use strict";
const m = require(process.env.S27_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/resolve-worktree-path.js");
m.gitCommonDirOf = function () { throw new Error("injected gitCommonDirOf failure"); };
JS
case_begin "reconcile-exception-rejects-reconcile-error" "hooks/workflow-mark/branching-reconcile.js"
new_state rc-gcd-err "$AWT2"
cp "$(statefile rc-gcd-err)" "$S27_TMP/rc-gcd-err.before"
out="$(NODE_OPTIONS="--require $(np "$S27_TMP/fail-gcd.js")" bc rc-gcd-err "$A" "branch: feature/rc-a worktree: $AWT")"
check_contains "gitCommonDirOf throws: rejection names reconcile-error" "$out" "reconcile-error"
check_contains "gitCommonDirOf throws: rejection gives the re-run sentinel" "$out" "WORKFLOW_BRANCHING_COMPLETE"
if cmp -s "$S27_TMP/rc-gcd-err.before" "$(statefile rc-gcd-err)"; then
  pass "gitCommonDirOf throws: state file byte-identical"
else
  fail "gitCommonDirOf throws: state file changed" "$(snap rc-gcd-err | tr '\n' ' ')"
fi
case_end

# ============================================================================================
# Judgment D: an explicit reset from branching_complete (or earlier) clears the recorded
# profile so the re-completion records it again; a reset from a later step keeps it.
reset_from() { sentinel "$1" "$2" "echo \"<<WORKFLOW_RESET_FROM_$3: re-decide the delivery path>>\""; }

case_begin "reset-from-branching-clears-and-rerecords" "hooks/workflow-mark/branching-handler.js"
new_state rc-rs-bc
ENFORCE_WORKTREE=off bc rc-rs-bc "$A" "main: direct work in the main checkout" >/dev/null
check "D setup: direct recorded" "$(field "$(snap rc-rs-bc)" DP)" "direct"
reset_from rc-rs-bc "$A" branching_complete >/dev/null
o="$(snap rc-rs-bc)"
check "D reset branching_complete: step pending" "$(field "$o" BC)" "pending"
check "D reset branching_complete: delivery_path cleared" "$(field "$o" DP)" "-"
check "D reset branching_complete: delivery_path_origin cleared" "$(field "$o" DPO)" "-"
check "D reset branching_complete: auto_merge_pr cleared" "$(field "$o" AMP)" "-"
bc rc-rs-bc "$A" "branch: feature/rc-a worktree: $AWT" >/dev/null
o="$(snap rc-rs-bc)"
check "D re-completion: branching_complete complete" "$(field "$o" BC)" "complete"
check "D re-completion: pull_request recorded afresh" "$(field "$o" DP)" "pull_request"
case_end

case_begin "reset-from-earlier-step-clears" "hooks/workflow-mark/branching-handler.js"
new_state rc-rs-detail
ENFORCE_WORKTREE=off bc rc-rs-detail "$A" "main: direct work in the main checkout" >/dev/null
reset_from rc-rs-detail "$A" detail >/dev/null
check "D reset detail (earlier): delivery_path cleared" "$(field "$(snap rc-rs-detail)" DP)" "-"
case_end

case_begin "reset-from-later-step-keeps" "hooks/workflow-mark/branching-handler.js"
new_state rc-rs-later
ENFORCE_WORKTREE=off bc rc-rs-later "$A" "main: direct work in the main checkout" >/dev/null
reset_from rc-rs-later "$A" write_tests >/dev/null
o="$(snap rc-rs-later)"
check "D reset write_tests (later): branching_complete stays complete" "$(field "$o" BC)" "complete"
check "D reset write_tests (later): delivery_path kept" "$(field "$o" DP)" "direct"
case_end

# ============================================================================================
read -r -d '' GCD_JS <<'JS' || true
const m = req("hooks/workflow-state/resolve-worktree-path.js");
if (typeof m.gitCommonDirOf !== "function") { out("GCD", "<gitCommonDirOf not exported>"); process.exit(0); }
const e = process.env;
const a = m.gitCommonDirOf(e.RC_A), aw = m.gitCommonDirOf(e.RC_AWT), b = m.gitCommonDirOf(e.RC_B), n = m.gitCommonDirOf(e.RC_NOGIT);
out("GCD", [typeof a === "string" && a.length > 0, a === aw, b !== null && b !== a, n === null].join(","));
JS
case_begin "gitCommonDirOf-unit" "hooks/workflow-state/resolve-worktree-path.js"
o="$(RC_A="$A" RC_AWT="$AWT" RC_B="$B" RC_NOGIT="$NOGIT" s27_node "$GCD_JS")"
check "gitCommonDirOf: non-empty for A, main==linked, other repo differs, non-git null" "$(field "$o" GCD)" "true,true,true,true"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
