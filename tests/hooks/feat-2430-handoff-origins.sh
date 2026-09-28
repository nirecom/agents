#!/usr/bin/env bash
# tests/hooks/feat-2430-handoff-origins.sh
# Tests: hooks/lib/handoff-artifact.js, bin/workflow/handoff-append
# Tags: handoff, origin, vocabulary, backward-compat, regression-2430, dup-group-keep:size-hard-limit, scope:issue-specific, pwsh-not-required, TL1
# Split rationale: append target tests/hooks/feat-2218-handoff-artifact.sh is 488 lines; appending O1–O3 (~70 lines) would exceed the 500-line HARD limit.

# Issue #2430 — the origin vocabulary is renamed so each value says what produced the entry: "step-end" becomes "procedure-point" (a skill procedure's fixed recording point, not the end of a workflow step) and the mechanical records get their own "auto-record" instead of borrowing "flush". Writers must refuse the retired value so a stale caller surfaces, but handoff files already on disk are append-only history and must still read back in full.

# TDD (write_code has not run): the vocabulary and rejection cases are expected to FAIL until HANDOFF_ORIGINS is renamed; the legacy read-back cases already hold and pin the compatibility contract.

set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts"
export CLAUDE_WORKFLOW_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$CLAUDE_WORKFLOW_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$AGENTS_DIR")"
cd "$TMP" || exit 1

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }

# A handoff written before the rename: one step-end entry and one compaction
# entry recorded under the old borrowed origin.
cat > "$TMP/wf/legacy-sid-handoff.md" <<'MD'
# Handoff — legacy-sid

handoff_schema_version: 1

## B
- 2026-09-01T10:00:00.000Z | flush | - | compaction | context compaction occurred at 2026-09-01T10:00:00.000Z | -

## E
- 2026-09-01T09:00:00.000Z | step-end | write_tests | commit-push | pushed the red tests | feature/x
MD

cat > "$TMP/vocab.js" <<'JS'
const H = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const bad = [];
const want = ['procedure-point', 'gate-block', 'auto-record', 'flush'];
if (JSON.stringify(H.HANDOFF_ORIGINS) !== JSON.stringify(want)) bad.push('HANDOFF_ORIGINS:' + JSON.stringify(H.HANDOFF_ORIGINS));
const e = (origin, key) => ({ cls: 'D', step: '-', key, summary: 's', pointer: '-', origin });
const r = H.appendHandoffEntry('vocab-sid', e('step-end', 'retired'));
if (r.written !== false || r.reason !== 'invalid') bad.push('step-end-accepted:' + JSON.stringify(r));
for (const o of want) {
  const w = H.appendHandoffEntry('vocab-sid', e(o, 'k-' + o));
  if (w.written !== true) bad.push(o + '-refused:' + JSON.stringify(w));
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

case_begin "origin-vocabulary-is-renamed" "hooks/lib/handoff-artifact.js"
expect "O1: HANDOFF_ORIGINS is the four renamed values; the writer refuses step-end and accepts each new value" "$(nj vocab.js)" "OK"
case_end

case_begin "cli-refuses-the-retired-origin" "bin/workflow/handoff-append"
run_with_timeout 60 node "$AGENTS_DIR/bin/workflow/handoff-append" --session cli-sid --class D --step - --key retired --summary s --pointer - --origin step-end >/dev/null 2>"$TMP/cli.err"
RC=$?
expect "O2: --origin step-end exits 2" "$RC" "2"
expect "O2: the usage names procedure-point as a valid origin" "$(grep -q 'procedure-point' "$TMP/cli.err" && echo yes || echo no)" "yes"
expect "O2: nothing is written" "$([ -e "$TMP/wf/cli-sid-handoff.md" ] && echo written || echo none)" "none"
case_end

cat > "$TMP/legacy.js" <<'JS'
const H = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const bad = [];
const all = () => [].concat.apply([], Object.values(H.readHandoff('legacy-sid').entriesByClass || {}));
const has = (list, origin, key) => list.some((x) => x.origin === origin && x.key === key);
let list = all();
if (list.length !== 2 || !has(list, 'flush', 'compaction') || !has(list, 'step-end', 'commit-push')) bad.push('read:' + JSON.stringify(list));
const view = H.renderHandoffForResume(H.readHandoff('legacy-sid'));
if (view.indexOf('pushed the red tests') === -1 || view.indexOf('context compaction occurred') === -1) bad.push('render:' + view);
if (process.argv[2] === 'append') {
  const origin = H.HANDOFF_ORIGINS.indexOf('procedure-point') === -1 ? 'gate-block' : 'procedure-point';
  const w = H.appendHandoffEntry('legacy-sid', { cls: 'E', step: 'run_tests', key: 'new-entry', summary: 'after the rename', pointer: '-', origin });
  if (w.written !== true) bad.push('append:' + JSON.stringify(w));
  list = all();
  if (list.length !== 3 || !has(list, 'flush', 'compaction') || !has(list, 'step-end', 'commit-push')) bad.push('legacy-lost-on-append:' + JSON.stringify(list));
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

case_begin "legacy-origins-still-read-back" "hooks/lib/handoff-artifact.js"
expect "O3: a pre-rename handoff (step-end, flush compaction) reads and renders in full" "$(nj legacy.js)" "OK"
expect "O3: appending a new entry keeps every legacy line" "$(nj legacy.js append)" "OK"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
