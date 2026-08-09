#!/usr/bin/env bash
# tests/feature-1644-review-gap-c11-outcome-writer.sh
# Tests: bin/issue-close-write-outcome.js, hooks/workflow-state/session-facts.js
# Tags: tl2, workflow, issue-close, outcome-json, idempotency, error-handling, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C11 (MEDIUM) — bin/issue-close-write-outcome.js --wf-meta.
#   Usage: issue-close-write-outcome.js --wf-meta <issues-json-array> <outcome-file>
# It writes one `skipped_wf_meta` record per issue into the outcome bag,
# upserting on issueNumber. This file pins the collection edges (empty,
# singleton, duplicates), the rerun/idempotency contract, preservation of
# unrelated pre-existing records, and the two malformed-input paths.
#
# TL3 gap (what this test does NOT catch):
# - Whether /worktree-end's WF-META branch invokes --wf-meta with the argv used
#   here, and whether the outcome file it names is the one the Final Report
#   renderer later reads.
# - Real concurrent writers racing on the same outcome file (the writer does a
#   read-modify-write with no lock).
# Closest-to-action mitigation: the CLI is spawned as a real subprocess against
# real files, so only the skill-side argv wiring is left to a TL3 run.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
OUTCOME_CLI_N="$AGENTS_DIR_N/bin/issue-close-write-outcome.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"
  else fail "$1 -- expected [$2] in: $3"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# DUAL-PIN (#1799).
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
# The CLI requires session-facts.js under AGENTS_CONFIG_DIR (only reached by
# --fallback / --session-id, but resolved from this var in all modes).
export AGENTS_CONFIG_DIR="$AGENTS_DIR_N"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
NEUTRAL_CWD="$TMPDIR_BASE/neutral"; mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

# --- drivers -----------------------------------------------------------------
WF_RC=0; WF_ERR=""
# wf_meta <issues-json> <outcome-file-bash-path>
wf_meta() {
  WF_ERR="$(run_with_timeout node "$OUTCOME_CLI_N" --wf-meta "$1" "$(nrm "$2")" 2>&1 >/dev/null)"
  WF_RC=$?
}

# bag_numbers <file> -- comma-joined issueNumber list, in stored order.
bag_numbers() {
  node -e '
    const fs=require("fs");
    let bag=null;
    try{bag=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(_){}
    let out;
    if(bag===null) out="<unparseable>";
    else if(!bag||!Array.isArray(bag.issues)) out="<no-issues-array>";
    else out=bag.issues.map(e=>String(e.issueNumber)).join(",");
    process.stdout.write(out);
  ' "$(nrm "$1")" 2>/dev/null
}
# bag_field <file> <issueNumber> <field>
bag_field() {
  node -e '
    const fs=require("fs");
    let bag={issues:[]};
    try{bag=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(_){}
    const e=(bag.issues||[]).find(x=>String(x.issueNumber)===process.argv[2]);
    process.stdout.write(e?String(e[process.argv[3]]):"<missing>");
  ' "$(nrm "$1")" "$2" "$3" 2>/dev/null
}
bag_count() {
  node -e '
    const fs=require("fs");
    let bag={};
    try{bag=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(_){}
    process.stdout.write(String((bag.issues||[]).length));
  ' "$(nrm "$1")" 2>/dev/null
}

echo "=== C11-1: numeric issue entries ==="
F1="$TMPDIR_BASE/o1.json"
wf_meta '[1644,1655]' "$F1"
check "C11-1a: exit 0" "0" "$WF_RC"
check "C11-1b: both numeric entries recorded in order" "1644,1655" "$(bag_numbers "$F1")"
check "C11-1c: state is skipped_wf_meta" "skipped_wf_meta" "$(bag_field "$F1" 1644 state)"
check "C11-1d: historyEntry is skipped" "skipped" "$(bag_field "$F1" 1644 historyEntry)"

echo ""
echo "=== C11-2: object issue entries (with and without repo) ==="
F2="$TMPDIR_BASE/o2.json"
wf_meta '[{"number":1644},{"number":1655,"repo":"owner/repo"}]' "$F2"
check "C11-2a: exit 0" "0" "$WF_RC"
check "C11-2b: object entries resolve to their numbers" "1644,1655" "$(bag_numbers "$F2")"
check "C11-2c: repo is carried through when present" "owner/repo" "$(bag_field "$F2" 1655 issueRepo)"
# A local issue has no repo field; JSON.stringify drops the undefined value.
check "C11-2d: a repo-less entry stores no issueRepo" "undefined" "$(bag_field "$F2" 1644 issueRepo)"

echo ""
echo "=== C11-3: EMPTY array ==="
F3="$TMPDIR_BASE/o3.json"
wf_meta '[]' "$F3"
check "C11-3a: exit 0" "0" "$WF_RC"
check "C11-3b: an empty bag file is still written" "0" "$(bag_count "$F3")"
check "C11-3c: the written bag has a well-formed issues array" "" "$(bag_numbers "$F3")"

echo ""
echo "=== C11-4: SINGLETON array ==="
F4="$TMPDIR_BASE/o4.json"
wf_meta '[{"number":1644}]' "$F4"
check "C11-4a: exit 0" "0" "$WF_RC"
check "C11-4b: exactly one record" "1" "$(bag_count "$F4")"
check "C11-4c: the record is the singleton issue" "1644" "$(bag_numbers "$F4")"

echo ""
echo "=== C11-5: DUPLICATE issue numbers are deduped by upsert ==="
# upsertEntry() filters the existing entry with the same issueNumber before
# pushing, so a duplicated input collapses to one record (last write wins).
F5="$TMPDIR_BASE/o5.json"
wf_meta '[1644,1644,{"number":1644},1655]' "$F5"
check "C11-5a: exit 0" "0" "$WF_RC"
check "C11-5b: duplicates collapse to one record per number" "2" "$(bag_count "$F5")"
check "C11-5c: dedupe keeps the LAST occurrence's position" "1644,1655" "$(bag_numbers "$F5")"

echo ""
echo "=== C11-6: RERUN is idempotent and preserves unrelated records ==="
F6="$TMPDIR_BASE/o6.json"
# Pre-existing, unrelated record written by an earlier close phase.
printf '%s' '{"issues":[{"issueNumber":42,"state":"closed","historyEntry":"appended","issueClosed":"yes","sentinelsPosted":"yes","wipCleared":"yes"}]}' > "$F6"
wf_meta '[1644,1655]' "$F6"
FIRST_NUMS="$(bag_numbers "$F6")"
FIRST_BYTES="$(cat "$F6")"
check "C11-6a: unrelated pre-existing record survives the write" "42,1644,1655" "$FIRST_NUMS"
check "C11-6b: the unrelated record keeps its own state" "closed" "$(bag_field "$F6" 42 state)"
wf_meta '[1644,1655]' "$F6"
check "C11-6c: rerun exit 0" "0" "$WF_RC"
check "C11-6d: rerun appends no duplicate records" "3" "$(bag_count "$F6")"
check "C11-6e: rerun leaves the file byte-identical" "$FIRST_BYTES" "$(cat "$F6")"
check "C11-6f: rerun still preserves the unrelated record" "closed" "$(bag_field "$F6" 42 state)"

echo ""
echo "=== C11-7: INVALID JSON input ==="
F7="$TMPDIR_BASE/o7.json"
printf '%s' '{"issues":[{"issueNumber":42,"state":"closed"}]}' > "$F7"
BEFORE7="$(cat "$F7")"
wf_meta 'not json at all' "$F7"
check "C11-7a: exits 1 on unparseable JSON" "1" "$WF_RC"
check_contains "C11-7b: the error names the invalid array" "invalid JSON array" "$WF_ERR"
check "C11-7c: the pre-existing outcome file is left untouched" "$BEFORE7" "$(cat "$F7")"

echo ""
echo "=== C11-8: NON-ARRAY JSON input ==="
# FINDING (pinned CURRENT behavior): the writer validates only that the payload
# is parseable JSON, never that it is an ARRAY. A JSON object parses fine and
# `for (const entry of issues)` then throws TypeError (not iterable) — the
# process dies with node's default exit code 1 BEFORE writeFileSync, so the
# outcome file is not corrupted, but the diagnostic is an uncaught stack trace
# rather than the writer's own usage message.
F8="$TMPDIR_BASE/o8.json"
printf '%s' '{"issues":[{"issueNumber":42,"state":"closed"}]}' > "$F8"
BEFORE8="$(cat "$F8")"
wf_meta '{"number":1644}' "$F8"
check "C11-8a: a JSON object payload exits non-zero" "1" "$WF_RC"
check_contains "C11-8b: it dies on the not-iterable TypeError (uncaught, pinned)" \
  "is not iterable" "$WF_ERR"
check "C11-8c: the outcome file is not corrupted by the failed run" "$BEFORE8" "$(cat "$F8")"
# A bare JSON string is iterable in JS — pinned separately so the "non-array"
# claim is not over-generalized.
F8B="$TMPDIR_BASE/o8b.json"
wf_meta '"1644"' "$F8B"
check "C11-8d: a JSON string payload exits 0 (iterated per character, pinned)" "0" "$WF_RC"
check "C11-8e: it yields undefined-numbered records rather than issue numbers" \
  "undefined" "$(bag_numbers "$F8B")"

echo ""
echo "=== C11-9: missing required args ==="
F9="$TMPDIR_BASE/o9.json"
WF_ERR="$(run_with_timeout node "$OUTCOME_CLI_N" --wf-meta '[1644]' 2>&1 >/dev/null)"; WF_RC=$?
check "C11-9a: omitting <outcome-file> exits 1" "1" "$WF_RC"
check_contains "C11-9b: the usage message names --wf-meta" "--wf-meta requires" "$WF_ERR"
if [ -e "$F9" ]; then fail "C11-9c: a file was written despite the usage error"
else pass "C11-9c: no outcome file written on a usage error"; fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
