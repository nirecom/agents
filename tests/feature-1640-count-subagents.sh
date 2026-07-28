#!/usr/bin/env bash
# tests/feature-1640-count-subagents.sh
# Tests: bin/count-subagents, hooks/lib/workflow-state/session-id.js, bin/vscode-cc-repair/prune.js, bin/vscode-cc-repair/prune/verify.js
# Tags: measurement, subagent-count, session-transcript, enumeration-failure, stub-classifier, scope:issue-specific, pwsh-not-required, TL2
#
# (b) of #1640. `bin/count-subagents` aggregates `input.subagent_type` occurrences out of
# Claude Code session transcripts, plus the C3 half of the plan: an enumeration failure
# must never be reported as "0 invocations". `listJsonlByMtimeStrict()` is the new
# failure-reporting view of the enumerator; `_listJsonlByMtime()` must keep its old
# swallow-everything semantics so hooks/lib/workflow-state/state-io.js does not change
# behaviour.
#
# ISOLATION CONTRACT (mirrors tests/bin-vscode-cc-repair-prune.sh). The tool reads the
# user's own session storage, so every invocation applies BOTH overrides:
#   1. --projects-root <tmp>   — replaces the ~/.claude/projects default
#   2. HOME / USERPROFILE=<tmp> — belt and braces: a dropped override lands in a fixture
#                                 tree, never in the real home
# run_cli supplies both; nothing in this suite ever reads the real session store.
#
# TL3 gap (what this test does NOT catch):
# - the real ~/.claude/projects tree (O(100) slugs, O(1000) .jsonl, multi-GB): scan cost
#   under VERIFY_MAX_SCAN, and the real record shapes emitted by the installed Claude Code
#   version (this suite pins only the `Task`/`Agent` tool-name variants known today).
# - POSIX permission semantics on the Windows host: every chmod-driven row degrades to a
#   documented SKIP. The nonexistent-directory rows below are the platform-independent
#   substitute and always run.
# - a genuinely concurrent writer deleting a file between readdir and stat; C3-b injects a
#   deterministic statSync fault at the module boundary instead.
# - the shipped execute bit (git mode 100755): the CLI is always invoked via `node <path>`.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

# The harness (counters, run_cli / node_m / summary helpers) and the fixture vocabulary
# live in the sibling lib.sh; only the cases are kept here. The split is the HARD
# 500-line limit of rules/coding/file-split.md, same arrangement as
# tests/feature-1180-commit-lang-check/lib.sh.
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1640-count-subagents"
# shellcheck source=./feature-1640-count-subagents/lib.sh
. "$SUITE_DIR/lib.sh"

# ---- B1: basic aggregation ---------------------------------------------------

echo "== B1: basic aggregation (3 records / 2 types) =="
R1="$(new_root)"
mkdir -p "$R1/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; rec "$SID_A" survey-code Task t2
  rec "$SID_A" detail-planner Task t3; } > "$R1/slug-one/$SID_A.jsonl"
run_cli --projects-root "$(native_path "$R1")" --all
assert_eq "B1/exit-0"      "0" "$CLI_RC"
assert_eq "B1/invocations" "3" "$(summary invocations)"
assert_eq "B1/types"       "2" "$(summary types)"
assert_eq "B1/sessions"    "1" "$(summary sessions)"
assert_eq "B1/survey-code"    "2" "$(type_count survey-code)"
assert_eq "B1/detail-planner" "1" "$(type_count detail-planner)"

echo "== B1b: session titles are never printed (user content) =="
TITLE_LEAK="absent"
grep -qF -- "$SECRET_TITLE" <<< "$CLI_OUT" && TITLE_LEAK="leaked"
assert_eq "B1b/no-title-in-output" "summary-printed absent" "$(has_summary) $TITLE_LEAK"

# ---- B2: stub exclusion ------------------------------------------------------

echo "== B2: title-only copy under a different slug is excluded as a stub =="
R2="$(new_root)"
mkdir -p "$R2/slug-one" "$R2/slug-two"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; rec "$SID_A" survey-code Task t2
  rec "$SID_A" detail-planner Task t3; } > "$R2/slug-one/$SID_A.jsonl"
title "$SID_A" "$SECRET_TITLE" > "$R2/slug-two/$SID_A.jsonl"
run_cli --projects-root "$(native_path "$R2")" --all
assert_eq "B2/exit-0"        "0" "$CLI_RC"
assert_eq "B2/stub-excluded" "1" "$(summary stub-excluded)"
assert_eq "B2/invocations"   "3" "$(summary invocations)"
assert_eq "B2/types"         "2" "$(summary types)"

echo "== B2b: --include-stubs counts the stub file too =="
run_cli --projects-root "$(native_path "$R2")" --all --include-stubs
assert_eq "B2b/exit-0"      "0" "$CLI_RC"
assert_eq "B2b/scanned"     "2" "$(summary scanned)"
assert_eq "B2b/invocations" "3" "$(summary invocations)"

# ---- B3: non-session files ---------------------------------------------------

echo "== B3: SESSION_FILE_PATTERN admits only <uuid>.jsonl =="
# Table-driven: one predicate (SESSION_FILE_PATTERN) over 4 filenames. Each row gets its
# own root holding exactly that one file, so `scanned` is a direct read-out of the
# predicate rather than a difference against a baseline.
while IFS='|' read -r name fname sid want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; fname="${fname//[[:space:]]/}"
    sid="${sid//[[:space:]]/}";   want="${want//[[:space:]]/}"
    r="$(new_root)"; mkdir -p "$r/slug-one"
    { content "$sid"; rec "$sid" survey-code Task b3a; } > "$r/slug-one/$fname"
    run_cli --projects-root "$(native_path "$r")" --all
    assert_eq "B3/$name" "0 $want" "$CLI_RC $(summary scanned)"
done <<EOF
session-uuid       | $SID_A.jsonl              | $SID_A      | 1
agent-prefixed     | agent-$AGENT_UUID.jsonl   | $AGENT_UUID | 0
history-dotfile    | .history.jsonl            | $SID_B      | 0
bare-name          | notes.jsonl               | $SID_A      | 0
EOF

# Mixed in one directory: the excluded files must not leak invocations into the totals.
R3="$(new_root)"
mkdir -p "$R3/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; } > "$R3/slug-one/$SID_A.jsonl"
{ content "$AGENT_UUID"; rec "$AGENT_UUID" survey-code Task a1
  rec "$AGENT_UUID" survey-code Task a2; }  > "$R3/slug-one/agent-$AGENT_UUID.jsonl"
{ content "$SID_B"; rec "$SID_B" detail-planner Task h1; } > "$R3/slug-one/.history.jsonl"
run_cli --projects-root "$(native_path "$R3")" --all
assert_eq "B3/mixed-dir" "0 1 1 1" \
    "$CLI_RC $(summary scanned) $(summary invocations) $(summary types)"
assert_eq "B3/no-agent-row" "NO-ROW" "$(type_count detail-planner)"

# ---- B4/B5/B6: record-level predicates ---------------------------------------

echo "== B4: a record whose sessionId differs from the filename is not counted =="
R4="$(new_root)"
mkdir -p "$R4/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1
  rec "$SID_C" survey-code Task foreign1; } > "$R4/slug-one/$SID_A.jsonl"
run_cli --projects-root "$(native_path "$R4")" --all
assert_eq "B4/exit-0"      "0" "$CLI_RC"
assert_eq "B4/invocations" "1" "$(summary invocations)"

echo "== B5: a duplicated tool_use id inside one file counts once =="
R5="$(new_root)"
mkdir -p "$R5/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task dup1
  rec "$SID_A" survey-code Task dup1; } > "$R5/slug-one/$SID_A.jsonl"
run_cli --projects-root "$(native_path "$R5")" --all
assert_eq "B5/exit-0"        "0" "$CLI_RC"
assert_eq "B5/invocations"   "1" "$(summary invocations)"
assert_eq "B5/survey-code"   "1" "$(type_count survey-code)"

echo "== B6: the predicate is input.subagent_type, not block.name (CPR-8) =="
R6="$(new_root)"
mkdir -p "$R6/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task old-name
  rec "$SID_A" survey-code Agent new-name; } > "$R6/slug-one/$SID_A.jsonl"
run_cli --projects-root "$(native_path "$R6")" --all
assert_eq "B6/exit-0"      "0" "$CLI_RC"
assert_eq "B6/invocations" "2" "$(summary invocations)"
assert_eq "B6/survey-code" "2" "$(type_count survey-code)"

# ---- C3-a: enumeration failure on a slug directory ---------------------------

echo "== C3-a: a slug directory that cannot be enumerated is an observation failure =="
R7="$(new_root)"
mkdir -p "$R7/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; } > "$R7/slug-one/$SID_A.jsonl"
# Platform-independent form: --cwd maps to a slug directory that does not exist.
run_cli --projects-root "$(native_path "$R7")" --cwd "$(native_path "$TMPROOT")/no-such-project-1640"
assert_eq "C3-a/exit-1" "1" "$CLI_RC"
ENUM_ERR="$(summary enum-errors)"
ENUM_VERDICT="$ENUM_ERR"
case "$ENUM_ERR" in
    ''|*[!0-9]*) : ;;
    *) [ "$ENUM_ERR" -ge 1 ] && ENUM_VERDICT="ge1" ;;
esac
assert_eq "C3-a/enum-errors-ge-1" "ge1" "$ENUM_VERDICT"
STDERR_WARNED="no-stderr-warning"
grep -qiE 'warn|error' <<< "$CLI_STDERR" && STDERR_WARNED="warned"
assert_eq "C3-a/stderr-warn" "summary-printed warned" "$(has_summary) $STDERR_WARNED"

echo "== C3-a2: an unreadable slug directory (POSIX permissions) =="
R8="$(new_root)"
mkdir -p "$R8/slug-locked"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; } > "$R8/slug-locked/$SID_A.jsonl"
if deny_read "$R8/slug-locked"; then
    run_cli --projects-root "$(native_path "$R8")" --all
    assert_eq "C3-a2/exit-1" "1" "$CLI_RC"
    chmod -R u+rwx "$R8" >/dev/null 2>&1 || true
else
    skip_case "C3-a2 unreadable slug dir: chmod is advisory on this host (or running as root)"
fi

# ---- C3-c: unreadable / missing --projects-root ------------------------------

echo "== C3-c: an unusable --projects-root never reports '0 sessions' =="
run_cli --projects-root "$(native_path "$TMPROOT")/no-such-root-1640" --all
# Paired with the summary line: a bare "exit 1" is also what a crashing binary produces.
assert_eq "C3-c/missing-root-exit-1" "1 summary-printed" "$CLI_RC $(has_summary)"

R9="$(new_root)"
mkdir -p "$R9/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; } > "$R9/slug-one/$SID_A.jsonl"
if deny_read "$R9"; then
    run_cli --projects-root "$(native_path "$R9")" --all
    assert_eq "C3-c/unreadable-root-exit-1" "1" "$CLI_RC"
    chmod -R u+rwx "$R9" >/dev/null 2>&1 || true
else
    skip_case "C3-c unreadable root: chmod is advisory on this host (or running as root)"
fi

# ---- C3-e: the positive verdict --------------------------------------------
#
# The symmetric half of C3-a/C3-c. Those pin "an enumeration failure is never reported as
# 0". This one pins the converse: a legitimately empty store IS 0, and must be a clean
# success. Without it, an over-eager guard that treats "0 sessions" as suspicious would
# pass every failure-side row while breaking every real empty store.
echo "== C3-e: an empty but readable --projects-root is a clean 0 =="
while IFS='|' read -r name mkslug; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; mkslug="${mkslug//[[:space:]]/}"
    r="$(new_root)"
    [ "$mkslug" = "yes" ] && mkdir -p "$r/slug-empty"
    run_cli --projects-root "$(native_path "$r")" --all
    assert_eq "C3-e/$name" "0 summary-printed 0 0 0 0" \
        "$CLI_RC $(has_summary) $(summary sessions) $(summary scanned) $(summary invocations) $(summary enum-errors)"
    STDERR_QUIET="warned"
    grep -qiE 'warn|error' <<< "$CLI_STDERR" || STDERR_QUIET="quiet"
    assert_eq "C3-e/$name/no-warning" "quiet" "$STDERR_QUIET"
done <<'EOF'
zero-slugs        | no
slug-no-sessions  | yes
EOF

# A non-session file alone must also stay a clean 0, not an observation failure: the
# exclusion path (B3) and the empty-store path (C3-e) must agree on the exit code.
R10="$(new_root)"
mkdir -p "$R10/slug-one"
{ content "$AGENT_UUID"; rec "$AGENT_UUID" survey-code Task e1; } > "$R10/slug-one/agent-$AGENT_UUID.jsonl"
run_cli --projects-root "$(native_path "$R10")" --all
assert_eq "C3-e/excluded-only-is-clean-0" "0 summary-printed 0 0" \
    "$CLI_RC $(has_summary) $(summary invocations) $(summary enum-errors)"

# ---- unreadable session file -------------------------------------------------

echo "== B7: an unreadable session file warns, still prints the summary, exits 1 =="
R10="$(new_root)"
mkdir -p "$R10/slug-one"
{ content "$SID_A"; rec "$SID_A" survey-code Task t1; } > "$R10/slug-one/$SID_A.jsonl"
{ content "$SID_B"; rec "$SID_B" detail-planner Task t2; } > "$R10/slug-one/$SID_B.jsonl"
if deny_read "$R10/slug-one/$SID_B.jsonl"; then
    run_cli --projects-root "$(native_path "$R10")" --all
    assert_eq "B7/exit-1" "1" "$CLI_RC"
    SUMMARY_SEEN="no-summary-line"
    grep -qF -- 'subagent-summary:' <<< "$CLI_OUT" && SUMMARY_SEEN="summary-printed"
    assert_eq "B7/summary-still-printed" "summary-printed" "$SUMMARY_SEEN"
    WARNED="no-stderr-warning"
    grep -qiE 'warn|error|unreadable' <<< "$CLI_STDERR" && WARNED="warned"
    assert_eq "B7/stderr-warn" "warned" "$WARNED"
    chmod -R u+rwx "$R10" >/dev/null 2>&1 || true
else
    skip_case "B7 unreadable session file: chmod is advisory on this host (or running as root)"
fi

# ---- C3-b / C3-d: the enumerator API itself ----------------------------------

echo "== C3-b: listJsonlByMtimeStrict records only the faulting file =="
R11="$(new_root)"
mkdir -p "$R11/slug-one"
: > "$R11/slug-one/$SID_A.jsonl"
: > "$R11/slug-one/$SID_B.jsonl"
R11_SLUG="$(native_path "$R11/slug-one")"
# lstatSync (not statSync) is what the enumerator calls: statSync follows symlinks, so a
# UUID-shaped .jsonl symlink could pull a path from outside the transcript directory into
# the report. Patched AFTER every require, so the module loader is never affected.
STRICT_JS='
const m = require("./hooks/lib/workflow-state/session-id");
const fs = require("fs");
const orig = fs.lstatSync;
fs.lstatSync = function (p, ...a) {
  if (String(p).indexOf(process.env.BAD_NAME) >= 0) { const e = new Error("boom"); e.code = "ENOENT"; throw e; }
  return orig.call(fs, p, ...a);
};
if (typeof m.listJsonlByMtimeStrict !== "function") { console.log("NO-STRICT-EXPORT"); process.exit(0); }
const r = m.listJsonlByMtimeStrict(process.env.DIR);
const scopes = (r.errors || []).map((e) => e.scope).join("+");
console.log("files=" + (r.files || []).length + " errors=" + (r.errors || []).length + " scope=" + scopes);
'
DIR="$R11_SLUG" BAD_NAME="$SID_B" node_m "$STRICT_JS"
assert_eq "C3-b/partial-result" "files=1 errors=1 scope=file" "$NODE_OUT"

echo "== C3-b2: a directory that cannot be read yields a dir-scoped error =="
STRICT_DIR_JS='
const m = require("./hooks/lib/workflow-state/session-id");
if (typeof m.listJsonlByMtimeStrict !== "function") { console.log("NO-STRICT-EXPORT"); process.exit(0); }
const r = m.listJsonlByMtimeStrict(process.env.DIR);
const scopes = (r.errors || []).map((e) => e.scope).join("+");
console.log("files=" + (r.files || []).length + " errors=" + (r.errors || []).length + " scope=" + scopes);
'
NODE_RC=0
NODE_OUT="$(cd "$AGENTS_DIR" && HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    DIR="$(native_path "$TMPROOT")/no-such-dir-1640" run_with_timeout 60 node -e "$STRICT_DIR_JS" 2>&1)" || NODE_RC=$?
assert_eq "C3-b2/dir-error" "files=0 errors=1 scope=dir" "$NODE_OUT"

# ---- C3-f: a symlinked .jsonl entry is skipped, and skipping is not an error --
#
# The enumerator stats with lstatSync and drops every non-regular-file entry. statSync
# would follow the link instead, so a UUID-shaped `.jsonl` symlink could pull a transcript
# in from outside the selected directory and print that outside path in the report.
# Both halves matter and are asserted together:
#   files=1  — the link is not listed (a statSync regression yields files=2, since the
#              link target here is a perfectly readable regular file)
#   errors=0 — the skip is not an observation failure (reporting it would inflate
#              enum-errors and make a deliberate skip indistinguishable from a failed stat)
echo "== C3-f: a symlinked .jsonl is skipped without being reported as an error =="
R12="$(new_root)"
mkdir -p "$R12/slug-one"
: > "$R12/slug-one/$SID_A.jsonl"
: > "$TMPROOT/outside-$SID_C.jsonl"
SYM_ENTRY="$R12/slug-one/$SID_C.jsonl"
# `ln -s` silently degrades to a copy on MSYS/Windows without developer mode or
# MSYS=winsymlinks:nativestrict. A copy IS a regular file and would legitimately be
# listed, so the assertion is only meaningful behind an `[ -L ]` proof — same gate as L8
# in tests/feature-1640-measure-norm-docs.sh (CPR-5).
if ln -s "$TMPROOT/outside-$SID_C.jsonl" "$SYM_ENTRY" 2>/dev/null && [ -L "$SYM_ENTRY" ]; then
    DIR="$(native_path "$R12/slug-one")" BAD_NAME="__no-such-path-1640__" node_m "$STRICT_JS"
    assert_eq "C3-f/symlink-skipped-not-an-error" "files=1 errors=0 scope=" "$NODE_OUT"
else
    rm -f "$SYM_ENTRY"
    skip_case "C3-f symlinked .jsonl: ln -s degraded to a plain copy on this host (no native symlink support) — a copy is a regular file and would be listed legitimately, so the skip cannot be observed here"
fi

echo "== C3-d: _listJsonlByMtime keeps its swallow-everything semantics (state-io.js:185) =="
LEGACY_JS='
const m = require("./hooks/lib/workflow-state/session-id");
const fs = require("fs");
const orig = fs.lstatSync;
fs.lstatSync = function (p, ...a) {
  if (process.env.BAD_NAME && String(p).indexOf(process.env.BAD_NAME) >= 0) {
    const e = new Error("boom"); e.code = "ENOENT"; throw e;
  }
  return orig.call(fs, p, ...a);
};
console.log(JSON.stringify(m._listJsonlByMtime(process.env.DIR)));
'
NODE_RC=0
NODE_OUT="$(cd "$AGENTS_DIR" && HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    DIR="$R11_SLUG" BAD_NAME="$SID_B" run_with_timeout 60 node -e "$LEGACY_JS" 2>&1)" || NODE_RC=$?
assert_eq "C3-d/file-stat-failure-empty" "[]" "$NODE_OUT"

NODE_RC=0
NODE_OUT="$(cd "$AGENTS_DIR" && HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    DIR="$(native_path "$TMPROOT")/no-such-dir-1640" BAD_NAME="" run_with_timeout 60 node -e "$LEGACY_JS" 2>&1)" || NODE_RC=$?
assert_eq "C3-d/dir-failure-empty" "[]" "$NODE_OUT"

# Non-regression counterpart (CPR-5): the healthy path must still return entries.
NODE_RC=0
NODE_OUT="$(cd "$AGENTS_DIR" && HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    DIR="$R11_SLUG" BAD_NAME="" run_with_timeout 60 node -e '
const m = require("./hooks/lib/workflow-state/session-id");
console.log(String(m._listJsonlByMtime(process.env.DIR).length));
' 2>&1)" || NODE_RC=$?
assert_eq "C3-d/healthy-path-unchanged" "2" "$NODE_OUT"

# ---- arguments ---------------------------------------------------------------

echo "== B8: argument handling =="
# Table-driven: one exit-code contract (0 ok / 2 argument error) over the whole argument
# surface. The `..` rows are symmetric with L7/dotdot-repo in
# tests/feature-1640-measure-norm-docs.sh (CPR-5): both path-taking CLIs must reject a
# `..` segment even when the resolved target is a perfectly good directory.
# No field contains a space, so unquoted expansion of $args is intentional word-splitting.
R1_NATIVE="$(native_path "$R1")"
R1_DOTDOT="$R1_NATIVE/../$(basename "$R1")"
while IFS='|' read -r name args want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
    # shellcheck disable=SC2086
    run_cli $args
    assert_eq "B8/$name" "$want" "$CLI_RC"
done <<EOF
help                | --help                                             | 0
known-session       | --projects-root $R1_NATIVE --all --session $SID_A  | 0
invalid-session     | --projects-root $R1_NATIVE --all --session ../etc/passwd | 2
unknown-flag        | --projects-root $R1_NATIVE --all --nope            | 2
relative-root       | --projects-root relative/path                      | 2
dotdot-root         | --projects-root $R1_DOTDOT --all                   | 2
relative-cwd        | --projects-root $R1_NATIVE --cwd relative/path     | 2
dotdot-cwd          | --projects-root $R1_NATIVE --cwd $R1_DOTDOT        | 2
EOF

# Rows with an assertion beyond the exit code stay explicit.
run_cli --projects-root "$R1_NATIVE" --all --session "$SID_A"
assert_eq "B8/known-session-invocations" "3" "$(summary invocations)"

run_cli --projects-root "$R1_NATIVE" --all --session "$SID_C"
MSG="no-message"
grep -qF -- "$SID_C" <<< "$CLI_OUT" && MSG="names-the-session"
assert_eq "B8/missing-session-exit-1" "1 names-the-session" "$CLI_RC $MSG"

# ---- B9: --json schema and totals consistency (Step 2-6) ---------------------
#
# Symmetric with L5 in tests/feature-1640-measure-norm-docs.sh. R1 is the B1 fixture:
# 1 session, 3 invocations, 2 types (survey-code=2, detail-planner=1).
echo "== B9: --json schema and totals consistency =="
run_cli --projects-root "$R1_NATIVE" --all --json
assert_eq "B9/exit-0" "0" "$CLI_RC"
JSON_PROBE="$(J="$CLI_STDOUT" run_with_timeout 30 node -e '
let d; try { d = JSON.parse(process.env.J); } catch (e) { console.log("PARSE-FAIL"); process.exit(0); }
const keys = ["generated_at", "root", "sessions", "totals", "excluded", "errors"];
const missing = keys.filter((k) => !(k in d));
if (missing.length) { console.log("MISSING:" + missing.join(",")); process.exit(0); }
if (!Array.isArray(d.sessions)) { console.log("SESSIONS-NOT-ARRAY"); process.exit(0); }
if (!Array.isArray(d.errors))   { console.log("ERRORS-NOT-ARRAY");   process.exit(0); }
const t = d.totals || {};
const by = t.by_type || t.types_by_name || {};
const summed = Object.values(by).reduce((a, n) => a + n, 0);
console.log([
  t.invocations === 3 ? "invocations-ok" : "invocations-mismatch",
  summed === t.invocations ? "rows-sum-ok" : "rows-sum-mismatch",
  Object.keys(by).length === t.types ? "types-ok" : "types-mismatch",
  d.sessions.length === t.sessions ? "sessions-ok" : "sessions-mismatch",
].join(" "));
' 2>&1)" || true
assert_eq "B9/schema-and-totals" \
    "invocations-ok rows-sum-ok types-ok sessions-ok" "$JSON_PROBE"

# The title-leak rule (Step 2-6) applies to the JSON view too. Run against R2, whose
# stub file actually carries $SECRET_TITLE, and scan it with --include-stubs so the
# title is genuinely in the data the tool read — otherwise "absent" would be vacuous.
run_cli --projects-root "$(native_path "$R2")" --all --include-stubs --json
JSON_TITLE_LEAK="absent"
grep -qF -- "$SECRET_TITLE" <<< "$CLI_OUT" && JSON_TITLE_LEAK="leaked"
assert_eq "B9/no-title-in-json" "0 absent" "$CLI_RC $JSON_TITLE_LEAK"

# `subagent_type` is attacker-shaped input, so the per-session `by_type` is built with
# Object.fromEntries() out of the same Map the totals use. Accumulating into a plain
# object instead would let `__proto__` walk the prototype chain (and `constructor` /
# `toString` collide with inherited properties), leaving the breakdown disagreeing with
# `invocations`. Both breakdowns are checked, because only the per-session one changed.
echo "== B9b: prototype-shaped subagent_type keys keep by_type consistent with totals =="
R13="$(new_root)"
mkdir -p "$R13/slug-one"
{ content "$SID_A"
  rec "$SID_A" __proto__   Task p1; rec "$SID_A" __proto__ Task p2
  rec "$SID_A" constructor Task c1; rec "$SID_A" toString  Task s1
  rec "$SID_A" normal      Task n1; } > "$R13/slug-one/$SID_A.jsonl"
run_cli --projects-root "$(native_path "$R13")" --all --json
PROTO_PROBE="$(J="$CLI_STDOUT" run_with_timeout 30 node -e '
let d; try { d = JSON.parse(process.env.J); } catch (e) { console.log("PARSE-FAIL"); process.exit(0); }
const s = (d.sessions || [])[0];
if (!s) { console.log("NO-SESSION"); process.exit(0); }
const sum = (o) => Object.values(o || {}).reduce((a, n) => a + n, 0);
console.log([
  "inv-" + d.totals.invocations,
  "types-" + d.totals.types,
  "session-sum-" + sum(s.by_type),
  "totals-sum-" + sum(d.totals.by_type),
  Object.keys(s.by_type || {}).sort().join("+"),
].join(" "));
' 2>&1)" || true
assert_eq "B9b/proto-keys-consistent" \
    "0 inv-5 types-4 session-sum-5 totals-sum-5 __proto__+constructor+normal+toString" \
    "$CLI_RC $PROTO_PROBE"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
