#!/usr/bin/env bash
# tests/feature-1611-append-only-archive-guard.sh
# Tests: hooks/block-history-direct.js, settings.json
# Tags: hook, settings, config, append-only, docs, scope:issue-specific, TL2
#
# Issue #1611 — append-only protection must cover the whole family (canonical
# docs/history.md + CHANGELOG.md and rotated archives under docs/history/*.md,
# changelog/*.md, docs/changelog/*.md) via both the tool-write and shell paths.
# T1-P asserts real-hook decisions; T1-R greps the hook's own `switch` and
# asserts settings.json registers every tool name it handles.
# TL3 gap: live dispatch and refusal surfacing — bin/check-verification-gate.sh.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_DIR/hooks/block-history-direct.js"
SETTINGS_JSON="$REPO_DIR/settings.json"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

if [ ! -f "$HOOK" ]; then
    fail "precondition" "hook not found at $HOOK"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# JSON-escape a raw string for embedding between double quotes.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Isolated workflow dir: the guard consults <workflowDir>/<sid>.workflow-off for the
# session override (#1725). Pinning CLAUDE_WORKFLOW_DIR to an empty temp dir and
# stripping the ambient session-identifying env vars keeps these block-expectations
# environment-independent — a real WORKFLOW_OFF marker in the developer's live session
# can never flip a verdict asserted here.
ISOLATED_WORKFLOW_DIR="$(mktemp -d)"
trap 'rm -rf "$ISOLATED_WORKFLOW_DIR"' EXIT
# Dual-pin (#1799): without WORKFLOW_PLANS_DIR the supervisor emitter still
# resolves the developer's real ~/.workflow-plans/ and appends there.
ISOLATED_PLANS_DIR="$ISOLATED_WORKFLOW_DIR/plans"
mkdir -p "$ISOLATED_PLANS_DIR"

# run_hook <stdin-json> → prints "approve" | "block" | "other"
run_hook() {
    local out
    out="$(printf '%s' "$1" | run_with_timeout 30 \
        env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_ENV_FILE \
        "CLAUDE_WORKFLOW_DIR=$ISOLATED_WORKFLOW_DIR" \
    "WORKFLOW_PLANS_DIR=$ISOLATED_PLANS_DIR" \
        node "$HOOK" 2>/dev/null)"
    case "$out" in
        *'"decision":"block"'*)   printf 'block' ;;
        *'"decision":"approve"'*) printf 'approve' ;;
        *)                        printf 'other' ;;
    esac
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$want got=$got"; fi
}

echo "=== T1-P/a: tool-write path (file_path) ==="

# name | tool | file_path | want
while IFS='|' read -r name tool fpath want; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed -e 's/^ *//' -e 's/ *$//')"
    tool="$(printf '%s' "$tool" | sed -e 's/^ *//' -e 's/ *$//')"
    fpath="$(printf '%s' "$fpath" | sed -e 's/^ *//' -e 's/ *$//')"
    want="$(printf '%s' "$want" | sed -e 's/^ *//' -e 's/ *$//')"
    stdin_json="{\"tool_name\":\"$(json_escape "$tool")\",\"tool_input\":{\"file_path\":\"$(json_escape "$fpath")\"}}"
    assert_eq "$name" "$want" "$(run_hook "$stdin_json")"
done <<'TABLE'
P01-archive-history-year   | Edit      | docs/history/2026.md         | block
P02-archive-history-index  | Write     | docs/history/index.md        | block
P03-archive-changelog-year | Edit      | changelog/2026.md            | block
P04-archive-docs-changelog | Write     | docs/changelog/2026.md       | block
P05-archive-multiedit      | MultiEdit | docs/history/2025.md         | block
P06-archive-editfiles      | editFiles | changelog/2025.md            | block
P07-abs-path-archive       | Edit      | C:/git/agents/docs/history/2026.md | block
P08-regression-canonical-h | Edit      | docs/history.md              | block
P09-regression-canonical-c | Write     | CHANGELOG.md                 | block
P10-case-insensitive-win   | Edit      | Docs/History/2026.md         | block
P11-case-insensitive-clog  | Edit      | ChangeLog/2026.MD            | block
P12-backslash-sep-archive  | Edit      | docs\history\2026.md         | block
P13-allow-rules-history    | Edit      | rules/docs/history.md        | approve
P14-allow-rules-changelog  | Edit      | rules/docs/changelog.md      | approve
P15-allow-architecture     | Edit      | docs/architecture.md         | approve
P16-allow-root-history      | Edit     | history.md                   | approve
P17-allow-history-dir-nonmd | Edit     | docs/history/notes.txt       | approve
P18-allow-unrelated-nested | Write     | src/history/2026.md          | approve
P22-dot-slash-prefix       | Edit      | ./docs/history/2026.md       | block
P23-dotdot-round-trip      | Edit      | docs/history/../history/2026.md | block
P24-dotdot-from-sibling    | Write     | docs/todo/../history/index.md   | block
P25-special-chars-in-name  | Edit      | docs/history/2026 (draft).md | block
P26-allow-deeper-history   | Edit      | docs/history/subdir/2026.md  | approve
P27-allow-deeper-changelog | Write     | changelog/subdir/2026.md     | approve
TABLE

echo ""
echo "=== T1-P/b: shell path (command) ==="
#
# S19 pins a KNOWN, accepted gap rather than a requirement: the hook inspects the
# command string only and cannot resolve a shell working directory, so a `cd` that
# makes the protected path relative is not detected. The plan scopes the shell
# predicate to the two path literals (`docs/history/*.md`, `changelog/*.md`);
# widening it to bare `history/2026.md` would over-block S18/P18-style paths.
# The guard is a guardrail against accidental direct edits, not a sandbox.

# name | tool | command | want
while IFS='|' read -r name tool cmd want; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed -e 's/^ *//' -e 's/ *$//')"
    tool="$(printf '%s' "$tool" | sed -e 's/^ *//' -e 's/ *$//')"
    cmd="$(printf '%s' "$cmd" | sed -e 's/^ *//' -e 's/ *$//')"
    want="$(printf '%s' "$want" | sed -e 's/^ *//' -e 's/ *$//')"
    stdin_json="{\"tool_name\":\"$(json_escape "$tool")\",\"tool_input\":{\"command\":\"$(json_escape "$cmd")\"}}"
    assert_eq "$name" "$want" "$(run_hook "$stdin_json")"
done <<'TABLE'
S01-append-archive       | Bash          | echo x >> docs/history/2026.md                    | block
S02-tee-changelog        | Bash          | tee changelog/2026.md < a.md                      | block
S03-cp-archive           | Bash          | cp a.md docs/history/2026.md                      | block
S04-append-canonical     | Bash          | echo x >> docs/history.md                         | block
S05-redirect-changelog   | Bash          | echo x > CHANGELOG.md                             | block
S06-mv-archive           | Bash          | mv a.md docs/history/index.md                     | block
S07-runInTerminal        | runInTerminal | echo x >> changelog/2026.md                       | block
S08-runCommands          | runCommands   | echo x >> docs/history/2026.md                    | block
S09-allow-doc-append     | Bash          | doc-append docs/history.md --category FEATURE --background b --changes c | approve
S10-allow-doc-rotate     | Bash          | uv run bin/doc-rotate.py docs/history.md          | approve
S11-allow-read-archive   | Bash          | cat docs/history/2026.md                          | approve
S12-allow-other-target   | Bash          | echo x >> docs/todo.md                            | approve
S13-double-quoted-path   | Bash          | echo x >> "docs/history/2026.md"                  | block
S14-single-quoted-path   | Bash          | echo x >> 'changelog/2026.md'                     | block
S15-dot-slash-prefix     | Bash          | echo x >> ./docs/history/2026.md                  | block
S16-special-chars-quoted | Bash          | echo x >> "docs/history/2026 (draft).md"          | block
S17-dotdot-round-trip    | Bash          | echo x >> docs/history/../history/2026.md         | block
S18-allow-deeper-subdir  | Bash          | echo x >> docs/history/subdir/2026.md             | approve
S19-known-gap-cwd-relative | Bash        | cd docs && echo x >> history/2026.md              | approve
TABLE

echo ""
echo "=== T1-P/c: fail-open ==="

got="$(printf '%s' 'not json at all {{{' | run_with_timeout 30 \
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_ENV_FILE \
    "CLAUDE_WORKFLOW_DIR=$ISOLATED_WORKFLOW_DIR" \
    "WORKFLOW_PLANS_DIR=$ISOLATED_PLANS_DIR" \
    node "$HOOK" 2>/dev/null | grep -c '"decision":"approve"' || true)"
assert_eq "P19-invalid-json-approves" "1" "$got"

assert_eq "P20-unknown-tool-approves" "approve" \
    "$(run_hook '{"tool_name":"WebFetch","tool_input":{"file_path":"docs/history/2026.md"}}')"

assert_eq "P21-missing-tool-input-approves" "approve" \
    "$(run_hook '{"tool_name":"Edit"}')"

echo ""
echo "=== T1-A: attack fixture — the protected archive must stay byte-identical ==="
#
# Verdict-only assertions cannot prove that nothing was written. Here a real
# sentinel archive is created and the guard is run as the gate in front of the
# write: when (and only when) the verdict is not "block", the write is actually
# performed. A false approve therefore mutates the file and the hash assertion
# fails — the assertion is not vacuous.

ATTACK_DIR="$(mktemp -d)"
trap 'rm -rf "$ATTACK_DIR" "$ISOLATED_WORKFLOW_DIR"' EXIT
mkdir -p "$ATTACK_DIR/docs/history"
SENTINEL="$ATTACK_DIR/docs/history/2026.md"
printf '### Sentinel entry (2026-01-01, abc1234)\nBackground: untouched.\n' > "$SENTINEL"
SENTINEL_HASH_BEFORE="$(md5sum "$SENTINEL" | cut -d' ' -f1)"

# gated_write <verdict> — perform the append only if the guard did not block.
gated_write() {
    [ "$1" = "block" ] || printf 'PWNED by an un-blocked write\n' >> "$SENTINEL"
}

A01_VERDICT="$(run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(json_escape "$SENTINEL")\"}}")"
gated_write "$A01_VERDICT"
assert_eq "A01-tool-write-blocked" "block" "$A01_VERDICT"
assert_eq "A01b-archive-unchanged" "$SENTINEL_HASH_BEFORE" "$(md5sum "$SENTINEL" | cut -d' ' -f1)"

A02_VERDICT="$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo pwned >> $(json_escape "$SENTINEL")\"}}")"
gated_write "$A02_VERDICT"
assert_eq "A02-shell-write-blocked" "block" "$A02_VERDICT"
assert_eq "A02b-archive-unchanged" "$SENTINEL_HASH_BEFORE" "$(md5sum "$SENTINEL" | cut -d' ' -f1)"

A03_VERDICT="$(run_hook "{\"tool_name\":\"runCommands\",\"tool_input\":{\"command\":\"tee $(json_escape "$SENTINEL") < /dev/null\"}}")"
gated_write "$A03_VERDICT"
assert_eq "A03-runcommands-write-blocked" "block" "$A03_VERDICT"
assert_eq "A03b-archive-unchanged" "$SENTINEL_HASH_BEFORE" "$(md5sum "$SENTINEL" | cut -d' ' -f1)"

echo ""
echo "=== T1-R: settings.json registration parity ==="

# Tool names handled by the hook's own switch — grepped from source, not hardcoded.
HOOK_TOOLS="$(grep -oE '^[[:space:]]*case "[A-Za-z]+":' "$HOOK" | sed -E 's/.*case "([A-Za-z]+)":.*/\1/' | sort -u)"

if [ -z "$HOOK_TOOLS" ]; then
    fail "R01-hook-tool-names-extracted" "no 'case \"<Tool>\":' labels found in $HOOK"
else
    pass "R01-hook-tool-names-extracted ($(echo $HOOK_TOOLS | tr '\n' ' '))"
fi

# Matchers of every PreToolUse group that registers block-history-direct.js.
SETTINGS_MATCHERS="$(node -e '
const fs = require("fs");
try {
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const groups = (s.hooks && s.hooks.PreToolUse) || [];
  const out = new Set();
  for (const g of groups) {
    const cmds = (g.hooks || []).map((h) => h && h.command || "").join(" ");
    if (!cmds.includes("block-history-direct.js")) continue;
    for (const tok of String(g.matcher || "").split("|")) {
      const t = tok.trim();
      if (t) out.add(t);
    }
  }
  process.stdout.write([...out].sort().join("\n"));
} catch (e) { process.exit(1); }
' "$SETTINGS_JSON" 2>/dev/null)"

if [ -z "$SETTINGS_MATCHERS" ]; then
    fail "R02-settings-registration-found" "block-history-direct.js is not registered in any settings.json PreToolUse group (or settings.json unreadable)"
else
    pass "R02-settings-registration-found ($(echo $SETTINGS_MATCHERS | tr '\n' ' '))"
fi

MISSING=""
while IFS= read -r t; do
    [ -z "$t" ] && continue
    if ! printf '%s\n' "$SETTINGS_MATCHERS" | grep -qxF "$t"; then
        MISSING="${MISSING:+$MISSING }$t"
    fi
done <<< "$HOOK_TOOLS"

if [ -z "$MISSING" ] && [ -n "$HOOK_TOOLS" ]; then
    pass "R03-matcher-covers-every-switch-tool"
else
    fail "R03-matcher-covers-every-switch-tool" "tool names handled by the hook but absent from its PreToolUse matchers: ${MISSING:-<hook tool list empty>}"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
