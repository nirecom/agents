#!/usr/bin/env bash
# feature-2527-auto-merge-pr-fix.sh — #2527 4-2: AUTO_MERGE_PR is read, pinned at branching, and named a channel.
# Tests: bin/workflow/release-channel, hooks/lib/auto-merge-config.js, hooks/lib/off-value.js, hooks/workflow-state/session-profile.js, hooks/workflow-state/state-io/session-fields.js, hooks/enforce-worktree/config.js
# Tags: scope:issue-specific, workflow-state, session-profile, auto-merge-pr, release-channel, TL2
# TL2: the real writer (workflow-mark.js fed BRANCHING_COMPLETE / RESET_FROM Bash payloads) over a
# fixture repo + linked worktree, the release-channel CLI, and unit calls to the new modules.
# Contracts pinned here (plan 4-2, judgments D/K):
#   isOffValue(v): lowercases, never trims; OFF_VALUES = off,0,false,no,disabled.
#   readAutoMergePr() -> {value: on|off, readable, source: config|default|fallback}.
#   state fields auto_merge_pr / auto_merge_pr_source, written with delivery_path at branching.
#   release-channel --session <sid>: CHANNEL= / AUTO_MERGE_PR= / SOURCE= on stdout, exit 0.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/feature-2527-auto-merge-pr-fix/_lib.sh"

# TL3 gap (not caught here): a live Claude Code session emitting the sentinels; only the
# PostToolUse hook process is exercised. Mitigation: the CLI is what the skills read.
# category: hook-registration.
AMP_TMP="$(make_tmp)"
readonly AMP_TMP
trap amp_teardown EXIT
harness_isolate "$AMP_TMP"
amp_setup

PRE="workflow_init=complete;clarify_intent=pending"
PR_SENTINEL="echo \"<<WORKFLOW_BRANCHING_COMPLETE: branch: feature/2527-amp|worktree: $AMP_WT_M|main>>\""
DIRECT_SENTINEL='echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: main|worktree: main|main>>"'

# branch_pr / branch_direct <sid> — a fresh state, then BRANCHING_COMPLETE through the real hook.
branch_pr() { mk_state "{\"sid\":\"$1\",\"steps\":\"$PRE\"}"; mark_bash "$1" "$AMP_REPO_M" "$PR_SENTINEL" >/dev/null; }
branch_direct() {
  mk_state "{\"sid\":\"$1\",\"steps\":\"$PRE\"}"
  ENFORCE_WORKTREE=off mark_bash "$1" "$AMP_REPO_M" "$DIRECT_SENTINEL" >/dev/null
}
# step_status <sid> <step> — last recorded status from the raw stream.
step_status() {
  AMP_SID="$1" AMP_STEP="$2" amp_node 'const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + process.env.AMP_SID + ".json", "utf8"));
const e = (s.events || []).filter((x) => x.kind === "step_status" && x.step === process.env.AMP_STEP);
console.log(e.length ? e[e.length - 1].status : "<none>");'
}
rawf() { field "$(raw_state "$1")" RAW; }
# cli_stdout_lines <sid> — the number of stdout lines the CLI prints (stderr dropped).
cli_stdout_lines() { run_with_timeout 30 node "$RELEASE_CHANNEL" --session "$1" 2>/dev/null | grep -c .; }

read -r -d '' READ_AMP_JS <<'JS' || true
const m = req("hooks/lib/auto-merge-config.js");
const r = m.readAutoMergePr();
console.log([r.value, r.readable === false ? "unreadable" : "readable", r.source].join("|"));
JS
# read_amp [preload] — readAutoMergePr() in a fresh process ("unreadable" adds the preload).
read_amp() {
  if [ "${1:-}" = "unreadable" ]; then
    NODE_OPTIONS="--require \"$AMP_PRELOAD_UNREADABLE\"" amp_node "$READ_AMP_JS"
  else
    amp_node "$READ_AMP_JS"
  fi
}

read -r -d '' PROF_JS <<'JS' || true
const core = req("hooks/workflow-state/state-io/core.js");
const m = req("hooks/workflow-state/session-profile.js");
const st = core.readState(process.env.AMP_SID);
const r = m.resolveSessionProfile(st, process.env.AMP_SID, { repoDir: process.env.CLAUDE_PROJECT_DIR });
console.log(String(r.autoMergePr) + "|" + String(r.sources && r.sources.autoMergePr));
JS
profile_amp() { AMP_SID="$1" amp_node "$PROF_JS"; }

read -r -d '' OFF_TABLE_JS <<'JS' || true
const m = req("hooks/lib/off-value.js");
const rows = [["off", true], ["OFF", true], ["Off", true], ["0", true], ["false", true], ["FALSE", true],
  ["no", true], ["NO", true], ["disabled", true], ["Disabled", true], [" off", false], ["off ", false],
  ["on", false], ["1", false], ["true", false], ["yes", false], ["enabled", false], ["", false],
  [undefined, false], [null, false], ["offf", false], ["of", false]];
const bad = rows.filter(([v, want]) => m.isOffValue(v) !== want).map(([v]) => JSON.stringify(v));
console.log(bad.length ? "MISMATCH:" + bad.join(",") : "ok");
console.log("VALUES=" + [...(m.OFF_VALUES || [])].sort().join(","));
JS

read -r -d '' EW_EQUIV_JS <<'JS' || true
const off = req("hooks/lib/off-value.js");
const cfg = req("hooks/enforce-worktree/config.js");
const vals = ["off", "OFF", "0", "false", "No", "disabled", " off", "off ", "on", "1", "true", "", "maybe"];
const bad = [];
for (const v of vals) {
  process.env.ENFORCE_WORKTREE = v;
  if (cfg.isEnforceWorktreeOn() !== !off.isOffValue(v)) bad.push(JSON.stringify(v));
}
delete process.env.ENFORCE_WORKTREE;
if (cfg.isEnforceWorktreeOn() !== true) bad.push("<unset>");
console.log(bad.length ? "MISMATCH:" + bad.join(",") : "ok");
JS

case_begin "off-value: isOffValue lowercases, never trims, five-word vocabulary (table)" "hooks/lib/off-value.js"
o="$(amp_node "$OFF_TABLE_JS")"
check "isOffValue table" "$(printf '%s\n' "$o" | head -n 1)" "ok"
check "OFF_VALUES vocabulary" "$(field "$o" VALUES)" "0,disabled,false,no,off"
case_end

case_begin "enforce-worktree: isEnforceWorktreeOn is the negation of isOffValue (table)" "hooks/enforce-worktree/config.js"
check "isEnforceWorktreeOn == !isOffValue for every row, unset is on" "$(amp_node "$EW_EQUIV_JS")" "ok"
src="$(cat "$AMP_ROOT_M/hooks/enforce-worktree/config.js")"
check_contains "config.js uses isOffValue" "$src" "isOffValue"
check_not_contains "config.js keeps no private vocabulary literal" "$src" '"disabled"'
case_end

case_begin "auto-merge-config: readAutoMergePr value / readable / source" "hooks/lib/auto-merge-config.js"
amp_env "AUTO_MERGE_PR=off"
check ".env off -> off/config" "$(read_amp)" "off|readable|config"
amp_env "AUTO_MERGE_PR=OFF"
check ".env OFF spelling -> off/config" "$(read_amp)" "off|readable|config"
amp_env "AUTO_MERGE_PR=on"
check ".env on -> on/config" "$(read_amp)" "on|readable|config"
amp_env "AUTO_MERGE_PR=banana"
check ".env other value -> on/config" "$(read_amp)" "on|readable|config"
amp_env
check "unset -> on/default" "$(read_amp)" "on|readable|default"
check "export off -> off/config" "$(AUTO_MERGE_PR=off read_amp)" "off|readable|config"
amp_env_local "AUTO_MERGE_PR=off"
check ".env.local overlay off -> off/config" "$(read_amp)" "off|readable|config"
amp_env "AUTO_MERGE_PR=on"
check ".env.local off wins over .env on" "$(read_amp)" "off|readable|config"
amp_env_local
amp_env "AUTO_MERGE_PR=off"
check "unreadable -> on/fallback even with .env off" "$(read_amp unreadable)" "on|unreadable|fallback"
amp_env
case_end

case_begin "pin: global .env off is pinned at BRANCHING_COMPLETE (pull_request)" "hooks/workflow-state/state-io/session-fields.js"
amp_env "AUTO_MERGE_PR=off"
branch_pr pin-off
check "sanity: branching_complete complete" "$(step_status pin-off branching_complete)" "complete"
check "raw fields written by the real writer" "$(rawf pin-off)" "pull_request|off|config"
o="$(release_channel pin-off)"
check "CLI channel/value/source" "$(channel_triple "$o")" "web-merge|off|recorded"
check "CLI exit 0" "$(field "$o" EXIT)" "0"
check "CLI prints exactly 3 stdout lines" "$(cli_stdout_lines pin-off)" "3"
check "profile autoMergePr recorded" "$(profile_amp pin-off)" "off|recorded"
case_end

case_begin "pin: the pinned value survives a later .env edit" "hooks/workflow-state/state-io/session-fields.js"
amp_env "AUTO_MERGE_PR=on"
check "raw fields unchanged after .env on" "$(rawf pin-off)" "pull_request|off|config"
check "CLI still web-merge/off/recorded" "$(channel_triple "$(release_channel pin-off)")" "web-merge|off|recorded"
check "profile still off/recorded" "$(profile_amp pin-off)" "off|recorded"
mark_bash pin-off "$AMP_REPO_M" "$PR_SENTINEL" >/dev/null
check "re-emitted BRANCHING_COMPLETE keeps the first value (write-once)" "$(rawf pin-off)" "pull_request|off|config"
amp_env
case_end

case_begin "pin: the .env.local overlay is what gets pinned" "hooks/workflow-state/state-io/session-fields.js"
amp_env_local "AUTO_MERGE_PR=off"
branch_pr pin-local
amp_env_local
check "overlay off pinned" "$(rawf pin-local)" "pull_request|off|config"
check "CLI after overlay removal" "$(channel_triple "$(release_channel pin-local)")" "web-merge|off|recorded"
case_end

case_begin "pin: unreadable at branching pins on/fallback; a later off never flips the channel" "hooks/workflow-state/state-io/session-fields.js"
amp_env "AUTO_MERGE_PR=off"
mk_state "{\"sid\":\"pin-fb\",\"steps\":\"$PRE\"}"
mark_bash_unreadable pin-fb "$AMP_REPO_M" "$PR_SENTINEL" >/dev/null
check "sanity: branching_complete complete" "$(step_status pin-fb branching_complete)" "complete"
check "fallback on pinned" "$(rawf pin-fb)" "pull_request|on|fallback"
check "CLI dialog/on/recorded-fallback with .env off readable" "$(channel_triple "$(release_channel pin-fb)")" "user-verified-dialog|on|recorded-fallback"
check "profile on/recorded-fallback" "$(profile_amp pin-fb)" "on|recorded-fallback"
amp_env
case_end

case_begin "pin: unset pins on/default" "hooks/workflow-state/state-io/session-fields.js"
branch_pr pin-unset
check "unset pinned as on/default" "$(rawf pin-unset)" "pull_request|on|default"
check "CLI dialog/on/recorded" "$(channel_triple "$(release_channel pin-unset)")" "user-verified-dialog|on|recorded"
case_end

case_begin "pin: a direct delivery records AUTO_MERGE_PR too" "hooks/workflow-state/state-io/session-fields.js"
amp_env "AUTO_MERGE_PR=off"
branch_direct pin-direct
check "sanity: branching_complete complete" "$(step_status pin-direct branching_complete)" "complete"
check "direct + off pinned" "$(rawf pin-direct)" "direct|off|config"
check "CLI: direct is always the dialog" "$(channel_triple "$(release_channel pin-direct)")" "user-verified-dialog|off|recorded"
amp_env
case_end

case_begin "channel: bootstrap push stays on the dialog; old state reads live (provisional)" "hooks/workflow-state/session-profile.js"
mk_state '{"sid":"ch-web","path":"pull_request","amp":"off","upto":"user_verification","steps":"user_verification=pending"}'
check "pull_request + off pinned -> web-merge" "$(channel_triple "$(release_channel ch-web)")" "web-merge|off|recorded"
mk_state '{"sid":"ch-boot","path":"pull_request","amp":"off","upto":"user_verification","steps":"user_verification=pending","annotate":"push_branch.decision=bootstrap"}'
check "bootstrap push -> dialog" "$(field "$(release_channel ch-boot)" CHANNEL)" "user-verified-dialog"
mk_state '{"sid":"ch-old","path":"pull_request","upto":"user_verification","steps":"user_verification=pending"}'
amp_env "AUTO_MERGE_PR=off"
check "old state + live off -> web-merge provisional" "$(channel_triple "$(release_channel ch-old)")" "web-merge|off|provisional"
check "old state profile off/provisional" "$(profile_amp ch-old)" "off|provisional"
amp_env
check "old state + live unset -> dialog provisional" "$(channel_triple "$(release_channel ch-old)")" "user-verified-dialog|on|provisional"
case_end

case_begin "release-channel CLI: unreadable live config, missing and corrupt state" "bin/workflow/release-channel"
amp_env "AUTO_MERGE_PR=off"
o="$(NODE_OPTIONS="--require \"$AMP_PRELOAD_UNREADABLE\"" release_channel ch-old)"
check "old state + unreadable -> dialog/on/unreadable" "$(channel_triple "$o")" "user-verified-dialog|on|unreadable"
check "unreadable exit 0" "$(field "$o" EXIT)" "0"
amp_env
o="$(release_channel no-such-session)"
check "missing state -> dialog" "$(field "$o" CHANNEL)" "user-verified-dialog"
check "missing state -> unreadable" "$(field "$o" SOURCE)" "unreadable"
check "missing state exit 0" "$(field "$o" EXIT)" "0"
printf '{ not json' > "$WORKFLOW_STATE_DIR/ch-corrupt.json"
o="$(release_channel ch-corrupt)"
check "corrupt state -> dialog/unreadable" "$(field "$o" CHANNEL)|$(field "$o" SOURCE)" "user-verified-dialog|unreadable"
check "corrupt state exit 0" "$(field "$o" EXIT)" "0"
case_end

case_begin "clearDeliveryProfile: explicit RESET_FROM_branching_complete clears, re-branching re-records" "hooks/workflow-state/state-io/session-fields.js"
amp_env "AUTO_MERGE_PR=off"
branch_pr rs-bc
check "pinned before the reset" "$(rawf rs-bc)" "pull_request|off|config"
mark_bash rs-bc "$AMP_REPO_M" 'echo "<<WORKFLOW_RESET_FROM_branching_complete: re-pin the delivery profile>>"' >/dev/null
check "sanity: branching_complete pending after reset" "$(step_status rs-bc branching_complete)" "pending"
check "explicit reset cleared the profile" "$(rawf rs-bc)" "<absent>|<absent>|<absent>"
amp_env "AUTO_MERGE_PR=on"
mark_bash rs-bc "$AMP_REPO_M" "$PR_SENTINEL" >/dev/null
check "re-branching re-records the live value" "$(rawf rs-bc)" "pull_request|on|config"
amp_env
case_end

case_begin "clearDeliveryProfile: later resets keep the pinned profile" "hooks/workflow-state/state-io/session-fields.js"
amp_env "AUTO_MERGE_PR=off"
branch_pr rs-wt
mark_bash rs-wt "$AMP_REPO_M" 'echo "<<WORKFLOW_RESET_FROM_write_tests: redo the tests>>"' >/dev/null
check "sanity: write_tests pending after reset" "$(step_status rs-wt write_tests)" "pending"
check "RESET_FROM_write_tests keeps the profile" "$(rawf rs-wt)" "pull_request|off|config"
mk_state '{"sid":"rs-push","path":"pull_request","amp":"off","upto":"user_verification","steps":"user_verification=complete"}'
mark_bash rs-push "$AMP_REPO_M" "git push origin main" 0 >/dev/null
check "sanity: post-push reset ran" "$(field "$(raw_state rs-push)" UV)" "pending"
check "post-push reset keeps the profile" "$(rawf rs-push)" "pull_request|off|config"
amp_env
case_end

case_begin "state-io: setDeliveryProfile / clearDeliveryProfile replace setDeliveryPath" "hooks/workflow-state/state-io/session-fields.js"
o="$(amp_node 'const a = req("hooks/workflow-state/state-io.js"); const b = req("hooks/workflow-state");
for (const [n, m] of [["IO", a], ["IDX", b]]) out(n, [typeof m.setDeliveryProfile, typeof m.clearDeliveryProfile, typeof m.setDeliveryPath].join("|"));')"
check "state-io.js exports" "$(field "$o" IO)" "function|function|undefined"
check "workflow-state index exports" "$(field "$o" IDX)" "function|function|undefined"
case_end

case_begin "install: release-channel and wait-web-merge.sh are auto-allowed (static)" "bin/workflow/release-channel"
allow="$(tr -d '\r' < "$AMP_ROOT_M/install/settings-allow-commands.txt")"
check "allow line bin/workflow/release-channel" "$(printf '%s\n' "$allow" | grep -cx 'bin/workflow/release-channel')" "1"
check "allow line ending in wait-web-merge.sh" "$(printf '%s\n' "$allow" | grep -c 'wait-web-merge\.sh$')" "1"
check "release-channel exists" "$([ -f "$RELEASE_CHANNEL" ] && echo yes || echo no)" "yes"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
