#!/usr/bin/env bash
# tests/feature-2063-render-issue-comments/_lib.sh
# Tests: bin/workflow/render-issue-comments, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/write-context.js
# Tags: workflow-init, issue-comments, cli, contract, fail-closed, sentinel-strip, tl2, scope:common
# Source from sibling group files: . "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# The driver harness is reused rather than re-mocked: P2 needs a REAL Path A
# context.md, and its gh/wip mocks plus pass/fail/finish are that harness's job.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/feature-workflow-init-driver/_lib.sh"

CLI="$AGENTS_DIR/bin/workflow/render-issue-comments"
WORK="$ROOT_TMP/ric-work"
mkdir -p "$WORK/plans" "$WORK/state"

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin, drop live ids.
export CLAUDE_WORKFLOW_DIR="$WORK/state"
export WORKFLOW_PLANS_DIR="$WORK/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- CLI invocation -----------------------------------------------------------
# A missing binary is reported as its own outcome, never as node's MODULE_NOT_FOUND
# exit 1 — otherwise every "must exit 1" assertion would pass while the subject
# does not exist at all.
CLI_OUT=""; CLI_ERR=""; CLI_RC=0
run_cli() {
    CLI_RC=0
    if [ ! -f "$CLI" ]; then
        CLI_OUT=""
        CLI_ERR="CLI_MISSING: bin/workflow/render-issue-comments not implemented"
        CLI_RC=127
        return 0
    fi
    CLI_OUT="$("$TIMEOUT_WRAP" 30 node "$CLI" "$@" 2>"$WORK/cli-err")" || CLI_RC=$?
    CLI_ERR="$(cat "$WORK/cli-err" 2>/dev/null || true)"
    return 0
}

# --- fixtures -----------------------------------------------------------------
healthy_ckpt() {  # <path> <N> <comments-raw-json>
    printf '{"version":3,"session_id":"ric","phase":"write-context","ask_id":null,"state":{"issues":[%s],"issue_json_cache":{"%s":{"number":%s,"title":"Fixture issue","body":"Fixture body","labels":[],"state":"OPEN","createdAt":"2026-07-01T00:00:00Z","comments":%s}}}}' \
        "$2" "$2" "$2" "$3" > "$1"
}
nocomments_ckpt() {  # <path> <N> — a current-version entry that simply lacks `comments`
    printf '{"version":3,"session_id":"ric","phase":"write-context","ask_id":null,"state":{"issues":[%s],"issue_json_cache":{"%s":{"number":%s,"title":"Fixture issue","body":"Fixture body","labels":[],"state":"OPEN","createdAt":"2026-07-01T00:00:00Z"}}}}' \
        "$2" "$2" "$2" > "$1"
}
raw_ckpt() { printf '%s' "$2" > "$1"; }  # <path> <raw-json-text>

TWO_COMMENTS='[{"author":{"login":"alice"},"body":"first remark","createdAt":"2026-07-02T00:00:00Z"},{"author":{"login":"bob"},"body":"second remark","createdAt":"2026-07-03T00:00:00Z"}]'
BROKEN_ELEMS='[null,{"author":null,"body":123,"createdAt":{}},{"author":{"login":"alice"},"body":"ok","createdAt":"2026-01-01T00:00:00Z"}]'
META_ONLY_BROKEN='[{"author":{"login":"alice"},"body":"ok","createdAt":123},{"author":42,"body":"ok2","createdAt":"2026-01-01T00:00:00Z"},{"author":{"login":"bob"},"body":456,"createdAt":"2026-01-02T00:00:00Z"}]'

# --- assertions ---------------------------------------------------------------
assert_eq() {  # <label> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want '$2' got '$3'"; fi
}
assert_rc() {  # <label> <want-rc>
    if [ "$CLI_RC" = "$2" ]; then pass "$1"; else fail "$1: want rc=$2 got rc=$CLI_RC (err='$CLI_ERR')"; fi
}
assert_out_has() {  # <label> <fixed-string>
    case "$CLI_OUT" in *"$2"*) pass "$1" ;; *) fail "$1: '$2' absent from stdout: '$(printf '%s' "$CLI_OUT" | head -c 300)'" ;; esac
}
assert_out_lacks() {  # <label> <fixed-string>
    case "$CLI_OUT" in *"$2"*) fail "$1: '$2' present in stdout" ;; *) pass "$1" ;; esac
}
assert_out_empty() {  # <label>
    if [ -z "$CLI_OUT" ]; then pass "$1"; else fail "$1: stdout not empty: '$(printf '%s' "$CLI_OUT" | head -c 300)'"; fi
}
assert_err_has() {  # <label> <fixed-string>
    case "$CLI_ERR" in *"$2"*) pass "$1" ;; *) fail "$1: '$2' absent from stderr: '$(printf '%s' "$CLI_ERR" | head -c 300)'" ;; esac
}
# A stack trace on stderr breaks BOTH promises at once: the deterministic single
# reason-token line, and the host paths it would print into a transcript.
assert_no_stack() {  # <label>
    if printf '%s' "$CLI_ERR" | grep -qE 'Cannot read properties|TypeError|^ +at |at Object\.'; then
        fail "$1: stack-trace residue on stderr: '$(printf '%s' "$CLI_ERR" | head -c 300)'"
    else
        pass "$1"
    fi
}
assert_err_only_line() {  # <label> <exact-line>
    local n
    n="$(printf '%s' "$CLI_ERR" | grep -c . || true)"
    if [ "$CLI_ERR" = "$2" ] && [ "$n" = "1" ]; then
        pass "$1"
    else
        fail "$1: want exactly one line '$2', got ($n line(s)) '$(printf '%s' "$CLI_ERR" | head -c 300)'"
    fi
}
# A host path can be leaked inside a single well-formed line just as easily as in a
# stack frame, so the leak check is separate from assert_err_only_line/assert_no_stack.
# Shared by the exit-3 tokens (P22/P27) and the exit-1 argument errors (P8).
assert_no_leak() {  # <label> <needle-that-must-not-appear>
    case "$CLI_ERR" in
        *"$2"*) fail "$1: stderr leaked '$2': '$(printf '%s' "$CLI_ERR" | head -c 200)'" ;;
        *) pass "$1" ;;
    esac
}
assert_err_one_line() {  # <label> — one non-empty line on stderr, whatever it says
    local n
    n="$(printf '%s' "$CLI_ERR" | grep -c . || true)"
    if [ "$n" = "1" ]; then pass "$1"; else fail "$1: want exactly 1 non-empty stderr line, got $n: '$(printf '%s' "$CLI_ERR" | head -c 300)'"; fi
}

# --- shared helpers for P17-P24 -------------------------------------------------
out_to_file() { printf '%s\n' "$CLI_OUT" > "$1"; }

# Every rendered line must be one of: the section heading, a `### Comment N — `
# header, blank, or blockquoted. Anything else is untrusted third-party text sitting
# at document level, which is exactly the structural boundary P17/P18 defend.
# "Blockquoted" is `> text` or a bare `>` (the form a blank body line takes) and
# nothing else: a bare `^>` predicate would also accept `>## Forged`, which is a
# document-level line as far as no Markdown reader is concerned. The split covers every
# Unicode line terminator, not just LF: U+0085/U+2028/U+2029 end a line for a Markdown
# reader, so a `\n`-only split would call a line "quoted" that renders as two.
unquoted_lines() {  # <file> — prints offending lines joined by ';'
    node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split(/\r\n|[\n\r\u0085\u2028\u2029]/);
const bad = lines.filter((l, i) => {
  if (i === 0 && l === "## Issue comments") return false;
  if (l === "") return false;
  if (/^### Comment \d+ — /.test(l)) return false;
  return !/^>( |$)/.test(l);
});
process.stdout.write(bad.join(";"));
' "$1"
}
count_re() {  # <file> <ERE>
    grep -Ec -- "$2" "$1" 2>/dev/null || true
}
# Nothing rendered means every "must occur 0 times" assertion below would pass without
# the subject ever having run — the exact false-green C7 was raised about. An empty
# capture is therefore an error in its own right, never a satisfied count.
rendered_something() {  # <file>
    [ -s "$1" ] || return 1
    [ -n "$(tr -d '\n' < "$1")" ] || return 1
    return 0
}
assert_count_re() {  # <label> <file> <ERE> <want>
    local got
    if ! rendered_something "$2"; then
        fail "$1: nothing was rendered — the count assertion is unfalsifiable"
        return
    fi
    got="$(count_re "$2" "$3")"
    if [ "$got" = "$4" ]; then pass "$1"; else fail "$1: want $4 line(s) matching /$3/, got $got"; fi
}
assert_all_quoted() {  # <label> <file>
    local bad
    if ! rendered_something "$2"; then
        fail "$1: nothing was rendered — the blockquote boundary is unfalsifiable"
        return
    fi
    bad="$(unquoted_lines "$2")"
    if [ -z "$bad" ]; then pass "$1"; else fail "$1: untrusted text escaped the blockquote boundary: '$bad'"; fi
}

