# Edit time: hooks/block-case-markers.js run as the command settings.json registers for it,
# as a child process fed a tool payload on stdin (#2411). Sourced by
# tests/hooks/feature-2411-gate-integration.sh.
# shellcheck shell=bash

echo ""
echo "=== edit: the registered hook command ==="

EDIT_JS="$TMPBASE/edit.js"
cat > "$EDIT_JS" <<'EDITJS'
// reg <settings.json> <name>: "<matcher>\t<type>\t<command>" per PreToolUse hook naming <name>.
// payload <tool> <cwd> <file_path> <body file>: the tool payload on stdout.
// verdict <hook stdout file>: the decision on line 1, the reason after it.
const fs = require("fs");
const [, , mode, a, b, c, d] = process.argv;
if (mode === "reg") {
  const s = JSON.parse(fs.readFileSync(a, "utf8"));
  for (const entry of (s.hooks && s.hooks.PreToolUse) || []) {
    for (const h of entry.hooks || []) {
      if (typeof h.command === "string" && h.command.includes(b)) {
        process.stdout.write([entry.matcher || "", h.type || "", h.command].join("\t") + "\n");
      }
    }
  }
} else if (mode === "payload") {
  process.stdout.write(JSON.stringify({
    tool_name: a,
    cwd: b,
    tool_input: { file_path: c, content: fs.readFileSync(d, "utf8") },
  }));
} else {
  let o = {};
  try {
    o = JSON.parse(fs.readFileSync(a, "utf8"));
  } catch (e) {
    o = { decision: "unparsed" };
  }
  process.stdout.write(String(o.decision || "none") + "\n" + String(o.reason || ""));
}
EDITJS
EDIT_JS_M="$(np "$EDIT_JS")"

REG_ROWS="$(node "$EDIT_JS_M" reg "$(np "$SETTINGS_JSON")" hooks/block-case-markers.js 2>/dev/null | tr -d '\r')"
REG_MATCHER="$(printf '%s\n' "$REG_ROWS" | head -n 1 | cut -f 1)"
REG_TYPE="$(printf '%s\n' "$REG_ROWS" | head -n 1 | cut -f 2)"
REG_CMD="$(printf '%s\n' "$REG_ROWS" | head -n 1 | cut -f 3)"
# The registered string, with only the settings root name replaced by this checkout.
RUN_CMD="${REG_CMD//\$AGENTS_MAIN_ROOT/$(np "$SCRIPT_CHECKOUT_ROOT")}"

# matcher_takes <tool> — the registered matcher, read as the alternation it is, names <tool>.
matcher_takes() {
  case "|$REG_MATCHER|" in
    *"|$1|"*) return 0 ;;
  esac
  return 1
}

# edit_try <tool> <rel> <body-name> — one tool call on the fixture repo through the
# registered command. Sets ED_RC, ED_DECISION, ED_REASON.
ED_RC=0; ED_DECISION="none"; ED_REASON=""
edit_try() {
  local repo_m parsed
  repo_m="$(np "$TEMPLATE")"
  node "$EDIT_JS_M" payload "$1" "$repo_m" "$repo_m/$2" "$(np "$BODIES/$3")" > "$TMPBASE/edit-payload.json"
  ED_RC=0
  ED_DECISION="none"
  ED_REASON=""
  if [ -z "$REG_CMD" ]; then
    ED_RC=127
    return 0
  fi
  (
    cd "$NEUTRAL_CWD" || exit 99
    run_with_timeout 60 env "AGENTS_MAIN_ROOT=$(np "$EMPTY_ROOT")" bash -c "$RUN_CMD" < "$TMPBASE/edit-payload.json"
  ) > "$TMPBASE/edit.out" 2>/dev/null || ED_RC=$?
  parsed="$(node "$EDIT_JS_M" verdict "$(np "$TMPBASE/edit.out")")"
  ED_DECISION="${parsed%%$'\n'*}"
  case "$parsed" in *$'\n'*) ED_REASON="${parsed#*$'\n'}" ;; esac
}

# edit_pair <language id> — both verdicts for one language.
edit_pair() {
  local lang="$1" rel
  lang_set "$lang" "gate-edit"
  rel="tests/hooks/$LF"

  edit_try Write "$rel" "$LBODY-conforming"
  assert_eq "$lang conforming: rc=$ED_RC decision=$ED_DECISION" "$lang conforming: rc=0 decision=approve"

  if ! command -v "$LREQ" >/dev/null 2>&1; then
    skip "$lang without markers: $LREQ not on PATH, its case reader cannot run"
    return 0
  fi
  edit_try Write "$rel" "$LBODY-missing"
  assert_eq "$lang without markers: rc=$ED_RC decision=$ED_DECISION" "$lang without markers: rc=0 decision=block"
  has "$lang without markers: names the file" "$ED_REASON" "$rel"
  has "$lang without markers: carries the code" "$ED_REASON" "code=MISSING_CASE_MARKERS"
}

case_begin "edit-hook-registration-matcher" "settings.json"
assert_eq "registrations=$(printf '%s' "$REG_ROWS" | grep -c .)" "registrations=1"
assert_eq "matcher=$REG_MATCHER" "matcher=Write|Edit|MultiEdit|editFiles"
assert_eq "type=$REG_TYPE" "type=command"
assert_eq "command=$REG_CMD" "command=node \"\$AGENTS_MAIN_ROOT/hooks/block-case-markers.js\""
for _tool in Write Edit MultiEdit editFiles; do
  if matcher_takes "$_tool"; then
    pass "matcher routes $_tool to the hook"
  else
    fail "matcher routes $_tool" "[$REG_MATCHER] does not name it"
  fi
done
if matcher_takes Read; then
  fail "matcher leaves Read alone" "[$REG_MATCHER] names it"
else
  pass "matcher leaves Read alone"
fi
case_end

case_begin "edit-bash-both-verdicts" "hooks/block-case-markers.js"
edit_pair bash
case_end

case_begin "edit-pester-both-verdicts" "hooks/block-case-markers.js"
edit_pair pester
case_end

case_begin "edit-pytest-both-verdicts" "hooks/block-case-markers.js"
edit_pair pytest
case_end

case_begin "edit-js-both-verdicts" "hooks/block-case-markers.js"
edit_pair js
case_end
