#!/usr/bin/env bash
# tests/bin/feat-2430-flush-mark-transcript.sh
# Tests: bin/workflow/handoff-append, hooks/lib/handoff-pressure.js, hooks/handoff-pressure-nudge.js
# Tags: handoff, flush-mark, pressure-nudge, transcript, baseline-increment, fail-open, fixture-isolation, regression-2430, scope:issue-specific, pwsh-not-required, TL2

# Issue #2430 C1 — the flush mark must be sized from the transcript the nudge hook actually measures. One session id can own a <sid>.jsonl in several project dirs; the old sizing took the first one readdir returned, so the mark recorded the wrong file and the next nudge either never saw the baseline move or discarded the mark. The fixture plants the same sid under "A-wrong" (larger, sorts first) and "Z-right" (the hook-supplied transcript_path), and drives the real nudge hook and the real handoff-append CLI.

# TL3 gap (what this test does NOT catch):
# - Claude Code really delivering transcript_path on UserPromptSubmit, and a real multi-project ~/.claude/projects layout.
# - readdir order is filesystem-defined: the pre-fix discrimination relies on "A-wrong" being returned first (true on NTFS / APFS); the post-fix assertions hold in any order.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): F1 and F2 are expected to FAIL until markFlush sizes from the path the nudge hook recorded; F3-F7 hold today and pin the fallback / fail-open / per-session / isolation contract.

# -e is omitted on purpose: a failing probe must not abort the file before the remaining cases report.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

REAL_PLANS_DIR="${WORKFLOW_PLANS_DIR:-${HOME:?}/.workflow-plans}"
REAL_WF_DIR="${WORKFLOW_STATE_DIR:-${HOME:?}/.claude/projects/workflow}"
TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$WORKFLOW_STATE_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
cd "$TMP" || exit 1

KiB=1024
MiB=$((1024 * KiB))
SUF="$$$RANDOM"
ALL_SIDS=()

# ---- helpers (JS lives in generated files that read argv / process.env only)
cat > "$TMP/seed.js" <<'JS'
// node seed.js <sid> — a session inside its workflow active period.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const sid = process.argv[2];
S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
S.markStep(sid, 'workflow_init', 'complete');
JS
cat > "$TMP/bytes.js" <<'JS'
// node bytes.js <path> <n> [append] — write or append n filler bytes.
const fs = require('fs');
const [p, n, mode] = process.argv.slice(2);
fs.mkdirSync(require('path').dirname(p), { recursive: true });
(mode === 'append' ? fs.appendFileSync : fs.writeFileSync)(p, Buffer.alloc(Number(n), 120));
JS
cat > "$TMP/mark.js" <<'JS'
// node mark.js <sid> — the flush mark's bytes: a number, "null", or ABSENT.
const fs = require('fs');
try {
  const m = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + '/' + process.argv[2] + '.control/handoff-flush-mark.json', 'utf8'));
  process.stdout.write(String(m.bytes));
} catch (e) { process.stdout.write('ABSENT'); }
JS
cat > "$TMP/discover.js" <<'JS'
// node discover.js <sid> — which dir the readdir-order discovery picks (fixture diagnostic).
const { discoverUpstreamTranscript } = require(process.env.AGENTS + '/bin/lib/resume-session/transcript-fallback');
const p = discoverUpstreamTranscript(process.argv[2]);
process.stdout.write(p ? require('path').basename(require('path').dirname(p)) : 'NONE');
JS

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
tpath() { np "$TMP/transcripts/$1/$2.jsonl"; }
plant() { nj bytes.js "$(tpath "$1" "$2")" "$3" "${4:-}" >/dev/null; }
# new_sid <VAR> <tag> — seed a session and assign its id to VAR. Called directly,
# never inside $(...), so the ALL_SIDS registration survives in this shell.
new_sid() { local s="fm-$2-$SUF"; ALL_SIDS+=("$s"); nj seed.js "$s" >/dev/null; printf -v "$1" '%s' "$s"; }
mark_bytes() { nj mark.js "$1"; }
flush() {
    run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append" --session "$1" --class C --step - \
        --key "flush-${2:-1}" --summary "probe flush ${2:-1}" --pointer - --origin flush 2>/dev/null
}
nudge() {
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"go"}' \
        "$1" "$2" "$(np "$TMP")" | run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/handoff-pressure-nudge.js" 2>/dev/null
}
# outcome <hook stdout> — fired / quiet / other:<text>.
outcome() {
    local compact="${1//[[:space:]]/}"
    if [[ "$1" == *'[handoff check]'* ]]; then printf 'fired'
    elif [[ "$compact" == '{}' ]]; then printf 'quiet'
    else printf 'other:%s' "${1:0:120}"; fi
}
expect() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi
}

# pair <sid> <wrong-bytes> <right-bytes> — the same sid in two project dirs.
pair() { plant A-wrong "$1" "$2"; plant Z-right "$1" "$3"; }

WRONG=$((2 * MiB))
RIGHT=$((64 * KiB))

# ---- F1: the mark is sized from the transcript the nudge measured

case_begin "flush-mark-sized-from-measured-transcript" "bin/workflow/handoff-append"
new_sid SID_F1 f1
pair "$SID_F1" "$WRONG" "$RIGHT"
echo "INFO: readdir-order discovery picks '$(nj discover.js "$SID_F1")' for the pair fixture (pre-fix discrimination needs A-wrong)"
expect "F1: the first nudge only initialises the baseline" "$(outcome "$(nudge "$SID_F1" "$(tpath Z-right "$SID_F1")")")" "quiet"
OUT="$(flush "$SID_F1")"; RC=$?
expect "F1: the flush is written (exit 0)" "$RC:${OUT%% *}" "0:WRITTEN=1"
expect "F1: the flush mark bytes equal the measured Z-right transcript, not the first-discovered A-wrong one" \
    "$(mark_bytes "$SID_F1")" "$RIGHT"
case_end

# ---- F2: growth written after the flush counts toward the next nudge

case_begin "post-flush-growth-reaches-next-nudge" "hooks/handoff-pressure-nudge.js"
new_sid SID_F2 f2
pair "$SID_F2" "$WRONG" "$RIGHT"
ZP="$(tpath Z-right "$SID_F2")"
nudge "$SID_F2" "$ZP" >/dev/null
flush "$SID_F2" >/dev/null
# +1.5MiB: below INCREMENT_BYTES from the flush size, so quiet either way. Pre-fix
# the mark (2MiB, larger than the transcript) is discarded and the baseline jumps here.
plant Z-right "$SID_F2" $((3 * MiB / 2)) append
expect "F2: 1.5MiB after the flush stays quiet" "$(outcome "$(nudge "$SID_F2" "$ZP")")" "quiet"
# +1MiB more: 2.5MiB since the flush fires; only 1MiB since a re-anchored baseline would not.
plant Z-right "$SID_F2" "$MiB" append
expect "F2: 2.5MiB of post-flush growth fires the nudge (the growth was not re-baselined away)" \
    "$(outcome "$(nudge "$SID_F2" "$ZP")")" "fired"
case_end

# ---- F3: with no nudge-recorded path, discovery sizes the mark

case_begin "flush-mark-discovery-fallback" "bin/workflow/handoff-append"
new_sid SID_F3 f3
plant only-dir "$SID_F3" $((128 * KiB))
OUT="$(flush "$SID_F3")"; RC=$?
expect "F3: the flush is written (exit 0)" "$RC:${OUT%% *}" "0:WRITTEN=1"
expect "F3: without any nudge run the mark is the discovered transcript's size" "$(mark_bytes "$SID_F3")" "$((128 * KiB))"
case_end

# ---- F4: a recorded path that no longer exists falls back to discovery

case_begin "flush-mark-stale-path-falls-back" "bin/workflow/handoff-append"
new_sid SID_F4 f4
pair "$SID_F4" "$WRONG" "$RIGHT"
nudge "$SID_F4" "$(tpath Z-right "$SID_F4")" >/dev/null
rm -f "$TMP/transcripts/Z-right/$SID_F4.jsonl"
flush "$SID_F4" >/dev/null
expect "F4: a deleted measured transcript falls back to the discovered one (not null)" "$(mark_bytes "$SID_F4")" "$WRONG"
case_end

# ---- F5: no transcript anywhere is fail-open

case_begin "flush-without-transcript-fails-open" "bin/workflow/handoff-append"
new_sid SID_F5 f5
OUT="$(flush "$SID_F5")"; RC=$?
expect "F5: with no transcript the flush still prints WRITTEN=1 and exits 0" "$RC:${OUT%% *}" "0:WRITTEN=1"
expect "F5: with no transcript the mark bytes are null" "$(mark_bytes "$SID_F5")" "null"
nudge "$SID_F5" "$(np "$TMP/transcripts/nowhere/$SID_F5.jsonl")" >/dev/null
rm -f "$TMP/wf/$SID_F5.control/handoff-flush-mark.json"
flush "$SID_F5" 2 >/dev/null
expect "F5: a recorded path with no transcript anywhere also yields null" "$(mark_bytes "$SID_F5")" "null"
case_end

# ---- F7: the measured path is per session, never a process-global "last measured"

case_begin "flush-mark-measured-path-is-per-session" "bin/workflow/handoff-append"
new_sid SID_A f7a
new_sid SID_B f7b
SIZE_A=$((80 * KiB))
SIZE_B=$((208 * KiB))
plant sess-a "$SID_A" "$SIZE_A"
plant sess-b "$SID_B" "$SIZE_B"
nudge "$SID_A" "$(tpath sess-a "$SID_A")" >/dev/null
# B is measured last: an implementation that keeps one "last measured path" would size A's mark from B's file.
nudge "$SID_B" "$(tpath sess-b "$SID_B")" >/dev/null
OUT="$(flush "$SID_A")"; RC=$?
expect "F7: flushing A after B was measured is written (exit 0)" "$RC:${OUT%% *}" "0:WRITTEN=1"
expect "F7: A's mark is sized from A's own transcript, not the last-measured B one" "$(mark_bytes "$SID_A")" "$SIZE_A"
flush "$SID_B" >/dev/null
expect "F7: B's mark is sized from B's own transcript" "$(mark_bytes "$SID_B")" "$SIZE_B"
case_end

# ---- F6: every write stays inside the fixture

case_begin "fixture-writes-stay-isolated" "hooks/handoff-pressure-nudge.js"
expect "F6: every seeded sid is registered for the leak scan (non-vacuity: 7 sids)" "${#ALL_SIDS[@]}" "7"
expect "F6: the fixture control dir received the F1 pressure sidecar (non-vacuity)" \
    "$([[ -f "$TMP/wf/$SID_F1.control/handoff-pressure.json" ]] && echo yes || echo no)" "yes"
leaked=""
for s in "${ALL_SIDS[@]}"; do
    for f in "$s-handoff-pressure.json" "$s-handoff-flush-mark.json" "$s-handoff.md" "$s.json"; do
        [[ -e "$REAL_PLANS_DIR/$f" ]] && leaked="$leaked $f"
    done
    [[ -e "$REAL_WF_DIR/$s.control" ]] && leaked="$leaked $s.control"
done
expect "F6: no fixture sid left a file in the real plans dir or a control dir in the real workflow dir" "${leaked:-none}" "none"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
