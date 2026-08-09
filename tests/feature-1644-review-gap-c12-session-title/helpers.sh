# shellcheck shell=bash
# Tests: hooks/lib/session-title.js
# Tags: tl2, workflow, session-title, jsonl, scope:issue-specific, pwsh-not-required
# Shared fixtures + probe helpers for tests/feature-1644-review-gap-c12-session-title.sh.
# Sourced by the dispatcher — not a standalone runner.

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
ST_MODULE_N="$AGENTS_DIR_N/hooks/lib/session-title.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }

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
PLANS_DIR_N="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
# The library's subagent guard keys on this; the parent Claude Code session may
# already export it. Unset here, set explicitly in the guard cases.
unset CLAUDE_CODE_CHILD_SESSION

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
CWD_ARG_N="$(nrm "$FIXTURE_REPO")"
NEUTRAL_CWD="$TMPDIR_BASE/neutral"; mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

JSONL_DIR="$TMPDIR_BASE/jsonl"; mkdir -p "$JSONL_DIR"

# --- probe -------------------------------------------------------------------
# ST_CALL is a JS statement evaluated with `m` bound to the library.
PROBE="$TMPDIR_BASE/st-probe.js"
cat > "$PROBE" <<'EOF'
const m = require(process.env.ST_MODULE);
try {
  eval(process.env.ST_CALL);
} catch (e) {
  process.stdout.write("THREW: " + e.message);
  process.exit(3);
}
EOF

# call <jsonl-file-bash> <js-statement>
call() {
  local jsonl="$1"; shift
  ST_MODULE="$ST_MODULE_N" ST_CALL="$1" CLAUDE_SESSION_JSONL_PATH="$(nrm "$jsonl")" \
    run_with_timeout node "$PROBE" 2>/dev/null
}

# last_title <jsonl-file-bash> <sid> -- most recent customTitle, or "<none>".
last_title() {
  node -e '
    const fs=require("fs");
    let out="<none>";
    try{
      const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(l=>l.trim());
      for(let i=lines.length-1;i>=0;i--){
        try{
          const r=JSON.parse(lines[i]);
          if(r.type==="custom-title"&&r.sessionId===process.argv[2]&&typeof r.customTitle==="string"){out=r.customTitle;break;}
        }catch(_){}
      }
    }catch(_){}
    process.stdout.write(out);
  ' "$(nrm "$1")" "$2" 2>/dev/null
}

title_records() {  # <jsonl-file-bash> -- count of custom-title records
  # grep -c exits 1 on zero matches; capture the count and normalize rather
  # than `|| echo 0`, which would emit BOTH "0" lines.
  local n
  n="$(grep -c '"type":"custom-title"' "$1" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

write_intent() { printf '%s' "$2" > "$PLANS_DIR/${1}-intent.md"; }
