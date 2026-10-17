# Baseline follows the session-progress.md update — sourced by ../feat-progress-pressure.sh, which calls
# each bl_case_* inside its own case block. Was tests/bin/feat-2430-flush-mark-transcript.sh:
# #2594 drops the flush mark; the baseline moves when session-progress.md is newer than it, to the size
# of the transcript the hook measures (the envelope's "Z-right", never the larger "A-wrong").
# TL3 gap: Claude Code really delivering transcript_path on PostToolUse, and the model's own Edit
# of session-progress.md (the fixture appends and sets the mtime). Mitigation: WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hooks.

BL="$PP_TMP/bl"
mkdir -p "$BL"
BL_REAL_PLANS_DIR="$PP_REAL_HOME/.workflow-plans"
BL_REAL_WF_DIR="$PP_REAL_HOME/.claude/projects/workflow"
BL_SUF="$$$RANDOM"
BL_SIDS=()

cat > "$BL/bytes.js" <<'JS'
// node bytes.js <path> <n> [append] — write or append n filler bytes.
const fs = require('fs');
const [p, n, mode] = process.argv.slice(2);
fs.mkdirSync(require('path').dirname(p), { recursive: true });
(mode === 'append' ? fs.appendFileSync : fs.writeFileSync)(p, Buffer.alloc(Number(n), 120));
JS
cat > "$BL/progress.js" <<'JS'
// node progress.js <sid> <minutes> — the model updates session-progress.md; mtime = now + <minutes>.
const fs = require('fs');
const [sid, minutes] = process.argv.slice(2);
const p = process.env.WORKFLOW_PLANS_DIR + '/' + sid + '-session-progress.md';
fs.appendFileSync(p, '\n## Current state\nupdated by the model\n');
const t = new Date(Date.now() + Number(minutes) * 60000);
fs.utimesSync(p, t, t);
JS
cat > "$BL/baseline.js" <<'JS'
// node baseline.js <sid> — baseline_bytes of progress-pressure.json, or ABSENT.
const fs = require('fs');
try {
  const m = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + '/' + process.argv[2] + '.control/progress-pressure.json', 'utf8'));
  process.stdout.write(String(m.baseline_bytes));
} catch (e) { process.stdout.write('ABSENT'); }
JS

bl_nj() { run_with_timeout 60 node "$(np "$BL/$1")" "${@:2}" 2>&1; }
bl_tpath() { np "$PP_TMP/transcripts/$1/$2.jsonl"; }
bl_plant() { bl_nj bytes.js "$(bl_tpath "$1" "$2")" "$3" "${4:-}" >/dev/null; }
# bl_new_sid <VAR> <tag> — seed a session and assign its id to VAR (never inside $(...), so the
# BL_SIDS registration survives in this shell).
bl_new_sid() { local s="pb-$2-$BL_SUF"; BL_SIDS+=("$s"); pp_state seed "$s"; printf -v "$1" '%s' "$s"; }
bl_nudge() {
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{}}' \
    "$1" "$2" "$(np "$PP_TMP/neutral")" | run_with_timeout 60 node "$PP_HOOK" 2>/dev/null
}
# bl_outcome <hook stdout> — fired / quiet / other:<text>.
bl_outcome() {
  local compact="${1//[[:space:]]/}"
  if [[ "$1" == *'[progress check]'* ]]; then printf 'fired'
  elif [[ -z "$compact" || "$compact" == '{}' ]]; then printf 'quiet'
  else printf 'other:%s' "${1:0:120}"; fi
}
bl_expect() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }
BL_WRONG=$((2 * MiB))
BL_RIGHT=$((64 * 1024))
# bl_pair <sid> — the same sid in two project dirs; Z-right is the one the envelope names.
bl_pair() { bl_plant A-wrong "$1" "$BL_WRONG"; bl_plant Z-right "$1" "$BL_RIGHT"; }
# bl_prime <sid> <transcript> — the first evaluation reports workflow_init and sets the baseline.
bl_prime() { bl_nudge "$1" "$2" >/dev/null; bl_nudge "$1" "$2" >/dev/null; }
# bl_update <sid> — one minute passes, then the model writes session-progress.md.
bl_update() { pp_age "$1" 1; bl_nj progress.js "$1" 0 >/dev/null; }
# bl_start <VAR> <tag> — a paired, primed session; sets BL_ZP to its measured transcript.
bl_start() { bl_new_sid "$1" "$2"; bl_pair "${!1}"; BL_ZP="$(bl_tpath Z-right "${!1}")"; bl_prime "${!1}" "$BL_ZP"; }

bl_case_b1() {
  bl_start SID_B1 b1
  bl_plant Z-right "$SID_B1" $((3 * MiB / 2)) append
  bl_expect "B1: 1.5MiB of growth stays quiet" "$(bl_outcome "$(bl_nudge "$SID_B1" "$BL_ZP")")" "quiet"
  bl_update "$SID_B1"
  bl_expect "B1: the evaluation after the session-progress.md update stays quiet" "$(bl_outcome "$(bl_nudge "$SID_B1" "$BL_ZP")")" "quiet"
  bl_expect "B1: the baseline moved to the measured Z-right size, not the first-discovered A-wrong one" \
    "$(bl_nj baseline.js "$SID_B1")" "$((BL_RIGHT + 3 * MiB / 2))"
}

bl_case_b2() {
  bl_start SID_B2 b2
  bl_plant Z-right "$SID_B2" $((3 * MiB / 2)) append
  bl_nudge "$SID_B2" "$BL_ZP" >/dev/null
  bl_update "$SID_B2"
  bl_nudge "$SID_B2" "$BL_ZP" >/dev/null
  # 3MiB since the first baseline, 1.5MiB since the update: quiet only if the update counted.
  bl_plant Z-right "$SID_B2" $((3 * MiB / 2)) append
  bl_expect "B2: 1.5MiB after the update stays quiet" "$(bl_outcome "$(bl_nudge "$SID_B2" "$BL_ZP")")" "quiet"
  bl_plant Z-right "$SID_B2" "$MiB" append
  bl_expect "B2: 2.5MiB after the update fires (the growth was not re-baselined away)" "$(bl_outcome "$(bl_nudge "$SID_B2" "$BL_ZP")")" "fired"
}

bl_case_b3() {
  bl_start SID_B3 b3
  bl_plant Z-right "$SID_B3" $((3 * MiB / 2)) append
  bl_expect "B3: 1.5MiB stays quiet" "$(bl_outcome "$(bl_nudge "$SID_B3" "$BL_ZP")")" "quiet"
  bl_plant Z-right "$SID_B3" $((3 * MiB / 2)) append
  bl_expect "B3: without a session-progress.md update, 3MiB fires (B2's quiet is the update's doing)" "$(bl_outcome "$(bl_nudge "$SID_B3" "$BL_ZP")")" "fired"
}

bl_case_b4() {
  bl_start SID_B4 b4
  bl_nj progress.js "$SID_B4" -10 >/dev/null
  bl_plant Z-right "$SID_B4" $((3 * MiB / 2)) append
  bl_expect "B4: 1.5MiB stays quiet" "$(bl_outcome "$(bl_nudge "$SID_B4" "$BL_ZP")")" "quiet"
  bl_expect "B4: a session-progress.md older than the baseline does not move it" "$(bl_nj baseline.js "$SID_B4")" "$BL_RIGHT"
  bl_plant Z-right "$SID_B4" "$MiB" append
  bl_expect "B4: 2.5MiB since the baseline fires" "$(bl_outcome "$(bl_nudge "$SID_B4" "$BL_ZP")")" "fired"
}

bl_case_b5() {
  local pa pb
  bl_new_sid SID_A b5a
  bl_new_sid SID_B b5b
  bl_plant sess-a "$SID_A" "$BL_RIGHT"
  bl_plant sess-b "$SID_B" "$BL_RIGHT"
  pa="$(bl_tpath sess-a "$SID_A")"
  pb="$(bl_tpath sess-b "$SID_B")"
  bl_prime "$SID_A" "$pa"
  bl_prime "$SID_B" "$pb"
  pp_age "$SID_B" 1
  bl_update "$SID_A"
  bl_plant sess-a "$SID_A" $((5 * MiB / 2)) append
  bl_plant sess-b "$SID_B" $((5 * MiB / 2)) append
  bl_expect "B5: B, whose session-progress.md was not written, fires at 2.5MiB" "$(bl_outcome "$(bl_nudge "$SID_B" "$pb")")" "fired"
  bl_expect "B5: A's own update moves A's baseline, so A stays quiet" "$(bl_outcome "$(bl_nudge "$SID_A" "$pa")")" "quiet"
}

bl_case_b6() {
  local s f leaked=""
  bl_expect "B6: every seeded sid is registered for the leak scan (non-vacuity: 6 sids)" "${#BL_SIDS[@]}" "6"
  bl_expect "B6: the fixture control dir received the B1 pressure sidecar (non-vacuity)" \
    "$([[ -f "$WORKFLOW_STATE_DIR/$SID_B1.control/progress-pressure.json" ]] && echo yes || echo no)" "yes"
  for s in "${BL_SIDS[@]}"; do
    for f in "$s-session-progress.md" "$s-handoff.md" "$s.json"; do
      [[ -e "$BL_REAL_PLANS_DIR/$f" ]] && leaked="$leaked $f"
    done
    [[ -e "$BL_REAL_WF_DIR/$s.control" ]] && leaked="$leaked $s.control"
  done
  bl_expect "B6: no fixture sid left a file in the real plans dir or a control dir in the real workflow dir" "${leaked:-none}" "none"
}
