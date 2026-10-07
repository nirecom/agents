#!/usr/bin/env bash
# Tests: hooks/lib/supervisor-codex-input.js, hooks/lib/supervisor-codex-input/
# Tags: TL1, supervisor, codex-input, transcript-cursor, scope:issue-specific, pwsh-not-required, security, path-traversal
# #2475 supervisor codex input module: rules table, transcript cursor, render.
# Dispatcher for feature-2475-supervisor-codex-input/ (fragments carry no frontmatter).
# RED until write-code creates the module; assumed API is listed in each fragment.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

SCI_FRAG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2475-supervisor-codex-input"
SCI_TMP="$(make_tmp)"
trap 'rm -rf "$SCI_TMP"' EXIT
harness_isolate "$SCI_TMP"
mkdir -p "$SCI_TMP/transcripts-empty" "$SCI_TMP/proj"
export CLAUDE_TRANSCRIPT_BASE_DIR="$SCI_TMP/transcripts-empty"
PLANS="$WORKFLOW_PLANS_DIR"
cd "$SCI_TMP" || exit 1

SCI_CLI="$(np "$AGENTS_DIR/hooks/lib/supervisor-codex-input.js")"
SCI_RULES="$(np "$AGENTS_DIR/hooks/lib/supervisor-codex-input/rules.js")"
SCI_ASSEMBLE="$(np "$AGENTS_DIR/hooks/lib/supervisor-codex-input/assemble.js")"
SCI_SCHEMA="$(np "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js")"
SCI_WRITER="$(np "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js")"

cat > "$SCI_TMP/jfield.js" <<'JS'
'use strict';
const fs = require('fs');
const [file, dotted] = process.argv.slice(2);
let v;
try { v = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { process.stdout.write('PARSE_ERROR'); process.exit(0); }
for (const k of (dotted || '').split('.').filter(Boolean)) v = (v === null || v === undefined) ? undefined : v[k];
process.stdout.write(v === undefined ? 'undefined' : (typeof v === 'string' ? v : JSON.stringify(v)));
JS

cat > "$SCI_TMP/mkstate.js" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const [schemaPath, writerPath, sid, mode, tpath, line, lastUuid] = process.argv.slice(2);
const { createEmptyState } = require(schemaPath);
const { getStatePath } = require(writerPath);
const st = createEmptyState(sid);
if (mode === 'alert' || mode === 'audit') {
  st[mode].transcript_cursor = { transcript_path: tpath, line: Number(line),
    last_uuid: lastUuid === 'null' ? null : lastUuid, updated_at: '2026-01-01T00:00:00Z' };
}
const p = getStatePath(sid);
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(st, null, 2));
JS

# sci_run <out> <args...> — run the CLI; sets SCI_RC, SCI_STDOUT, SCI_STDERR.
sci_run() {
  local out="$1"; shift
  SCI_STDOUT="$(run_with_timeout 30 node "$SCI_CLI" "$@" --out "$out" 2>"$SCI_TMP/stderr.txt")"
  SCI_RC=$?
  SCI_STDERR="$(cat "$SCI_TMP/stderr.txt" 2>/dev/null)"
}

# sci_block <file> <NAME> — lines strictly between [NAME START] and [NAME END].
sci_block() {
  awk -v s="[$2 START]" -v e="[$2 END]" '$0==s{f=1;next} $0==e{f=0} f' "$1" 2>/dev/null
}

# sci_header <file> — lines between [SUPERVISOR INPUT HEADER] and [HANDOFF START].
sci_header() {
  awk '$0=="[SUPERVISOR INPUT HEADER]"{f=1;next} $0=="[HANDOFF START]"{f=0} f' "$1" 2>/dev/null
}

# sci_next_field <field> — a field of the CURSOR_NEXT json in $SCI_STDOUT.
sci_next_field() {
  printf '%s\n' "$SCI_STDOUT" | sed -n 's/^CURSOR_NEXT: //p' > "$SCI_TMP/next.json"
  node "$(np "$SCI_TMP/jfield.js")" "$(np "$SCI_TMP/next.json")" "$1"
}

# sci_mkstate <sid> <alert|audit|none> <transcript-path> <line> <last_uuid|null>
sci_mkstate() {
  run_with_timeout 20 node "$(np "$SCI_TMP/mkstate.js")" "$SCI_SCHEMA" "$SCI_WRITER" "$@"
}

# sci_msys_path <path> — genuine /c/<rest> drive form (cygpath -u yields /tmp/... for the tmp dir).
sci_msys_path() {
  local m; m="$(cygpath -m "$1")"
  case "$m" in
    [A-Za-z]:/*) printf '/%s%s\n' "$(printf '%s' "${m%%:*}" | tr '[:upper:]' '[:lower:]')" "${m#?:}" ;;
    *) printf '%s\n' "$m" ;;
  esac
}

# sci_run_msys <args...> — run the CLI with MSYS argv conversion off, so a /c/... argument
#   reaches node verbatim. MSYS_NO_PATHCONV also stops env conversion, so the fixture
#   dirs are handed over in native form explicitly (else node reads /tmp/... as C:\tmp).
sci_run_msys() {
  WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")" WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$CLAUDE_TRANSCRIPT_BASE_DIR")" HOME="$(np "$HOME")" \
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' run_with_timeout 30 node "$SCI_CLI" "$@"
}

sci_has() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing '$3' in: $(printf '%.300s' "$2")" ;; esac
}
sci_lacks() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) fail "$1" "unexpected '$3' in: $(printf '%.300s' "$2")" ;; *) pass "$1" ;; esac
}
sci_match() { # <label> <haystack> <extended-regex>
  if printf '%s\n' "$2" | grep -Eq -- "$3"; then pass "$1"; else fail "$1" "no line matches /$3/ in: $(printf '%.300s' "$2")"; fi
}
sci_eq() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$3") got=$(printf '%q' "$2")"; fi
}

echo "=== #2475 supervisor codex input ==="

case_begin "rules-table" "hooks/lib/supervisor-codex-input/rules.js"
# shellcheck source=./feature-2475-supervisor-codex-input/rules.sh
. "$SCI_FRAG/rules.sh"
case_end

case_begin "transcript-cursor" "hooks/lib/supervisor-codex-input/cursor.js"
# shellcheck source=./feature-2475-supervisor-codex-input/cursor.sh
. "$SCI_FRAG/cursor.sh"
case_end

case_begin "assemble-render" "hooks/lib/supervisor-codex-input/assemble.js"
# shellcheck source=./feature-2475-supervisor-codex-input/render.sh
. "$SCI_FRAG/render.sh"
case_end

case_begin "wsid-validation" "hooks/lib/supervisor-codex-input/cli.js"
# shellcheck source=./feature-2475-supervisor-codex-input/wsid.sh
. "$SCI_FRAG/wsid.sh"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
