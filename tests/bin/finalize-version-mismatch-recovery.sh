#!/usr/bin/env bash
# tests/bin/finalize-version-mismatch-recovery.sh
# Tests: bin/worker-dispatch/workers/issue-close-finalize/state.js, skills/issue-close-finalize/scripts/run-finalize-terminal.sh
# Tags: issue-close-finalize, state-file, schema-version, recovery-message, scope:issue-specific, TL2
# lang-check: ignore -- the recovery-sentence match accepts the Japanese wording of the state.js message.
# #2561: a state file written under another schema version is refused by both readers, and
# both messages carry ONE recovery sentence (delete the state file, redo the initial phase).
# The sentence is taken from the state.js message (the segment naming the initial phase) and
# must appear verbatim in the run-finalize-terminal.sh output.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP_ROOT" || exit 1

STATE_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/workers/issue-close-finalize/state.js"
TERMINAL_SH="$SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/scripts/run-finalize-terminal.sh"

# A state file one schema version behind the writer's constant.
STATE_FILE="$TMP_ROOT/state.json"
node -e '
const s = require(process.argv[1]);
const st = { schema_version: s.SCHEMA_VERSION - 1, root_issue_number: 7, current_issue_number: 7,
  owner_repo: "acme/widgets", phase: "init_done", triage_action: "resume_e",
  g5_loop_iteration: 0, proposal_counters: { accepted: 0, declined: 0, skipped: 0 } };
require("fs").writeFileSync(process.argv[2], JSON.stringify(st));
' "$STATE_JS" "$STATE_FILE"

STATE_MSG="$(node -e '
const s = require(process.argv[1]);
const st = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
process.stdout.write(String(s.validateState(st, {}) || ""));
' "$STATE_JS" "$STATE_FILE" 2>&1)"
# The recovery sentence: the sentence of the state.js message that names the initial phase.
RECOVERY="$(printf '%s' "$STATE_MSG" | node -e '
const t = require("fs").readFileSync(0, "utf8");
const seg = t.split(/(?<=[.;。])\s*/).find((x) => /initial/.test(x));
process.stdout.write(seg ? seg.trim() : "");
')"

case_begin "state-js-version-mismatch-names-recovery" "bin/worker-dispatch/workers/issue-close-finalize/state.js"
if ! printf '%s' "$STATE_MSG" | grep -q 'schema_version'; then
  fail "state.js refuses an old schema version" "message does not name schema_version: $STATE_MSG"
elif [ -z "$RECOVERY" ]; then
  fail "state.js message carries a recovery sentence naming the initial phase" "got: $STATE_MSG"
elif ! printf '%s' "$RECOVERY" | grep -Eqi 'delete|remove|削除|消'; then
  fail "state.js recovery sentence says to delete the state file" "got: $RECOVERY"
else
  pass "state.js version-mismatch message carries the recovery sentence"
fi
case_end

case_begin "terminal-script-version-mismatch-same-recovery" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
OUT="$(run_with_timeout 30 bash "$TERMINAL_SH" "$STATE_FILE" sid-test "$TMP_ROOT/outcome.json" 2>&1)"
if ! printf '%s' "$OUT" | grep -q 'STATUS=failed'; then
  fail "run-finalize-terminal.sh refuses an old schema version" "output: $OUT"
elif [ -z "$RECOVERY" ]; then
  fail "run-finalize-terminal.sh carries the state.js recovery sentence" "state.js has no recovery sentence to compare (output: $OUT)"
elif ! printf '%s' "$OUT" | grep -qF -- "$RECOVERY"; then
  fail "run-finalize-terminal.sh carries the state.js recovery sentence verbatim" "want '$RECOVERY' in: $OUT"
else
  pass "run-finalize-terminal.sh carries the same recovery sentence as state.js"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
