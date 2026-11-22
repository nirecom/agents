#!/usr/bin/env bash
# tests/bin/feature-530-notes-promotion-triage-flow/helpers.sh
# Tests: bin/worktree-notes-triage.js, bin/worktree-notes-triage/resolve.js, hooks/lib/worktree-notes-sections.js
# Tags: notes-promotion, worktree-notes, triage, cli, subprocess, TL2, scope:issue-specific
#
# Shared fixtures/helpers for the feature-530 notes-promotion triage-flow suite.
# Sourced by the sub-files — not a standalone runner.

set -u

_HELPERS_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
TRIAGE_BIN="$(nodepath "$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/worktree-notes-triage.js")"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# --------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md)
# --------------------------------------------------------------------------
TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/np-flow-$$")"
mkdir -p "$TMPD"
trap 'chmod -R u+rwx "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT

PLANS_DIR="$TMPD/plans"
mkdir -p "$PLANS_DIR"
# Dual-pin: pinning only one of the pair lets the supervisor emitter fall back to
# the developer's real ~/.workflow-plans and contaminate it.
export WORKFLOW_STATE_DIR="$(nodepath "$TMPD/workflow")"
export WORKFLOW_PLANS_DIR="$(nodepath "$PLANS_DIR")"
mkdir -p "$TMPD/workflow"
# The parent Claude Code session exports these; inheriting them would resolve the
# live session's state file.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# Neutral CWD: hooks and CLIs that shell out to `git rev-parse` must not resolve
# the real agents repo.
NEUTRAL_CWD="$TMPD/cwd"
mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

# Fixture main repo (for the backup-branch-dir branch).
TARGET_MAIN_ROOT="$TMPD/main-repo"
mkdir -p "$TARGET_MAIN_ROOT"
git -C "$TARGET_MAIN_ROOT" init -q 2>/dev/null
# Installed pre-commit hooks must not fire inside the fixture.
git -C "$TARGET_MAIN_ROOT" config core.hooksPath /dev/null 2>/dev/null
export CLAUDE_PROJECT_DIR="$(nodepath "$TARGET_MAIN_ROOT")"

NOTES_BODY='# Worktree Notes
Branch: feature/np
Created: 2026-08-01
Path: /tmp/np
WORKTREE_BASE_DIR: (default)
Session-ID: SIDPLACEHOLDER

## Gitignored files copied from main
- (none)

## BugsFound
- bug one
- bug two

## RelatedTasks
- related one
- related two

## NextTasks
- next one
- next two

## ManualReminders
- rotate the staging credential by hand

## History Notes
- (none)'

# All three triage sections empty — the NP-4 prefilter fixture.
NOTES_BODY_EMPTY=$'# Worktree Notes\nBranch: feature/np-empty\nCreated: 2026-08-01\nPath: /tmp/np\nWORKTREE_BASE_DIR: (default)\nSession-ID: SIDPLACEHOLDER\n\n## Gitignored files copied from main\n- (none)\n\n## BugsFound\n- (none)\n\n## RelatedTasks\n- (none)\n\n## NextTasks\n- (none)\n\n## ManualReminders\n- (none)\n\n## History Notes\n- (none)'

# write_triage_notes <dir> [session-id] -> node path. #2019: one entry per rule-table class —
# HIGH (auto-high), MEDIUM+instance and MEDIUM/other (final-list), test-failure (handoff),
# LOW / MEDIUM / not-defect on this-pr (dispose-in-pr), LOW / not-defect on other (discard).
write_triage_notes() {
    local o='<!-- pr-scope: other -->' t='<!-- pr-scope: this-pr -->'; mkdir -p "$1"
    printf '%s\n' '# Worktree Notes' 'Branch: feature/np' 'Created: 2026-08-01' "Session-ID: ${2:-sess-np}" '' '## BugsFound' \
        "- crash on save <!-- severity: high --> <!-- instance: saving a CRLF file drops its last line --> <!-- loc: a.js:3 --> $o" \
        "- slow index rebuild <!-- severity: medium --> <!-- instance: rebuild of 2k files takes 40s --> <!-- loc: b.js:9 --> $o" \
        "- flaky parser test <!-- severity: medium --> <!-- instance: parser.test fails 1 run in 5 --> <!-- test-failure --> $o" \
        '' '## RelatedTasks' "- tidy log wording <!-- severity: low --> $t" "- rename helper <!-- severity: medium --> $t" \
        "- maybe cache lookups <!-- severity: medium --> $o" '' '## NextTasks' "- typo in comment <!-- severity: low --> $o" \
        "- style preference <!-- severity: not-defect --> $o" "- intended behaviour <!-- severity: not-defect --> $t" \
        '' '## ManualReminders' '- rotate the staging credential by hand' '' '## History Notes' '- (none)' > "$1/WORKTREE_NOTES.md"
    nodepath "$1/WORKTREE_NOTES.md"
}
# A receiver that accepts every hand-off (finding-rules-triage.js runs FINDING_HANDOFF_BIN as `node <bin> <json>`).
HANDOFF_OK="$(nodepath "$TMPD/handoff-ok.js")"; printf '%s\n' 'process.stdout.write("handoff: accepted\n")' > "$TMPD/handoff-ok.js"

# write_notes <dir> [session-id] -> echoes the node-friendly notes path
write_notes() {
    local dir="$1" sid="${2:-sess-np}"
    mkdir -p "$dir"
    printf '%s\n' "${NOTES_BODY/SIDPLACEHOLDER/$sid}" > "$dir/WORKTREE_NOTES.md"
    nodepath "$dir/WORKTREE_NOTES.md"
}

# write_empty_notes <dir> [session-id] -> echoes the node-friendly notes path
write_empty_notes() {
    local dir="$1" sid="${2:-sess-np}"
    mkdir -p "$dir"
    printf '%s\n' "${NOTES_BODY_EMPTY/SIDPLACEHOLDER/$sid}" > "$dir/WORKTREE_NOTES.md"
    nodepath "$dir/WORKTREE_NOTES.md"
}

# Run `resolve` with the given args. Sets RESOLVE_OUT / RESOLVE_ERR / RESOLVE_RC.
RESOLVE_OUT=""; RESOLVE_ERR=""; RESOLVE_RC=0
resolve() {
    RESOLVE_OUT="$(run_with_timeout 30 node "$TRIAGE_BIN" resolve "$@" 2>"$TMPD/stderr.txt")"
    RESOLVE_RC=$?
    RESOLVE_ERR="$(cat "$TMPD/stderr.txt" 2>/dev/null)"
}

# jfield <json> <key> -> value, or the literal ERR / (absent)
jfield() {
    node -e '
      try {
        const j = JSON.parse(process.argv[1]);
        const v = j[process.argv[2]];
        process.stdout.write(v === undefined ? "(absent)" : String(v));
      } catch (e) { process.stdout.write("ERR"); }
    ' -- "$1" "$2" 2>/dev/null
}

# Canonical path form for comparison: absolute, forward slashes, case-folded on
# Windows. Without this a correct answer fails on separator or drive-case drift.
norm_path() {
    node -e '
      const p = require("path");
      const s = String(process.argv[1] || "");
      if (!s || s === "(absent)" || s === "ERR") { process.stdout.write(s); }
      else {
        const r = p.resolve(s).replace(/\\/g, "/");
        process.stdout.write(process.platform === "win32" ? r.toLowerCase() : r);
      }
    ' -- "$1" 2>/dev/null
}

# md5 of a file (node — no coreutils dependency on the md5 binary name).
file_md5() {
    node -e '
      const c = require("crypto"), fs = require("fs");
      try { process.stdout.write(c.createHash("md5").update(fs.readFileSync(process.argv[1])).digest("hex")); }
      catch (e) { process.stdout.write("NOFILE"); }
    ' -- "$1" 2>/dev/null
}

# Count *.tmp leftovers next to a notes file (atomic-write residue).
tmp_residue() {
    local dir; dir="$(dirname "$1")"
    ls "$dir"/*.tmp 2>/dev/null | grep -c '' || true
}

# json_len <json> -> array length, or ERR
json_len() {
    node -e 'try{process.stdout.write(String(Object.values(JSON.parse(process.argv[1])).flat().length))}catch(e){process.stdout.write("ERR")}' \
        -- "$1" 2>/dev/null
}

# json_at <json> <index> <key> -> value, or ERR
json_at() {
    node -e '
      try {
        const v = Object.values(JSON.parse(process.argv[1])).flat()[Number(process.argv[2])][process.argv[3]];
        process.stdout.write(String(v));
      } catch (e) { process.stdout.write("ERR"); }
    ' -- "$1" "$2" "$3" 2>/dev/null
}

# json_groups <json> -> "autoHigh=b|b;finalList=...;..." in contract order. finalList/overflow keep list
# order (loc-sorted); the other groups are sorted by body, since their order is not part of the contract.
json_groups() {
    node -e 'try{const g=JSON.parse(process.argv[1]);process.stdout.write(["autoHigh","finalList","overflow","disposeInPr","discard","testFailureHandoff"].map(k=>{const b=(Array.isArray(g[k])?g[k]:[]).map(e=>e.body);return k+"="+(/List|overflow/.test(k)?b:b.sort()).join("|")}).join(";"))}catch(e){process.stdout.write("ERR")}' -- "$1" 2>/dev/null
}
# group_rows <json> <group> -> one "lineNumber<TAB>body" line per entry of that group, in list order
group_rows() {
    node -e 'try{for(const e of JSON.parse(process.argv[1])[process.argv[2]]||[])console.log(e.lineNumber+"\t"+e.body)}catch(e){}' -- "$1" "$2" 2>/dev/null
}
