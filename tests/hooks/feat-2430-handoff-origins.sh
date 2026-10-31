#!/usr/bin/env bash
# tests/hooks/feat-2430-handoff-origins.sh
# Tests: bin/workflow/handoff-append
# Tags: handoff, origin, vocabulary, backward-compat, regression-2430, regression-2652, state-handoff-record, dup-group-keep:size-hard-limit, scope:issue-specific, pwsh-not-required, TL1
# Split rationale: append target tests/hooks/feat-2218-handoff-artifact.sh is near the 500-line HARD limit; the origin cases stay in their own file.

# Issue #2430 — the origin vocabulary says what produced each record: "procedure-point" (a skill procedure's fixed recording point), "gate-block" and "auto-record". A retired value must be refused so a stale caller surfaces.
# Since #2652 "gate-block" and "auto-record" are hook-only (written by the hooks through write.js); the CLI refusing them is covered by tests/bin/feature-2652-handoff-append-origins.js.
# Issue #2652 — the CLI writes a state handoff record (a `state_handoff_record` event in the session's state file) instead of a line in handoff.md, and the main-session "flush" origin retires: its facts live in session-progress.md (rules/progress-update.md). A handoff.md already on disk is history for the state handoff reader (owned by its own tests) and the writer never touches it.
# Removed with #2652: the HANDOFF_ORIGINS export check, the legacy read-back/render case and readDocumentFile all exercised hooks/lib/handoff-artifact.js, which is deleted; reading legacy handoff.md now belongs to the state handoff reader (legacy-handoff-md.js) and its tests.
# Module-level checks are not possible here: the test-language gate keeps a bash file from targeting a js module, so every case drives the CLI and reads the state file back.

# TDD (write_code has not run): the state-file and flush-refusal assertions are expected to FAIL until handoff-append writes state handoff records and refuses flush; the step-end refusal already holds.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"; readonly TMP
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$WORKFLOW_STATE_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP" || exit 1

CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append"
nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }
# append <sid> <key> <origin> — one CLI call; prints "<stdout+stderr>|rc=N".
append() {
    local out rc
    out="$(run_with_timeout 60 node "$CLI" --session "$1" --class D --step - --key "$2" --summary s --pointer - --origin "$3" 2>&1)"; rc=$?
    printf '%s|rc=%s' "$out" "$rc"
}

cat > "$TMP/seed-active.js" <<'JS'
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const sid = process.argv[2];
S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
S.markStep(sid, 'workflow_init', 'complete');
process.stdout.write('seeded');
JS

# recs.js <sid> [key] — the state handoff records in the sid's state file, as
# "<origin>/<cls>/<record_key>" lines; NOSTATE when the file is absent.
cat > "$TMP/recs.js" <<'JS'
const fs = require('fs');
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const sid = process.argv[2], key = process.argv[3];
if (!fs.existsSync(S.getStatePath(sid))) { process.stdout.write('NOSTATE'); process.exit(0); }
let ev = [];
try { ev = ((S.readRawState(sid) || {}).events || []); } catch (e) { process.stdout.write('READERR:' + e.message); process.exit(0); }
const recs = ev.filter((e) => e && e.kind === 'state_handoff_record' && (!key || e.record_key === key));
process.stdout.write(recs.map((e) => e.origin + '/' + e.cls + '/' + e.record_key).join(',') || 'NONE');
JS

# The CLI's one origin, procedure-point, lands as one state handoff record carrying it, and a
# handoff.md written before #2652 stays byte-identical (the writer never touches it).
# gate-block and auto-record are hook-only; their CLI refusal lives in tests/bin/feature-2652-handoff-append-origins.js.
case_begin "cli-records-each-origin-in-state" "bin/workflow/handoff-append"
expect "O1: active session seeded" "$(nj seed-active.js vocab-sid)" "seeded"
mkdir -p "$TMP/wf/vocab-sid.control"
printf '%s\n' '# Handoff — vocab-sid' '' 'handoff_schema_version: 1' '' '## E' '- 2026-09-01T09:00:00.000Z | step-end | write_tests | commit-push | pushed the red tests | feature/x' > "$TMP/wf/vocab-sid.control/handoff.md"
cp "$TMP/wf/vocab-sid.control/handoff.md" "$TMP/legacy.before"
for o in procedure-point; do
    R="$(append vocab-sid "k-$o" "$o")"
    expect "O1: --origin $o exits 0" "${R##*|rc=}" "0"
    expect "O1: --origin $o lands as one state handoff record with that origin" "$(nj recs.js vocab-sid "k-$o")" "$o/D/k-$o"
done
expect "O1: the legacy handoff.md is byte-identical after the appends" "$(cmp -s "$TMP/legacy.before" "$TMP/wf/vocab-sid.control/handoff.md" && echo same || echo changed)" "same"
case_end

# Both retired values — step-end (#2430) and flush (#2652) — exit 2 with the
# usage on stderr and write nothing.
case_begin "cli-refuses-the-retired-origin" "bin/workflow/handoff-append"
expect "O2: active session seeded" "$(nj seed-active.js cli-sid)" "seeded"
for o in step-end flush; do
    run_with_timeout 60 node "$CLI" --session cli-sid --class D --step - --key "retired-$o" --summary s --pointer - --origin "$o" >"$TMP/o2.out" 2>"$TMP/o2.err"
    RC=$?
    expect "O2: --origin $o exits 2" "$RC" "2"
    expect "O2: --origin $o: stderr names procedure-point as a valid origin" "$(grep -q 'procedure-point' "$TMP/o2.err" && echo yes || echo no)" "yes"
    expect "O2: --origin $o: stdout reports no write" "$(grep -c 'WRITTEN=1' "$TMP/o2.out")" "0"
    expect "O2: --origin $o: no state handoff record is written" "$(nj recs.js cli-sid "retired-$o")" "NONE"
done
expect "O2: no handoff.md is written" "$([ -e "$TMP/wf/cli-sid.control/handoff.md" ] && echo written || echo none)" "none"
expect "O2: no handoff-flush-mark.json is written" "$([ -e "$TMP/wf/cli-sid.control/handoff-flush-mark.json" ] && echo written || echo none)" "none"
expect "O2: --help's origin list names no flush" "$(run_with_timeout 60 node "$CLI" --help 2>&1 | grep -E -c -- '--origin <origin>.*one of:.*flush')" "0"
expect "O2: --help's origin list names procedure-point" "$(run_with_timeout 60 node "$CLI" --help 2>&1 | grep -E -c -- '--origin <origin>.*one of:.*procedure-point')" "1"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
