#!/usr/bin/env bash
# tests/bin/finalize-version-mismatch-recovery.sh
# Tests: bin/worker-dispatch/workers/issue-close-finalize/state.js, skills/issue-close-finalize/scripts/run-finalize-terminal.sh
# Tags: issue-close-finalize, state-file, schema-version, recovery-message, scope:issue-specific, TL2, feature-1889
# lang-check: ignore -- the recovery-sentence match accepts the Japanese wording of the state.js message.
# #2561: a state file written under another schema version is refused by both readers, and
# both messages carry ONE recovery sentence (delete the state file, redo the initial phase).
# The sentence is taken from the state.js message (the segment naming the initial phase) and
# must appear verbatim in the run-finalize-terminal.sh output.
# #1889 (added): ICF-K passes owner_repo / issue_repo from the state to write-outcome.

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

# #1889: ICF-K hands the state's owner_repo to write-outcome as --owner-repo (always) and the
# state's issue_repo as --issue-repo (only when set). Driven on a copy whose close-chain tools are
# stubs; the copy's write-outcome entrypoint logs its argv, then runs the worktree's real writer.
# TL3 gap: a real close chain (gh issue close, sentinel comments) is not exercised here.
SCRIPTS_REL="skills/issue-close-finalize/scripts"
CO="$TMP_ROOT/co"
mkdir -p "$CO/skills/issue-close-finalize" "$CO/bin/github-issues"
cp -r "$SCRIPT_CHECKOUT_ROOT/$SCRIPTS_REL" "$CO/$SCRIPTS_REL"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch" "$CO/bin/worker-dispatch"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$CO/hooks"
for s in close-completed.sh post-close-sentinels.sh wip-state.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$CO/bin/github-issues/$s"
done
ARGV_LOG="$TMP_ROOT/write-outcome-argv.log"
REAL_WRITER="$SCRIPT_CHECKOUT_ROOT/bin/issue-close-write-outcome.js"
if command -v cygpath >/dev/null 2>&1; then
  ARGV_LOG="$(cygpath -m "$ARGV_LOG")"; REAL_WRITER="$(cygpath -m "$REAL_WRITER")"
fi
printf 'require("fs").appendFileSync(%s, JSON.stringify(process.argv.slice(2)) + "\\n");\nrequire(%s);\n' \
  "\"$ARGV_LOG\"" "\"$REAL_WRITER\"" >"$CO/bin/issue-close-write-outcome.js"

# write-state.js <state.js> <state-file> [<issue_repo>] — a current-version state for #42 in o/r.
cat >"$TMP_ROOT/write-state.js" <<'JS'
const s = require(process.argv[2]);
const st = { schema_version: s.SCHEMA_VERSION, root_issue_number: 42, current_issue_number: 42,
  owner_repo: "o/r", phase: "init_done", triage_action: "resume_e",
  g5_loop_iteration: 0, proposal_counters: { accepted: 0, declined: 0, skipped: 0 } };
if (process.argv[4]) st.issue_repo = process.argv[4];
require("fs").writeFileSync(process.argv[3], JSON.stringify(st));
JS

# check.js <outcome-file> <argv-log> — prints "flag-owner|flag-issue|homeRepo|entries|entryRepo" for #42.
cat >"$TMP_ROOT/check.js" <<'JS'
const fs = require("fs");
let argv = []; try { argv = JSON.parse(fs.readFileSync(process.argv[3], "utf8").trim().split("\n")[0]); } catch (_) {}
let bag = { issues: [] }; try { bag = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch (_) {}
const val = (f) => (argv.includes(f) ? argv[argv.indexOf(f) + 1] : "-");
const e = (bag.issues || []).filter((x) => x && x.issueNumber === 42);
console.log([val("--owner-repo"), val("--issue-repo"), bag.homeRepo || "-", e.length, (e[0] && e[0].issueRepo) || "-"].join("|"));
JS

# finalize <name> [<issue_repo>] — one terminal pass; leaves $TMP_ROOT/<name>.out and the result line.
finalize() {
  local name="$1"; shift
  rm -f "$ARGV_LOG"
  node "$TMP_ROOT/write-state.js" "$CO/bin/worker-dispatch/workers/issue-close-finalize/state.js" "$TMP_ROOT/$name-state.json" "$@"
  run_with_timeout 60 bash "$CO/$SCRIPTS_REL/run-finalize-terminal.sh" "$TMP_ROOT/$name-state.json" "sid-$name" \
    "$TMP_ROOT/$name-outcome.json" >"$TMP_ROOT/$name.out" 2>&1
  node "$TMP_ROOT/check.js" "$TMP_ROOT/$name-outcome.json" "$ARGV_LOG"
}

case_begin "finalize-terminal-passes-issue-repo-and-owner-repo" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
got="$(finalize fin1 x/y)"
if ! grep -q '^STATUS=terminal$' "$TMP_ROOT/fin1.out"; then
  fail "issue_repo and owner_repo reach the outcome" "finalize did not complete: $(head -3 "$TMP_ROOT/fin1.out")"
elif [ "$got" != "o/r|x/y|o/r|1|x/y" ]; then
  fail "issue_repo and owner_repo reach the outcome" "want o/r|x/y|o/r|1|x/y (owner|issue flag|homeRepo|entries|issueRepo), got $got"
else
  pass "issue_repo reaches the entry, owner_repo reaches the bag homeRepo"
fi
case_end

case_begin "finalize-terminal-omits-empty-issue-repo" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
got="$(finalize fin2)"
if ! grep -q '^STATUS=terminal$' "$TMP_ROOT/fin2.out"; then
  fail "no issue_repo passes no --issue-repo" "finalize did not complete: $(head -3 "$TMP_ROOT/fin2.out")"
elif [ "$got" != "o/r|-|o/r|1|-" ]; then
  fail "no issue_repo passes no --issue-repo" "want o/r|-|o/r|1|- (owner|issue flag|homeRepo|entries|issueRepo), got $got"
else
  pass "without issue_repo only --owner-repo is passed and the entry carries no repo"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
