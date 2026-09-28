#!/usr/bin/env bash
# tests/hooks/feature-2388-block-case-markers.sh
# Tests: hooks/block-case-markers.js, settings.json, hooks/lib/precommit-tests-frontmatter.sh
# Tags: TL2, hooks, pretooluse, edit-time, case-markers, registration, dotenv, scope:issue-specific
# Issue #2388 Step 5: the Edit-time case-marker gate for NEW .sh test entrypoints;
# pre-commit is the backstop for what it cannot rebuild (editFiles, NotebookEdit).
# Cases live in tests/hooks/feature-2388-block-case-markers/*.sh; marker text only in heredocs.
# TL3 gap: real Claude Code routing into the hook (mitigation: WORKFLOW_USER_VERIFIED).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

HOOK="$AGENTS_DIR/hooks/block-case-markers.js"
SETTINGS_JSON="$AGENTS_DIR/settings.json"
PRECOMMIT_LIB="$AGENTS_DIR/hooks/lib/precommit-tests-frontmatter.sh"
CASE_DIR="$AGENTS_DIR/tests/hooks/feature-2388-block-case-markers"

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

# The hook must resolve paths from the payload, never from its own cwd.
NEUTRAL_CWD="$TMPBASE/neutral"
mkdir -p "$NEUTRAL_CWD"

# Empty fixture config dir: the hook must not see the developer's real one.
CFG_DIR="$TMPBASE/agents-config"
mkdir -p "$CFG_DIR"
CFG_DIR_M="$(np "$CFG_DIR")"

# Payload builder (feature-1894 shape):
#   node payload.js <tool_name> <cwd|-> <file_path|-> [key=value ...]
# `@<path>` reads a file, `e<N>.<key>=` fills edits[N], `!<key>=` is top-level.
PAYLOAD_JS="$TMPBASE/payload.js"
cat > "$PAYLOAD_JS" <<'PAYLOAD'
const fs = require("fs");
const [, , tool, cwd, filePath, ...rest] = process.argv;
const payload = {};
if (tool !== "-") payload.tool_name = tool;
if (cwd !== "-") payload.cwd = cwd;
const ti = {};
const edits = [];
for (const raw of rest) {
  const i = raw.indexOf("=");
  if (i < 0) continue;
  const key = raw.slice(0, i);
  let val = raw.slice(i + 1);
  if (val.startsWith("@")) val = fs.readFileSync(val.slice(1), "utf8");
  if (key.startsWith("!")) { payload[key.slice(1)] = val; continue; }
  const m = key.match(/^e(\d+)\.(.+)$/);
  if (m) {
    const n = Number(m[1]);
    while (edits.length <= n) edits.push({});
    edits[n][m[2]] = m[2] === "replace_all" ? val === "true" : val;
    continue;
  }
  ti[key] = key === "replace_all" ? val === "true" : val;
}
if (filePath !== "-") ti.file_path = filePath;
if (edits.length) ti.edits = edits;
payload.tool_input = ti;
process.stdout.write(JSON.stringify(payload));
PAYLOAD
PAYLOAD_JS_M="$(np "$PAYLOAD_JS")"
PAYLOAD_FILE="$TMPBASE/payload.json"
mkpayload() {
  node "$PAYLOAD_JS_M" "$@" > "$PAYLOAD_FILE"
}

# Hook runner. HK_ENV_RESET scrubs every name the hook could pick up from the
# developer's session; extra VAR=VAL args become child variables.
HK_ENV_RESET=(-u CLAUDE_PROJECT_DIR -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID)
HK_HOOK="$HOOK"
HK_OUT=""
HK_ERR=""
HK_RC=0
HK_DECISION="none"
HK_REASON=""
REASON_JS="$TMPBASE/reason.js"
cat > "$REASON_JS" <<'REASONJS'
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  process.stdout.write(typeof o.reason === "string" ? o.reason : "");
} catch (e) {
  process.stdout.write("");
}
REASONJS
REASON_JS_M="$(np "$REASON_JS")"

hk_run() {
  local outfile="$TMPBASE/hook.out"
  local errfile="$TMPBASE/hook.err"
  local hook_m
  hook_m="$(np "$HK_HOOK")"
  HK_RC=0
  (cd "$NEUTRAL_CWD" || exit 99; run_with_timeout 30 env "${HK_ENV_RESET[@]}" "AGENTS_CONFIG_DIR=$CFG_DIR_M" "$@" node "$hook_m" < "$PAYLOAD_FILE" > "$outfile" 2> "$errfile") || HK_RC=$?
  HK_OUT="$(cat "$outfile" 2>/dev/null)"
  HK_ERR="$(cat "$errfile" 2>/dev/null)"
  HK_REASON="$(node "$REASON_JS_M" "$(np "$outfile")")"
  local squashed="${HK_OUT//[[:space:]]/}"
  case "$squashed" in
    *'"decision":"block"'*) HK_DECISION="block" ;;
    *'"decision":"approve"'*) HK_DECISION="approve" ;;
    *) HK_DECISION="none" ;;
  esac
}

# assert_decision <label> <want> — raw output in the detail on mismatch.
assert_decision() {
  if [ "$HK_DECISION" = "$2" ]; then
    pass "$1: $2"
  else
    fail "$1" "want=$2 got=$HK_DECISION rc=$HK_RC out=$HK_OUT err=$HK_ERR"
  fi
}
# assert_reason_has / assert_reason_lacks <label> <fixed-string>
assert_reason_has() {
  if printf '%s' "$HK_REASON" | grep -qF -- "$2"; then
    pass "$1: reason has $2"
  else
    fail "$1" "reason lacks $2: $HK_REASON"
  fi
}
assert_reason_lacks() {
  if printf '%s' "$HK_REASON" | grep -qF -- "$2"; then
    fail "$1" "reason unexpectedly has $2: $HK_REASON"
  else
    pass "$1: reason lacks $2"
  fi
}

# snap_file <path> -> "absent" or "present:<cksum>"; the hook must never write.
snap_file() {
  if [ -e "$1" ]; then
    printf 'present:%s' "$(cksum < "$1")"
  else
    printf 'absent'
  fi
}

# Fixture bodies (marker text only inside heredoc bodies).
BODIES="$TMPBASE/bodies"
mkdir -p "$BODIES"
cat > "$BODIES/missing.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
echo no markers
EOF
cat > "$BODIES/malformed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
  case_begin "a" "bin/a.sh"
  case_end
EOF
cat > "$BODIES/conforming.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
case_begin "a" "bin/a.sh"
echo a
case_end
case_begin "b" "bin/b.sh"
echo b
case_end
EOF
cat > "$BODIES/uncertain.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
node -e '
for (const a of [1]) console.log(a)
'
case_begin "a" "bin/a.sh"
case_end
case_begin "b" "bin/b.sh"
case_end
EOF
cat > "$BODIES/single-path.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
echo one path needs no markers
EOF
# Edit strings: the first marker line, and the same line indented.
cat > "$BODIES/old-begin-a.txt" <<'EOF'
case_begin "a" "bin/a.sh"
EOF
cat > "$BODIES/new-begin-a-indented.txt" <<'EOF'
  case_begin "a" "bin/a.sh"
EOF

# Fixture repos: REPO has tests/lib/harness.sh and one committed test entrypoint;
# REPO_NH has no harness (the gate does not apply there).
fixture_repo() {
  harness_git_init "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" config core.autocrlf false
  mkdir -p "$1/tests/hooks" "$1/tests/lib"
  printf 'readme\n' > "$1/README.md"
  cp "$BODIES/conforming.sh" "$1/tests/hooks/existing.sh"
  if [ "${2:-}" != "noharness" ]; then
    printf '# harness stub\n' > "$1/tests/lib/harness.sh"
  fi
  git -C "$1" add -A
  git -C "$1" commit -q -m init
}
REPO="$TMPBASE/repo"
REPO_NH="$TMPBASE/repo-nh"
fixture_repo "$REPO"
fixture_repo "$REPO_NH" noharness
REPO_M="$(np "$REPO")"
REPO_NH_M="$(np "$REPO_NH")"

# untracked <rel> [body] — an on-disk, never-committed file in REPO (a NEW file
# for the gate); echoes the payload-shaped absolute path.
untracked() {
  mkdir -p "$(dirname "$REPO/$1")"
  cp "$BODIES/${2:-conforming}.sh" "$REPO/$1"
  printf '%s' "$REPO_M/$1"
}

if [ ! -f "$HOOK" ]; then
  echo "NOTE: hooks/block-case-markers.js does not exist yet — hook cases are expected to fail (#2388)."
fi

# Passthrough: tools whose post-edit content cannot be rebuilt are approved
# (pre-commit catches them); non-edit tools are none of this hook's business.
case_begin "editfiles-approves" "hooks/block-case-markers.js"
mkpayload editFiles "$REPO_M" "$REPO_M/tests/hooks/pt-editfiles.sh" "content=@$BODIES/missing.sh"
hk_run
assert_decision "editfiles-approves" approve
assert_eq "$HK_RC" "0"
case_end

case_begin "notebookedit-approves" "hooks/block-case-markers.js"
mkpayload NotebookEdit "$REPO_M" "$REPO_M/tests/hooks/pt-notebook.sh" "new_source=@$BODIES/missing.sh"
hk_run
assert_decision "notebookedit-approves" approve
case_end

case_begin "bash-tool-approves" "hooks/block-case-markers.js"
mkpayload Bash "$REPO_M" - "command=echo hi"
hk_run
assert_decision "bash-tool-approves" approve
case_end

# shellcheck source=feature-2388-block-case-markers/decision.sh
. "$CASE_DIR/decision.sh"
# shellcheck source=feature-2388-block-case-markers/scope.sh
. "$CASE_DIR/scope.sh"
# shellcheck source=feature-2388-block-case-markers/registration.sh
. "$CASE_DIR/registration.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
